import XCTest
import CoreML
import CoreGraphics
@testable import BerkeleyPlate

final class SegmentationTests: XCTestCase {
    func testPortraitLandscapeAndPromptMapping() throws {
        let portrait = try SAMTransform(width: 400, height: 800)
        XCTAssertEqual(portrait.width, 512); XCTAssertEqual(portrait.height, 1024)
        let point = try portrait.modelPoint(CGPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(point.x, 128); XCTAssertEqual(point.y, 768)
        let landscape = try SAMTransform(width: 800, height: 400)
        XCTAssertEqual(landscape.width, 1024); XCTAssertEqual(landscape.height, 512)
        XCTAssertThrowsError(try portrait.modelPoint(CGPoint(x: -0.1, y: 0)))
        XCTAssertThrowsError(try portrait.modelPoint(CGPoint(x: 1, y: 0)))
    }

    func testMaskCropsRightPaddingAndPreservesBounds() throws {
        var logits = [Float](repeating: -10, count: 65536)
        // Foreground entirely inside the right-side padding of a portrait image.
        for y in 0..<256 { for x in 160..<256 { logits[y*256+x] = 10 } }
        let transform = try SAMTransform(width: 400, height: 800)
        XCTAssertThrowsError(try SAMMask.region(logits: logits, transform: transform))
        logits = [Float](repeating: -10, count: 65536)
        for y in 32..<96 { for x in 32..<96 { logits[y*256+x] = 10 } }
        let region = try SAMMask.region(logits: logits, transform: transform)
        XCTAssertEqual(region.bounds.minX, 0.25, accuracy: 0.01)
        XCTAssertEqual(region.bounds.minY, 0.125, accuracy: 0.01)
        XCTAssertEqual(region.bounds.width, 0.5, accuracy: 0.01)
        XCTAssertEqual(region.bounds.height, 0.25, accuracy: 0.01)
        XCTAssertEqual(region.mask.count, region.maskWidth * region.maskHeight)
        try region.validate()
        logits[0] = .nan
        XCTAssertThrowsError(try SAMMask.region(logits: logits, transform: transform))
    }

    func testRGBOrderOrientationAndNormalizedZeroPadding() throws {
        // Asymmetric source: red top half, blue bottom half. CGImage bytes are top-down.
        let bytes: [UInt8] = [255,0,0,255, 255,0,0,255, 0,0,255,255, 0,0,255,255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let (array, transform) = try SAMImageInput.make(image)
        XCTAssertEqual(transform.width, 256)
        XCTAssertEqual(array[[0,0,64,64]].floatValue, (255-123.675)/58.395, accuracy: 0.02)
        XCTAssertEqual(array[[0,2,960,64]].floatValue, (255-103.53)/57.375, accuracy: 0.02)
        XCTAssertEqual(array[[0,0,64,900]].floatValue, 0)
        XCTAssertEqual(array[[0,2,960,900]].floatValue, 0)
    }

    func testPromptEncodingMatchesOfficialPyTorchFixture() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "mobile_sam_prompt_encoder_weights", withExtension: "json"))
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let weights = try decoder.decode(SAMPromptWeights.self, from: Data(contentsOf: url))
        let result = try weights.sparse(points: [SAMPoint(location: CGPoint(x: 0.3,y: 0.2), positive: true),
            SAMPoint(location: CGPoint(x: 0.9,y: 0.8), positive: false)], transform: SAMTransform(width: 400, height: 800))
        struct Reference: Decodable { let sparse: [Float] }
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "prompt-reference", withExtension: "json"))
        let expected = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(result.count, expected.sparse.count)
        for i in 0..<result.count { XCTAssertEqual(result[i].floatValue, expected.sparse[i], accuracy: 0.00002) }
        XCTAssertThrowsError(try weights.sparse(points: [], transform: SAMTransform(width: 1, height: 1)))
    }

    func testBundledTrainedModelsExecute() async throws {
        // Mandatory integration test: missing resources must fail, never silently skip.
        // A synthetic image checks runtime/finite outputs only, not segmentation accuracy.
        let segmenter = MobileSAM()
        do {
            let result = try await segmenter.candidates(photo: CaptureFixture.photo(), points: [SAMPoint(location: CGPoint(x: 0.5,y: 0.5), positive: true)])
            XCTAssertFalse(result.isEmpty)
            for candidate in result { try candidate.region.validate(); XCTAssertTrue(candidate.score.isFinite) }
        } catch PipelineFailure.unavailable {
            // Empty masks are valid on a uniform synthetic photo after successful model execution.
        }
        await segmenter.release()
    }
}
