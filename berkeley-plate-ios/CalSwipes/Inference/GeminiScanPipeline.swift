import CoreImage
import Foundation

/// Sends the captured photo to the backend's /v1/scan-meal endpoint, which calls Gemini to
/// classify food against today's Berkeley Dining menu. Nutrition always comes from the local
/// MenuEnvelope — never from Gemini estimates.
///
/// Confidence tiers returned by the backend:
///   "auto"    (≥0.90) — result accepted automatically
///   "confirm" (0.70–0.89) — presented to user for confirmation
///   "ask"     (<0.70)    — user must select the correct item from candidates
actor GeminiScanPipeline: ScanAnalyzing {
    private let api: APIClient

    init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String) ?? ""
        let baseURL = URL(string: configured) ?? URL(string: "https://api.example.invalid")!
        self.api = APIClient(baseURL: baseURL)
    }

    func analyze(photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>, isDiningHall: Bool = true,
                 progress: @escaping @Sendable (String) async -> Void) async throws -> ScanResult {
        try ScanPipeline.validateMenu(menu, capturedAt: photo.capturedAt)
        try Task.checkCancellation()

        if isBlurry(photo.image) {
            throw PipelineFailure.unavailable(
                "Photo looks blurry — hold the camera steady and try again in better light."
            )
        }

        await progress("Identifying food with AI…")

        let body = ScanMealRequest(
            photo: photo.jpegData.base64EncodedString(),
            mimeType: "image/jpeg",
            hall: menu.hall.rawValue,
            date: menu.date,
            meal: menu.meal.rawValue
        )

        let httpResult: HTTPResult
        do {
            httpResult = try await api.post(path: "v1/scan-meal", body: body)
        } catch {
            throw PipelineFailure.unavailable(
                "Could not reach the recognition service. Check your connection and try again."
            )
        }

        let response = try JSONCoding.decoder().decode(ScanMealResponse.self, from: httpResult.data)

        guard !response.matched.isEmpty else {
            let reason = response.noMatchReason ?? "This food doesn't appear to be on today's menu."
            throw PipelineFailure.unavailable(reason)
        }

        return try buildResult(from: response.matched, menu: menu)
    }

    // MARK: - Result construction

    private func buildResult(from matched: [ScanMatchedItem], menu: MenuEnvelope) throws -> ScanResult {
        var lines: [EstimatedLine] = []
        var candidates: [ScanCandidate] = []

        for match in matched {
            guard let item = menu.items.first(where: { $0.id == match.itemId }),
                  item.nutritionStatus == "published",
                  let macros = item.macros else { continue }
            guard [macros.caloriesKcal, macros.proteinG, macros.carbsG, macros.fatG]
                .allSatisfy({ $0.isFinite && $0 >= 0 }) else { continue }

            lines.append(EstimatedLine(id: UUID(), item: item, multiplier: 1.0, macros: macros))

            let alts = match.alternatives.compactMap { alt -> ScanAlternative? in
                guard let altItem = menu.items.first(where: { $0.id == alt.itemId }),
                      altItem.macros != nil else { return nil }
                return ScanAlternative(item: altItem, confidence: alt.confidence)
            }
            candidates.append(ScanCandidate(primaryItem: item, confidence: match.confidence, alternatives: alts))
        }

        guard !lines.isEmpty else { throw PipelineFailure.missingNutrition }

        let total = lines.reduce(NutritionMath.zero) { NutritionMath.add($0, $1.macros) }
        guard [total.caloriesKcal, total.proteinG, total.carbsG, total.fatG].allSatisfy(\.isFinite) else {
            throw PipelineFailure.invalidOutput
        }

        // Overall tier is the worst (lowest-confidence) tier across all matched items.
        let tier = worstTier(matched.map(\.confidenceTier))

        return ScanResult(
            lines: lines, total: total, lower: nil, upper: nil,
            isDemo: false, isVisionClassified: false, isGenericFallback: false,
            isGeminiClassified: true, isNonDiningHallEstimate: false,
            menuRevision: menu.revision,
            confidenceTier: tier,
            candidates: tier == "auto" ? [] : candidates
        )
    }

    private func worstTier(_ tiers: [String]) -> String {
        if tiers.contains("ask") { return "ask" }
        if tiers.contains("confirm") { return "confirm" }
        return "auto"
    }

    // MARK: - Blur detection

    /// Returns true when edge energy is below threshold, indicating a blurry photo.
    private func isBlurry(_ image: CGImage, threshold: Float = 0.018) -> Bool {
        let ci = CIImage(cgImage: image)
        let scale = min(1.0, 300.0 / Double(max(image.width, image.height)))
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let edgeFilter = CIFilter(name: "CIEdges",
                                        parameters: [kCIInputImageKey: small,
                                                     "inputIntensity": NSNumber(value: 10.0)]),
              let edgeOutput = edgeFilter.outputImage,
              let avgFilter = CIFilter(name: "CIAreaAverage",
                                       parameters: [kCIInputImageKey: edgeOutput,
                                                    kCIInputExtentKey: CIVector(cgRect: edgeOutput.extent)]),
              let avgOutput = avgFilter.outputImage else { return false }

        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(avgOutput,
                           toBitmap: &pixel,
                           rowBytes: MemoryLayout<Float>.size * 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        return pixel[0] < threshold
    }
}

// MARK: - Correction logging

extension GeminiScanPipeline {
    func logCorrection(originalItemId: String, correctedItemId: String,
                       photo: CapturedPhoto, menu: MenuEnvelope) async {
        let body = ScanCorrectionRequest(
            hall: menu.hall.rawValue,
            date: menu.date,
            meal: menu.meal.rawValue,
            photoHash: photo.sha256,
            originalItemId: originalItemId,
            correctedItemId: correctedItemId
        )
        _ = try? await api.post(path: "v1/log-correction", body: body)
    }
}
