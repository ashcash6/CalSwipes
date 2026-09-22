import CoreGraphics
import Foundation
import Vision

/// On-device food recognition using Apple's built-in Vision classifier.
/// Primary path: matches Vision labels against today's dining hall menu items.
/// Fallback: when no menu item matches, uses a generic food database so the
/// user always gets an estimate rather than an error.
/// No network calls, no model download, no LiDAR required.
actor VisionClassifyPipeline: ScanAnalyzing {
    func analyze(photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>, isDiningHall: Bool = true,
                 progress: @escaping @Sendable (String) async -> Void) async throws -> ScanResult {
        try ScanPipeline.validateMenu(menu, capturedAt: photo.capturedAt)
        try Task.checkCancellation()
        await progress("Reading photo on this iPhone…")

        let labelWords = try await classifyToWords(photo.image)
        try Task.checkCancellation()
        await progress("Matching today's menu…")

        let published = menu.items.filter { $0.nutritionStatus == "published" && $0.macros != nil }

        if !published.isEmpty {
            let ranked = published
                .map { ($0, score($0, labelWords: labelWords)) }
                .sorted { $0.1 > $1.1 }
            let picked = Array(ranked.prefix(3).filter { $0.1 > 0 }.map(\.0))
            if !picked.isEmpty {
                return try buildMenuResult(picked, menuRevision: menu.revision)
            }
        }

        // No menu match — fall back to generic food database
        await progress("Using generic food estimates…")
        return try genericFallback(labelWords: labelWords, menuRevision: menu.revision)
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
                    for word in obs.identifier.split(whereSeparator: { !$0.isLetter })
                        .map({ String($0).lowercased() }) where word.count > 2 {
                        words[word] = max(words[word, default: 0], obs.confidence)
                    }
                }
                continuation.resume(returning: words)
            }
        }
    }

    // MARK: - Menu matching (no preselection boost)

    private func score(_ item: MenuItem, labelWords: [String: Float]) -> Double {
        var s = 0.0
        let itemWords = item.name.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count > 2 }
        for word in itemWords {
            if let confidence = labelWords[word] { s += Double(confidence) }
        }
        return s
    }

    // MARK: - Menu result

    private func buildMenuResult(_ items: [MenuItem], menuRevision: String) throws -> ScanResult {
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
                          isDemo: false, isVisionClassified: true, isGenericFallback: false,
                          isGeminiClassified: false, isNonDiningHallEstimate: false, menuRevision: menuRevision)
    }

    // MARK: - Generic fallback

    private func genericFallback(labelWords: [String: Float], menuRevision: String) throws -> ScanResult {
        let ranked = labelWords
            .compactMap { word, conf -> (String, Float, Macros)? in
                guard let m = GenericFoodDB.lookup(word) else { return nil }
                return (word, conf, m)
            }
            .sorted { $0.1 > $1.1 }

        guard let best = ranked.first else {
            throw PipelineFailure.unavailable(
                "Could not identify food from this photo. Try better lighting or move the camera closer."
            )
        }

        let displayName = best.0.capitalized
        let item = MenuItem(
            id: "generic-\(best.0)",
            name: displayName,
            categories: ["Generic estimate"],
            serving: Serving(quantity: 1, unit: "serving", description: "~1 serving",
                             weightG: nil, weightBasis: ""),
            macros: best.2,
            nutritionStatus: "published",
            referenceImageUrl: nil,
            warnings: ["Values are generic averages, not from today's dining hall menu."],
            allergens: [],
            dietaryTags: []
        )
        let line = EstimatedLine(id: UUID(), item: item, multiplier: 1.0, macros: best.2)
        let total = best.2
        guard [total.caloriesKcal, total.proteinG, total.carbsG, total.fatG].allSatisfy(\.isFinite) else {
            throw PipelineFailure.invalidOutput
        }
        return ScanResult(lines: [line], total: total, lower: nil, upper: nil,
                          isDemo: false, isVisionClassified: true, isGenericFallback: true,
                          isGeminiClassified: false, isNonDiningHallEstimate: false, menuRevision: menuRevision)
    }
}

// MARK: - Generic food database

enum GenericFoodDB {
    static func lookup(_ word: String) -> Macros? { db[word] }

    private static let db: [String: Macros] = [
        "pizza":     Macros(caloriesKcal: 285, proteinG: 12, carbsG: 36, fatG: 10),
        "burger":    Macros(caloriesKcal: 354, proteinG: 20, carbsG: 28, fatG: 17),
        "sandwich":  Macros(caloriesKcal: 310, proteinG: 17, carbsG: 35, fatG: 10),
        "salad":     Macros(caloriesKcal: 150, proteinG:  5, carbsG: 12, fatG:  9),
        "pasta":     Macros(caloriesKcal: 350, proteinG: 12, carbsG: 65, fatG:  5),
        "rice":      Macros(caloriesKcal: 200, proteinG:  4, carbsG: 44, fatG:  0),
        "soup":      Macros(caloriesKcal: 180, proteinG:  8, carbsG: 20, fatG:  6),
        "chicken":   Macros(caloriesKcal: 335, proteinG: 38, carbsG:  0, fatG: 18),
        "beef":      Macros(caloriesKcal: 340, proteinG: 35, carbsG:  0, fatG: 21),
        "fish":      Macros(caloriesKcal: 250, proteinG: 35, carbsG:  0, fatG: 11),
        "salmon":    Macros(caloriesKcal: 280, proteinG: 36, carbsG:  0, fatG: 14),
        "sushi":     Macros(caloriesKcal: 250, proteinG: 10, carbsG: 38, fatG:  6),
        "taco":      Macros(caloriesKcal: 210, proteinG:  9, carbsG: 22, fatG:  9),
        "burrito":   Macros(caloriesKcal: 490, proteinG: 22, carbsG: 65, fatG: 14),
        "steak":     Macros(caloriesKcal: 400, proteinG: 45, carbsG:  0, fatG: 22),
        "noodle":    Macros(caloriesKcal: 320, proteinG: 10, carbsG: 58, fatG:  4),
        "bread":     Macros(caloriesKcal: 265, proteinG:  9, carbsG: 49, fatG:  3),
        "egg":       Macros(caloriesKcal: 220, proteinG: 15, carbsG:  2, fatG: 16),
        "oatmeal":   Macros(caloriesKcal: 160, proteinG:  5, carbsG: 28, fatG:  3),
        "pancake":   Macros(caloriesKcal: 350, proteinG:  8, carbsG: 55, fatG: 11),
        "waffle":    Macros(caloriesKcal: 380, proteinG:  8, carbsG: 58, fatG: 13),
        "cereal":    Macros(caloriesKcal: 250, proteinG:  6, carbsG: 48, fatG:  3),
        "yogurt":    Macros(caloriesKcal: 180, proteinG: 12, carbsG: 26, fatG:  3),
        "fruit":     Macros(caloriesKcal:  80, proteinG:  1, carbsG: 20, fatG:  0),
        "apple":     Macros(caloriesKcal:  95, proteinG:  0, carbsG: 25, fatG:  0),
        "banana":    Macros(caloriesKcal: 105, proteinG:  1, carbsG: 27, fatG:  0),
        "vegetable": Macros(caloriesKcal:  50, proteinG:  2, carbsG: 10, fatG:  0),
        "broccoli":  Macros(caloriesKcal:  55, proteinG:  4, carbsG: 11, fatG:  0),
        "fries":     Macros(caloriesKcal: 365, proteinG:  4, carbsG: 48, fatG: 17),
        "potato":    Macros(caloriesKcal: 170, proteinG:  4, carbsG: 37, fatG:  0),
        "wrap":      Macros(caloriesKcal: 300, proteinG: 15, carbsG: 35, fatG: 10),
        "curry":     Macros(caloriesKcal: 380, proteinG: 20, carbsG: 35, fatG: 15),
        "tofu":      Macros(caloriesKcal: 200, proteinG: 18, carbsG:  8, fatG: 10),
        "poke":      Macros(caloriesKcal: 360, proteinG: 28, carbsG: 38, fatG:  8),
        "bowl":      Macros(caloriesKcal: 400, proteinG: 20, carbsG: 50, fatG: 12),
        "fried":     Macros(caloriesKcal: 380, proteinG: 15, carbsG: 35, fatG: 18),
        "grilled":   Macros(caloriesKcal: 290, proteinG: 30, carbsG: 10, fatG: 12),
        "roasted":   Macros(caloriesKcal: 260, proteinG: 18, carbsG: 25, fatG: 10),
        "smoothie":  Macros(caloriesKcal: 280, proteinG:  8, carbsG: 52, fatG:  4),
        "cake":      Macros(caloriesKcal: 350, proteinG:  4, carbsG: 55, fatG: 14),
        "cookie":    Macros(caloriesKcal: 280, proteinG:  3, carbsG: 42, fatG: 12),
        "muffin":    Macros(caloriesKcal: 340, proteinG:  5, carbsG: 55, fatG: 12),
        "bagel":     Macros(caloriesKcal: 270, proteinG: 11, carbsG: 55, fatG:  1),
        "toast":     Macros(caloriesKcal: 150, proteinG:  5, carbsG: 27, fatG:  2),
        "mac":       Macros(caloriesKcal: 390, proteinG: 12, carbsG: 58, fatG: 14),
        "spaghetti": Macros(caloriesKcal: 350, proteinG: 12, carbsG: 65, fatG:  5),
        "ramen":     Macros(caloriesKcal: 380, proteinG: 12, carbsG: 55, fatG: 11),
        "stir":      Macros(caloriesKcal: 300, proteinG: 18, carbsG: 30, fatG: 12),
    ]
}
