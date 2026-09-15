import Foundation
import SwiftUI

struct ScanRequest: Identifiable {
    let id = UUID()
    let menu: MenuEnvelope
    let expected: Set<String>
}

enum ScanPhase: Equatable { case camera, review, processing, result, blocked }

@MainActor
final class ScanController: ObservableObject {
    @Published private(set) var phase: ScanPhase = .camera
    @Published private(set) var photo: CapturedPhoto?
    @Published private(set) var result: ScanResult?
    @Published private(set) var message = ""
    @Published private(set) var demoActive = false
    @Published private(set) var candidates: [SAMCandidate] = []
    @Published private(set) var candidateIndex = 0
    @Published private(set) var points: [SAMPoint] = []
    @Published private(set) var foods: [FoodRegion] = []
    @Published private(set) var plate: FoodRegion?
    @Published var selectingPlate = true
    @Published var excludePoint = false
    var candidate: FoodRegion? { candidates.indices.contains(candidateIndex) ? candidates[candidateIndex].region : nil }
    var outlinedPlate: SegmentedPlate { SegmentedPlate(foods: foods, plate: plate) }
    let request: ScanRequest
    private let pipeline: any ScanAnalyzing
    private let segmenter: any PromptSegmenting
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(request: ScanRequest, pipeline: any ScanAnalyzing = ScanPipeline(), segmenter: any PromptSegmenting = MobileSAM()) {
        self.request = request
        self.pipeline = pipeline
        self.segmenter = segmenter
    }

    func accept(_ photo: CapturedPhoto) {
        guard phase == .camera else { return }
        self.photo = photo
        result = nil
        message = ""
        phase = .review
    }

    func retake() {
        cancel()
        clearSegmentation()
        photo = nil
        result = nil
        message = ""
        demoActive = false
        phase = .camera
    }

    func close() {
        task?.cancel()
        task = nil
        generation = UUID()
        photo = nil
        result = nil
        clearSegmentation()
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation = UUID()
        if photo != nil { phase = .review }
    }

    func analyze() { run(pipeline, isDemo: false) }

    private func clearSegmentation() {
        candidates = []; points = []; foods = []; plate = nil
        candidateIndex = 0; selectingPlate = true; excludePoint = false
        let segmenter = segmenter
        Task { await segmenter.release() }
    }

    func startNewOutline() {
        guard phase != .processing else { return }
        candidates = []; points = []; candidateIndex = 0; excludePoint = false
        message = ""; phase = .review; result = nil; demoActive = false
    }

    func nextCandidate() {
        guard !candidates.isEmpty, phase != .processing else { return }
        candidateIndex = (candidateIndex + 1) % candidates.count
    }

    func removeFood(_ id: UUID) { foods.removeAll { $0.id == id } }

    func confirmOutline() {
        guard phase == .review, let candidate else { return }
        if selectingPlate { plate = candidate; selectingPlate = false }
        else {
            guard foods.count < 8 else { message = "This build supports up to eight food regions."; return }
            foods.append(candidate)
        }
        startNewOutline()
    }

    func tap(_ location: CGPoint) {
        guard let photo, phase == .review || phase == .blocked else { return }
        guard location.x.isFinite, location.y.isFinite, (0..<1).contains(location.x), (0..<1).contains(location.y) else { return }
        guard points.count < 9 else { message = "Start a new outline after nine taps."; return }
        guard !excludePoint || !points.isEmpty else { message = "Tap inside the object first."; return }
        points.append(SAMPoint(location: location, positive: !excludePoint))
        excludePoint = false
        candidates = []; candidateIndex = 0; result = nil; demoActive = false
        let current = UUID(); generation = current
        let segmenter = segmenter, prompts = points
        phase = .processing; message = "Finding the outline on this iPhone…"
        task = Task { [weak self] in
            do {
                let candidates = try await segmenter.candidates(photo: photo, points: prompts)
                guard !Task.isCancelled, let self, self.generation == current else { return }
                guard !candidates.isEmpty, candidates.count <= 3 else { throw PipelineFailure.invalidOutput }
                for value in candidates { try value.region.validate() }
                self.candidates = candidates; self.phase = .review; self.message = ""; self.task = nil
            } catch is CancellationError {
                guard let self, self.generation == current else { return }
                self.phase = .review; self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.message = error.localizedDescription; self.phase = .blocked; self.task = nil
            }
        }
    }

    #if DEBUG
    func previewDemo() { run(DemoScanPipeline(), isDemo: true) }
    #endif

    private func run(_ selectedPipeline: any ScanAnalyzing, isDemo: Bool) {
        guard let photo, phase != .processing else { return }
        task?.cancel()
        let current = UUID()
        generation = current
        demoActive = isDemo
        result = nil
        phase = .processing
        message = isDemo ? "Preparing example results…" : "Preparing on-device analysis…"
        let menu = request.menu
        let expected = request.expected
        task = Task { [weak self] in
            do {
                let result = try await selectedPipeline.analyze(photo: photo, menu: menu, expected: expected) { [weak self] progress in
                    await MainActor.run {
                        guard let self, self.generation == current else { return }
                        self.message = progress
                    }
                }
                guard !Task.isCancelled, let self, self.generation == current else { return }
                // Defense in depth: a demo implementation can never be displayed as a measured result.
                guard result.isDemo == isDemo else { throw PipelineFailure.invalidOutput }
                self.result = result
                self.phase = .result
            } catch is CancellationError {
                guard let self, self.generation == current else { return }
                self.phase = .review
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.message = error.localizedDescription
                self.phase = .blocked
            }
        }
    }
}
