import Foundation

/// Sends the captured photo to the backend's /v1/scan-meal endpoint, which calls
/// Gemini to identify food and estimate portion sizes against today's menu.
/// Falls back to VisionClassifyPipeline when the backend returns no confident match
/// or is unreachable.
actor GeminiScanPipeline: ScanAnalyzing {
    private let api: APIClient
    private let fallback = VisionClassifyPipeline()

    init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String) ?? ""
        let baseURL = URL(string: configured) ?? URL(string: "https://api.example.invalid")!
        self.api = APIClient(baseURL: baseURL)
    }

    func analyze(photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>,
                 progress: @escaping @Sendable (String) async -> Void) async throws -> ScanResult {
        try ScanPipeline.validateMenu(menu, capturedAt: photo.capturedAt)
        try Task.checkCancellation()
        await progress("Identifying food with AI…")

        if let result = try await attemptGemini(photo: photo, menu: menu) {
            return result
        }

        try Task.checkCancellation()
        await progress("Trying on-device recognition…")
        return try await fallback.analyze(photo: photo, menu: menu, expected: expected, progress: progress)
    }

    // Returns nil when Gemini finds no confident match, so the caller falls back to Vision.
    private func attemptGemini(photo: CapturedPhoto, menu: MenuEnvelope) async throws -> ScanResult? {
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
            // Network or server error — silently fall through to Vision
            return nil
        }

        let response = try JSONCoding.decoder().decode(ScanMealResponse.self, from: httpResult.data)
        guard !response.matched.isEmpty else { return nil }

        var lines: [EstimatedLine] = []
        for match in response.matched {
            guard let item = menu.items.first(where: { $0.id == match.itemId }),
                  let macros = match.adjustedMacros else { continue }
            guard [macros.caloriesKcal, macros.proteinG, macros.carbsG, macros.fatG]
                .allSatisfy({ $0.isFinite && $0 >= 0 }) else { continue }
            lines.append(EstimatedLine(id: UUID(), item: item,
                                       multiplier: match.portionMultiplier, macros: macros))
        }
        guard !lines.isEmpty else { return nil }

        let total = lines.reduce(NutritionMath.zero) { NutritionMath.add($0, $1.macros) }
        guard [total.caloriesKcal, total.proteinG, total.carbsG, total.fatG].allSatisfy(\.isFinite) else {
            return nil
        }
        return ScanResult(lines: lines, total: total, lower: nil, upper: nil,
                          isDemo: false, isVisionClassified: false, isGenericFallback: false,
                          isGeminiClassified: true, menuRevision: menu.revision)
    }
}
