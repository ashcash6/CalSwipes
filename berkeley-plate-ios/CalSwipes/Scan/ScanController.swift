import Foundation
import SwiftUI

struct ScanRequest: Identifiable {
    let id = UUID()
    let menu: MenuEnvelope
    let expected: Set<String>
}

enum ScanPhase: Equatable { case camera, review, processing, result, blocked, verify }

@MainActor
final class ScanController: ObservableObject {
    @Published private(set) var phase: ScanPhase = .camera
    @Published private(set) var photo: CapturedPhoto?
    @Published private(set) var result: ScanResult?
    @Published private(set) var message = ""
    @Published private(set) var demoActive = false
    @Published private(set) var samCandidates: [SAMCandidate] = []
    @Published private(set) var candidateIndex = 0
    @Published private(set) var points: [SAMPoint] = []
    @Published private(set) var foods: [FoodRegion] = []
    @Published private(set) var plate: FoodRegion?
    @Published var selectingPlate = true
    @Published var excludePoint = false
    var candidate: FoodRegion? { samCandidates.indices.contains(candidateIndex) ? samCandidates[candidateIndex].region : nil }
    var outlinedPlate: SegmentedPlate { SegmentedPlate(foods: foods, plate: plate) }
    let request: ScanRequest
    private let pipeline: any ScanAnalyzing
    private let segmenter: any PromptSegmenting
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var pendingResult: ScanResult?

    init(request: ScanRequest, pipeline: any ScanAnalyzing = GeminiScanPipeline(), segmenter: any PromptSegmenting = MobileSAM()) {
        self.request = request
        self.pipeline = pipeline
        self.segmenter = segmenter
    }

    func accept(_ photo: CapturedPhoto) {
        guard phase == .camera else { return }
        self.photo = photo
        result = nil
        message = ""
        run(pipeline, isDemo: false)
    }

    func retake() {
        cancel()
        clearSegmentation()
        photo = nil
        result = nil
        pendingResult = nil
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
        pendingResult = nil
        clearSegmentation()
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation = UUID()
        if photo != nil { phase = .review }
    }

    func analyze() { run(pipeline, isDemo: false) }

    // MARK: - Verify phase

    /// Called when the user taps an item in the verification picker, replacing the AI's guess.
    func confirmVerification(itemId: String) {
        guard let pending = pendingResult,
              let item = request.menu.items.first(where: { $0.id == itemId }),
              item.nutritionStatus == "published",
              let macros = item.macros else {
            message = "Nutrition data not available for that item."
            phase = .blocked
            return
        }
        let line = EstimatedLine(id: UUID(), item: item, multiplier: 1.0, macros: macros)
        let confirmed = ScanResult(
            lines: [line], total: macros, lower: nil, upper: nil,
            isDemo: false, isVisionClassified: false, isGenericFallback: false,
            isGeminiClassified: true, isNonDiningHallEstimate: false,
            menuRevision: pending.menuRevision, confidenceTier: "auto", candidates: []
        )

        // Log correction if the user picked something different than what AI suggested.
        if let original = pending.candidates.first, original.primaryItem.id != itemId {
            if let gemini = pipeline as? GeminiScanPipeline, let photo {
                let photoRef = photo
                let menuRef = request.menu
                Task { await gemini.logCorrection(originalItemId: original.primaryItem.id,
                                                   correctedItemId: itemId,
                                                   photo: photoRef, menu: menuRef) }
            }
        }

        pendingResult = nil
        result = confirmed
        phase = .result
    }

    /// Called when the user says "none of these" in the verification picker.
    func rejectVerification() {
        pendingResult = nil
        phase = .review
        result = nil
    }

    // MARK: - Post-result correction

    /// Called from the result view when the user taps "Wrong item?" after auto-accept.
    func reportCorrection(originalItemId: String, correctedItemId: String) {
        guard let photo, correctedItemId != originalItemId,
              let item = request.menu.items.first(where: { $0.id == correctedItemId }),
              item.nutritionStatus == "published",
              let macros = item.macros else { return }

        if let gemini = pipeline as? GeminiScanPipeline {
            let photoRef = photo
            let menuRef = request.menu
            Task { await gemini.logCorrection(originalItemId: originalItemId,
                                               correctedItemId: correctedItemId,
                                               photo: photoRef, menu: menuRef) }
        }

        let line = EstimatedLine(id: UUID(), item: item, multiplier: 1.0, macros: macros)
        result = ScanResult(
            lines: [line], total: macros, lower: nil, upper: nil,
            isDemo: false, isVisionClassified: false, isGenericFallback: false,
            isGeminiClassified: true, isNonDiningHallEstimate: false,
            menuRevision: result?.menuRevision ?? "", confidenceTier: "auto", candidates: []
        )
    }

    // MARK: - SAM segmentation

    private func clearSegmentation() {
        samCandidates = []; points = []; foods = []; plate = nil
        candidateIndex = 0; selectingPlate = true; excludePoint = false
        let segmenter = segmenter
        Task { await segmenter.release() }
    }

    func startNewOutline() {
        guard phase != .processing else { return }
        samCandidates = []; points = []; candidateIndex = 0; excludePoint = false
        message = ""; phase = .review; result = nil; demoActive = false
    }

    func nextCandidate() {
        guard !samCandidates.isEmpty, phase != .processing else { return }
        candidateIndex = (candidateIndex + 1) % samCandidates.count
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
        samCandidates = []; candidateIndex = 0; result = nil; demoActive = false
        let current = UUID(); generation = current
        let segmenter = segmenter, prompts = points
        phase = .processing; message = "Finding the outline on this iPhone…"
        task = Task { [weak self] in
            do {
                let candidates = try await segmenter.candidates(photo: photo, points: prompts)
                guard !Task.isCancelled, let self, self.generation == current else { return }
                guard !candidates.isEmpty, candidates.count <= 3 else { throw PipelineFailure.invalidOutput }
                for value in candidates { try value.region.validate() }
                self.samCandidates = candidates; self.phase = .review; self.message = ""; self.task = nil
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
        pendingResult = nil
        phase = .processing
        message = isDemo ? "Preparing example results…" : "Analyzing your meal…"
        let menu = request.menu
        let expected = request.expected
        task = Task { [weak self] in
            do {
                let scanResult = try await selectedPipeline.analyze(
                    photo: photo, menu: menu, expected: expected, isDiningHall: true
                ) { [weak self] progress in
                    await MainActor.run {
                        guard let self, self.generation == current else { return }
                        self.message = progress
                    }
                }
                guard !Task.isCancelled, let self, self.generation == current else { return }
                guard scanResult.isDemo == isDemo else { throw PipelineFailure.invalidOutput }

                if !isDemo && (scanResult.confidenceTier == "confirm" || scanResult.confidenceTier == "ask") {
                    self.pendingResult = scanResult
                    self.result = scanResult
                    self.phase = .verify
                } else {
                    self.result = scanResult
                    self.phase = .result
                }
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
