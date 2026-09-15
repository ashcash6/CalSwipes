import XCTest
@testable import BerkeleyPlate

private struct DelayedPipeline: ScanAnalyzing {
    func analyze(photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>, progress: @escaping @Sendable (String) async -> Void) async throws -> ScanResult {
        await progress("Test progress")
        try await Task.sleep(for: .seconds(30))
        throw PipelineFailure.unavailable("Should have been canceled")
    }
}

private actor SuspendedSegmenter: PromptSegmenting {
    var pending: CheckedContinuation<[SAMCandidate], Never>?
    func candidates(photo: CapturedPhoto, points: [SAMPoint]) async throws -> [SAMCandidate] {
        await withCheckedContinuation { pending = $0 }
    }
    func isPending() -> Bool { pending != nil }
    func finish() {
        let region = FoodRegion(id: UUID(), bounds: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2),
            maskWidth: 2, maskHeight: 2, mask: [1,1,1,1])
        pending?.resume(returning: [SAMCandidate(region: region, score: 0.8)]); pending = nil
    }
    func release() {}
}

@MainActor
final class ScanControllerTests: XCTestCase {
    func testLateSegmentationCannotRestoreClosedPhoto() async throws {
        let segmenter = SuspendedSegmenter()
        let controller = ScanController(request: ScanRequest(menu: try CaptureFixture.menu(), expected: []), segmenter: segmenter)
        controller.accept(try CaptureFixture.photo())
        controller.tap(CGPoint(x: 0.5,y: 0.5))
        for _ in 0..<100 {
            if await segmenter.isPending() { break }
            await Task.yield()
        }
        let pending = await segmenter.isPending()
        XCTAssertTrue(pending)
        controller.close()
        await segmenter.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(controller.photo)
        XCTAssertTrue(controller.candidates.isEmpty)
        XCTAssertTrue(controller.foods.isEmpty)
        XCTAssertNil(controller.plate)
    }

    func testCancelRetakeAndCloseDiscardState() async throws {
        let controller = ScanController(request: ScanRequest(menu: try CaptureFixture.menu(), expected: []), pipeline: DelayedPipeline())
        controller.accept(try CaptureFixture.photo())
        XCTAssertEqual(controller.phase, .review)
        controller.analyze()
        XCTAssertEqual(controller.phase, .processing)
        controller.cancel()
        XCTAssertEqual(controller.phase, .review)
        controller.retake()
        XCTAssertEqual(controller.phase, .camera)
        XCTAssertNil(controller.photo)
        controller.accept(try CaptureFixture.photo())
        controller.close()
        XCTAssertNil(controller.photo)
        XCTAssertNil(controller.result)
        await Task.yield()
        XCTAssertNil(controller.result)
    }
}
