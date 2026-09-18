import CoreGraphics
import Foundation
import Vision

/// On-device food recognition using Apple's built-in Vision classifier.
/// Classifies the full photo, maps labels to today's menu items by keyword
/// overlap, and returns the top matches at one published serving each.
/// No network calls, no model download, no LiDAR required.
actor VisionClassifyPipeline: ScanAnalyzing {
    func analyze(photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>,
                 progress: @escaping @Sendable (String) async -> Void) async throws -> ScanResult {
        try ScanPipeline.validateMenu(menu, capturedAt: photo.capturedAt)
        try Task.checkCancellation()
        await progress("Reading photo on this iPhone…")

        let labelWords = try await classifyToWords(photo.image)
        try Task.checkCancellation()
        await progress("Matching today's menu…")

        let published = menu.items.filter { $0.nutritionStatus == "published" && $0.macros != nil }
        guard !published.isEmpty else {
            throw PipelineFailure.unavailable("No published nutrition in today's menu.")
        }

        let ranked = published
            .map { ($0, score($0, labelWords: labelWords, expected: expected)) }
            .sorted { $0.1 > $1.1 }

        // Take up to 3 items with a positive label overlap, then fall back
        // to whatever the user preselected from the menu.
        var picked = ranked.prefix(3).filter { $0.1 > 0 }.map(\.0)
        if picked.isEmpty {
            picked = published.filter { expected.contains($0.id) }
        }
        guard !picked.isEmpty else {
            throw PipelineFailure.unavailable(
                "Could not identify food from this photo. Try better lighting, " +
                "or preselect expected items from the menu first."
            )
        }

        return try buildResult(picked, menuRevision: menu.revision)
    }

    // MARK: - Vision classification

    private func classifyToWords(_ image: CGImage) async throws -> [String: Float] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNClassifyImageRequest()
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                var words: [String: Float] = [:]
                for obs in request.results ?? [] where obs.confidence > 0.05 {
                    // Split "macaroni_and_cheese" into ["macaroni", "and", "cheese"]
                    for word in obs.identifier.split(whereSeparator: { !$0.isLetter }).map({ String($0).lowercased() }) where word.count > 2 {
                        words[word] = max(words[word, default: 0], obs.confidence)
                    }
                }
                continuation.resume(returning: words)
            }
        }
    }

    // MARK: - Menu matching

    private func score(_ item: MenuItem, labelWords: [String: Float], expected: Set<String>) -> Double {
        // Preselected items get a small boost so the user's hint is respected.
        var s: Double = expected.contains(item.id) ? 0.15 : 0
        let itemWords = item.name.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count > 2 }
        for word in itemWords {
            if let confidence = labelWords[word] { s += Double(confidence) }
        }
        return s
    }

    // MARK: - Result assembly

    private func buildResult(_ items: [MenuItem], menuRevision: String) throws -> ScanResult {
        var lines: [EstimatedLine] = []
        for item in items {
            guard let macros = item.macros, item.nutritionStatus == "published" else { continue }
            lines.append(EstimatedLine(id: UUID(), item: item, multiplier: 1.0, macros: macros))
        }
        guard !lines.isEmpty else { throw PipelineFailure.missingNutrition }
        let total = lines.reduce(NutritionMath.zero) { NutritionMath.add($0, $1.macros) }
        guard [total.caloriesKcal, total.proteinG, total.carbsG, total.fatG].allSatisfy(\.isFinite) else {
            throw PipelineFailure.invalidOutput
        }
        return ScanResult(lines: lines, total: total, lower: nil, upper: nil,
                          isDemo: false, isVisionClassified: true, menuRevision: menuRevision)
    }
}
