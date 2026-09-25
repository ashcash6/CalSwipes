import CoreGraphics
import CoreML
import CoreVideo
import Foundation

struct ModelContract {
    let resourceName: String
    let inputs: [String: MLFeatureType]
    let outputs: [String: MLFeatureType]
    static let smoke = ModelContract(resourceName: "PlateSmoke", inputs: ["image":.image], outputs: ["luma":.multiArray])
}

enum ModelFailure: LocalizedError {
    case missing(String), contractMismatch, imageInput
    var errorDescription: String? {
        switch self {
        case .missing(let name): return "The on-device model \(name) is not bundled."
        case .contractMismatch: return "The model’s input/output contract does not match its adapter."
        case .imageInput: return "The photo could not be prepared for this model."
        }
    }
}

struct ModelPrediction {
    let features: any MLFeatureProvider
    let elapsedMilliseconds: Double
}

/// Serial, off-main model work. A single cached model limits simultaneous model residency.
/// This runner does not interpret outputs as food masks or portion estimates.
actor CoreMLRuntime {
    private let bundle: Bundle
    private var cached: (name: String, model: MLModel)?
    init(bundle: Bundle = .main) { self.bundle = bundle }

    func unload() { cached = nil }

    func predict(_ contract: ModelContract, features: any MLFeatureProvider) throws -> ModelPrediction {
        try Task.checkCancellation()
        let model = try load(contract)
        for (name, type) in contract.inputs {
            guard let feature = features.featureValue(for: name), feature.type == type,
                  model.modelDescription.inputDescriptionsByName[name]?.isAllowedValue(feature) == true else {
                throw ModelFailure.contractMismatch
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let prediction = try model.prediction(from: features)
        let elapsed = start.duration(to: clock.now).components
        try Task.checkCancellation()
        for (name, type) in contract.outputs {
            guard prediction.featureValue(for: name)?.type == type else { throw ModelFailure.contractMismatch }
        }
        return ModelPrediction(features: prediction,
            elapsedMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    }

    private func load(_ contract: ModelContract) throws -> MLModel {
        let model: MLModel
        if let cached, cached.name == contract.resourceName { model = cached.model }
        else {
            cached = nil
            guard let url = bundle.url(forResource: contract.resourceName, withExtension: "mlmodelc") else {
                throw ModelFailure.missing(contract.resourceName)
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try MLModel(contentsOf: url, configuration: configuration)
        }
        guard Set(model.modelDescription.inputDescriptionsByName.keys) == Set(contract.inputs.keys),
              contract.inputs.allSatisfy({ model.modelDescription.inputDescriptionsByName[$0.key]?.type == $0.value }),
              contract.outputs.allSatisfy({ model.modelDescription.outputDescriptionsByName[$0.key]?.type == $0.value }) else {
            throw ModelFailure.contractMismatch
        }
        cached = (contract.resourceName, model)
        return model
    }

    /// Diagnostic only: feed the supplied untrained conversion fixture, never a nutrition model.
    func smokePrediction(_ image: CGImage) throws -> ModelPrediction {
        let buffer = try ImageTensor.make(image, width: 256, height: 256)
        let features = try MLDictionaryFeatureProvider(dictionary: ["image":MLFeatureValue(pixelBuffer: buffer)])
        return try predict(.smoke, features: features)
    }
}

enum ImageTensor {
    /// Aspect-fit letterboxing for the smoke fixture. Real model adapters must own their transforms.
    static func make(_ image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        guard (1...2048).contains(width), (1...2048).contains(height) else { throw ModelFailure.imageInput }
        var value: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey:true,
            kCVPixelBufferCGBitmapContextCompatibilityKey:true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &value) == kCVReturnSuccess, let buffer = value else {
            throw ModelFailure.imageInput
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ModelFailure.imageInput
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (CGFloat(width)-size.width)/2, y: (CGFloat(height)-size.height)/2,
                                      width: size.width, height: size.height))
        return buffer
    }
}
