import CoreML
import CoreGraphics
import Foundation

struct SAMPoint {
    let location: CGPoint // normalized upright photo coordinates
    let positive: Bool
}

struct SAMCandidate: Identifiable {
    var id: UUID { region.id }
    let region: FoodRegion
    let score: Float // predicted mask IoU; not food/nutrition confidence
}

protocol PromptSegmenting {
    func candidates(photo: CapturedPhoto, points: [SAMPoint]) async throws -> [SAMCandidate]
    func release() async
}

struct SAMPromptWeights: Decodable {
    let embedDim: Int
    let imageEmbeddingSize: [Int]
    let inputImageSize: [Int]
    let gaussianMatrix: [[Float]]
    let pointEmbeddings: [[Float]]
    let notAPointEmbed: [Float]
    let noMaskEmbed: [Float]
    func validate() throws {
        guard embedDim == 256, imageEmbeddingSize == [64,64], inputImageSize == [1024,1024],
              gaussianMatrix.count == 2, gaussianMatrix.allSatisfy({ $0.count == 128 && $0.allSatisfy(\.isFinite) }),
              pointEmbeddings.count == 4, pointEmbeddings.allSatisfy({ $0.count == 256 && $0.allSatisfy(\.isFinite) }),
              notAPointEmbed.count == 256, noMaskEmbed.count == 256,
              notAPointEmbed.allSatisfy(\.isFinite), noMaskEmbed.allSatisfy(\.isFinite) else { throw ModelFailure.contractMismatch }
    }
    func sparse(points: [SAMPoint], transform: SAMTransform) throws -> MLMultiArray {
        try validate()
        guard (1...9).contains(points.count), points.contains(where: \.positive) else { throw ModelFailure.imageInput }
        let result = try MLMultiArray(shape: [1, NSNumber(value: points.count+1), 256], dataType: .float32)
        for (i, point) in points.enumerated() {
            let p = try transform.modelPoint(point.location)
            let x = 2 * (Float(p.x)+0.5)/1024 - 1, y = 2 * (Float(p.y)+0.5)/1024 - 1
            for j in 0..<128 {
                let angle = (x * gaussianMatrix[0][j] + y * gaussianMatrix[1][j]) * 2 * Float.pi
                result[i*256+j] = NSNumber(value: sin(angle) + pointEmbeddings[point.positive ? 1 : 0][j])
                result[i*256+j+128] = NSNumber(value: cos(angle) + pointEmbeddings[point.positive ? 1 : 0][j+128])
            }
        }
        for j in 0..<256 { result[points.count*256+j] = NSNumber(value: notAPointEmbed[j]) }
        return result
    }
}

/// One actor serializes all model work. Encoder is released after embedding; decoder
/// and embedding are reused across taps on this photo and explicitly released on close.
actor MobileSAM: PromptSegmenting {
    private let bundle: Bundle
    private var decoder: MLModel?
    private var weights: SAMPromptWeights?
    private var dense: MLMultiArray?
    private var cached: (id: UUID, embedding: MLMultiArray, transform: SAMTransform)?
    init(bundle: Bundle = .main) { self.bundle = bundle }

    func release() { cached = nil; decoder = nil; dense = nil; weights = nil }

    func candidates(photo: CapturedPhoto, points: [SAMPoint]) throws -> [SAMCandidate] {
        try Task.checkCancellation()
        guard (1...9).contains(points.count), points.contains(where: \.positive) else { throw ModelFailure.imageInput }
        if cached?.id != photo.id {
            release()
            let (input, transform) = try SAMImageInput.make(photo.image)
            let embedding: MLMultiArray = try autoreleasepool {
                let encoder = try load("mobile_sam_encoder", inputs: ["image"], outputs: ["image_embeddings"])
                let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image":input]))
                guard let value = output.featureValue(for: "image_embeddings")?.multiArrayValue else { throw ModelFailure.contractMismatch }
                try Self.check(value, shape: [1,256,64,64])
                return value
            }
            try Task.checkCancellation()
            cached = (photo.id, embedding, transform)
        }
        guard let cached else { throw ModelFailure.contractMismatch }
        if weights == nil {
            guard let url = bundle.url(forResource: "mobile_sam_prompt_encoder_weights", withExtension: "json") else {
                throw ModelFailure.missing("MobileSAM prompt weights")
            }
            let json = JSONDecoder(); json.keyDecodingStrategy = .convertFromSnakeCase
            let value = try json.decode(SAMPromptWeights.self, from: Data(contentsOf: url))
            try value.validate()
            let array = try MLMultiArray(shape: [1,256,64,64], dataType: .float32)
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for c in 0..<256 { (ptr + c*4096).update(repeating: value.noMaskEmbed[c], count: 4096) }
            dense = array; weights = value
        }
        guard let weights, let dense else { throw ModelFailure.contractMismatch }
        let sparse = try weights.sparse(points: points, transform: cached.transform)
        if decoder == nil { decoder = try load("mobile_sam_decoder", inputs: ["image_embeddings", "sparse_embeddings", "dense_embeddings"], outputs: ["masks", "iou_predictions"]) }
        guard let decoder else { throw ModelFailure.contractMismatch }
        try Task.checkCancellation()
        let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "image_embeddings":cached.embedding, "sparse_embeddings":sparse, "dense_embeddings":dense]))
        try Task.checkCancellation()
        guard let masks = output.featureValue(for: "masks")?.multiArrayValue,
              let scores = output.featureValue(for: "iou_predictions")?.multiArrayValue else { throw ModelFailure.contractMismatch }
        try Self.check(masks, shape: [1,3,256,256]); try Self.check(scores, shape: [1,3])
        var result: [SAMCandidate] = []
        for i in 0..<3 {
            // Indexed MLMultiArray reads respect strides; do not assume contiguous model outputs.
            var logits = [Float](); logits.reserveCapacity(65536)
            for y in 0..<256 { for x in 0..<256 { logits.append(masks[[0, NSNumber(value:i), NSNumber(value:y), NSNumber(value:x)]].floatValue) } }
            guard logits.allSatisfy(\.isFinite), scores[i].floatValue.isFinite else { throw PipelineFailure.invalidOutput }
            do { result.append(SAMCandidate(region: try SAMMask.region(logits: logits, transform: cached.transform), score: scores[i].floatValue)) }
            catch PipelineFailure.unavailable { continue }
        }
        try Task.checkCancellation()
        guard !result.isEmpty else { throw PipelineFailure.unavailable("No outline was found. Try a different point.") }
        return result.sorted { $0.score > $1.score }
    }

    private func load(_ name: String, inputs: Set<String>, outputs: Set<String>) throws -> MLModel {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else { throw ModelFailure.missing(name) }
        let config = MLModelConfiguration(); config.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: config)
        guard Set(model.modelDescription.inputDescriptionsByName.keys) == inputs,
              Set(model.modelDescription.outputDescriptionsByName.keys) == outputs,
              model.modelDescription.inputDescriptionsByName.values.allSatisfy({ $0.type == .multiArray }),
              model.modelDescription.outputDescriptionsByName.values.allSatisfy({ $0.type == .multiArray }) else { throw ModelFailure.contractMismatch }
        return model
    }
    private static func check(_ array: MLMultiArray, shape: [Int]) throws {
        guard array.shape.map(\.intValue) == shape else { throw ModelFailure.contractMismatch }
    }
}
