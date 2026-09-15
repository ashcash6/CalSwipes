import CoreML
import XCTest
@testable import BerkeleyPlate

final class CoreMLRuntimeTests: XCTestCase {
    func testMissingModelExplicitlyFails() async throws {
        let contract = ModelContract(resourceName: "IntentionallyMissing", inputs: [:], outputs: [:])
        let input = try MLDictionaryFeatureProvider(dictionary: [:])
        do {
            _ = try await CoreMLRuntime(bundle: Bundle(for: Self.self)).predict(contract, features: input)
            XCTFail("Missing model should not run")
        } catch ModelFailure.missing { }
    }

    func testUntrainedConversionFixtureOnCoreML() async throws {
        let bundle = Bundle(for: Self.self)
        guard bundle.url(forResource: "PlateSmoke", withExtension: "mlmodelc") != nil else {
            throw XCTSkip("Run Tools/export_smoke_model.py and regenerate the Xcode project to test real CoreML execution")
        }
        let prediction = try await CoreMLRuntime(bundle: bundle).smokePrediction(CaptureFixture.image(width: 256, height: 256))
        let tensor = try XCTUnwrap(prediction.features.featureValue(for: "luma")?.multiArrayValue)
        XCTAssertEqual(tensor.shape.map(\.intValue), [1,1,256,256])
        XCTAssertEqual(tensor[[0,0,128,128] as [NSNumber]].doubleValue, 1, accuracy: 0.02)
        XCTAssertGreaterThan(prediction.elapsedMilliseconds, 0)
    }
}
