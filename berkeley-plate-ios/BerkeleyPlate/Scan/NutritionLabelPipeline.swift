import Foundation
import Vision

struct NutritionLabelResult {
    var calories: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?

    var isComplete: Bool { calories != nil && proteinG != nil && carbsG != nil && fatG != nil }

    var asMacros: Macros? {
        guard let cal = calories else { return nil }
        return Macros(caloriesKcal: cal, proteinG: proteinG ?? 0, carbsG: carbsG ?? 0, fatG: fatG ?? 0)
    }
}

enum NutritionLabelPipeline {
    static func scan(_ image: CGImage) async -> NutritionLabelResult {
        await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: parse(lines: lines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }

    private static func parse(lines: [String]) -> NutritionLabelResult {
        var result = NutritionLabelResult()
        // Join with newlines so multi-line labels still match
        let text = lines.joined(separator: "\n")

        // Calories — exclude "Calories from Fat" (found on older labels)
        result.calories = firstNumber(in: text, pattern: #"(?i)Calories(?!\s+from)\D{0,12}?(\d{1,4})"#)

        // Total Fat
        result.fatG = firstNumber(in: text, pattern: #"(?i)Total Fat\D{0,8}?(\d{1,4}(?:\.\d+)?)"#)

        // Total Carbohydrate (various spellings)
        result.carbsG =
            firstNumber(in: text, pattern: #"(?i)Total Carbohydrate\D{0,8}?(\d{1,4}(?:\.\d+)?)"#) ??
            firstNumber(in: text, pattern: #"(?i)Total Carb\b\D{0,8}?(\d{1,4}(?:\.\d+)?)"#)

        // Protein
        result.proteinG = firstNumber(in: text, pattern: #"(?i)\bProtein\D{0,8}?(\d{1,4}(?:\.\d+)?)"#)

        return result
    }

    private static func firstNumber(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }
}
