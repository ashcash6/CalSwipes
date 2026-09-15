import CoreGraphics
import XCTest
@testable import BerkeleyPlate

private struct FakeStages: Segmenting, MenuClassifying, PortionEstimating {
    let matchID: String?
    func segment(_ photo: CapturedPhoto) async throws -> SegmentedPlate {
        SegmentedPlate(foods: [FoodRegion(id: UUID(), bounds: CGRect(x:0.1,y:0.1,width:0.5,height:0.5),
            maskWidth: 1, maskHeight: 1, mask: [1])], plate: nil)
    }
    func classify(_ regions: [FoodRegion], photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>) async throws -> [RegionMatch] {
        regions.map { RegionMatch(regionId: $0.id, menuItemId: matchID, similarity: 0.8) }
    }
    func estimate(_ regions: [FoodRegion], matches: [RegionMatch], photo: CapturedPhoto, menu: MenuEnvelope) async throws -> [EstimatedServing] {
        XCTFail("Portion estimation must not run on an RGB-only photo")
        throw PipelineFailure.invalidOutput
    }
}

final class PipelineTests: XCTestCase {
    func testMissingModelsNeverProduceEstimate() async throws {
        do {
            _ = try await ScanPipeline().analyze(photo: CaptureFixture.photo(), menu: CaptureFixture.menu(), expected: []) { _ in }
            XCTFail("Missing models must not fabricate an estimate")
        } catch PipelineFailure.unavailable { }
    }

    func testUnknownFoodStopsTotal() async throws {
        let stages = FakeStages(matchID: nil)
        let pipeline = ScanPipeline(segmentation: stages, classification: stages, portions: stages)
        do {
            _ = try await pipeline.analyze(photo: CaptureFixture.photo(), menu: CaptureFixture.menu(), expected: []) { _ in }
            XCTFail("Unknown food must not silently disappear from a total")
        } catch PipelineFailure.needsIdentification { }
    }

    func testRGBPhotoNeverBecomesMetricPortion() async throws {
        let stages = FakeStages(matchID: "1542")
        let pipeline = ScanPipeline(segmentation: stages, classification: stages, portions: stages)
        do {
            _ = try await pipeline.analyze(photo: CaptureFixture.photo(), menu: CaptureFixture.menu(), expected: []) { _ in }
            XCTFail("RGB photo cannot prove metric scale")
        } catch PipelineFailure.metricDepthRequired { }
    }

    func testMenuExpiresBeforeNewAnalysis() throws {
        let menu = try CaptureFixture.menu()
        XCTAssertThrowsError(try ScanPipeline.validateMenu(menu, capturedAt: Date(), now: menu.expiresAt))
        XCTAssertThrowsError(try ScanPipeline.validateMenu(menu, capturedAt: Date().addingTimeInterval(-86400)))
    }

    func testInvalidMaskAndBoundsRejected() {
        XCTAssertThrowsError(try FoodRegion(id: UUID(), bounds: CGRect(x:0,y:0,width:2,height:1), maskWidth: 1, maskHeight: 1, mask: [1]).validate())
        XCTAssertThrowsError(try FoodRegion(id: UUID(), bounds: CGRect(x:0,y:0,width:1,height:1), maskWidth: 2, maskHeight: 1, mask: [1]).validate())
        XCTAssertThrowsError(try FoodRegion(id: UUID(), bounds: CGRect(x:0,y:0,width:1,height:1), maskWidth: 1, maskHeight: 1, mask: [.nan]).validate())
    }

    func testReferenceArithmeticAndRangeValidation() throws {
        let menu = try CaptureFixture.menu()
        let serving = EstimatedServing(regionId: UUID(), menuItemId: "1542", multiplier: 1.5, lowerMultiplier: 0.5, upperMultiplier: 2)
        let result = try NutritionMath.result([serving], menu: menu)
        XCTAssertEqual(result.total.caloriesKcal, 259.77, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.lower).caloriesKcal, 86.59, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.upper).caloriesKcal, 346.36, accuracy: 0.001)
        for factor in [Double.nan, -1, 0, 9] {
            XCTAssertThrowsError(try NutritionMath.result([EstimatedServing(regionId: UUID(), menuItemId: "1542",
                multiplier: factor, lowerMultiplier: 0.5, upperMultiplier: 2)], menu: menu))
        }
    }

    #if DEBUG
    func testDemoIsLabeledAndHasNoConfidenceRange() async throws {
        let result = try await DemoScanPipeline().analyze(photo: CaptureFixture.photo(), menu: CaptureFixture.menu(), expected: ["1542"]) { _ in }
        XCTAssertTrue(result.isDemo)
        XCTAssertNil(result.lower)
        XCTAssertNil(result.upper)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.total.caloriesKcal, 173.18, accuracy: 0.001)
    }
    #endif
}
