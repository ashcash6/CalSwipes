import CoreGraphics
import Foundation

enum PipelineFailure: LocalizedError {
    case unavailable(String), staleMenu, invalidOutput, needsIdentification, metricDepthRequired, missingNutrition
    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return detail
        case .staleMenu: return "Refresh today’s menu before starting a new analysis."
        case .invalidOutput: return "The analysis returned inconsistent data. No estimate was produced."
        case .needsIdentification: return "Some food could not be identified. No total was calculated."
        case .metricDepthRequired: return "Calibrated metric depth is required to estimate portions. This build captures a photo only."
        case .missingNutrition: return "Published nutrition is missing for an item. No total was calculated."
        }
    }
}

struct FoodRegion: Identifiable {
    let id: UUID
    /// Top-left origin; normalized bounds in the upright, prepared photo.
    let bounds: CGRect
    let maskWidth: Int
    let maskHeight: Int
    let mask: [Float]
    func validate() throws {
        guard (1...1024).contains(maskWidth), (1...1024).contains(maskHeight),
              mask.count == maskWidth * maskHeight,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }),
              bounds.width > 0, bounds.height > 0, bounds.minX >= 0, bounds.minY >= 0,
              bounds.maxX <= 1, bounds.maxY <= 1,
              mask.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw PipelineFailure.invalidOutput }
    }
}

struct SegmentedPlate {
    let foods: [FoodRegion]
    let plate: FoodRegion?
}

struct RegionMatch {
    let regionId: UUID
    let menuItemId: String?
    /// Cosine similarity is not a calibrated confidence probability.
    let similarity: Double
}

struct EstimatedServing {
    let regionId: UUID
    let menuItemId: String
    let multiplier: Double
    let lowerMultiplier: Double
    let upperMultiplier: Double
}

struct EstimatedLine: Identifiable {
    let id: UUID
    let item: MenuItem
    let multiplier: Double
    let macros: Macros
}

struct ScanResult {
    let lines: [EstimatedLine]
    let total: Macros
    let lower: Macros?
    let upper: Macros?
    let isDemo: Bool
    let menuRevision: String
}

protocol Segmenting {
    func segment(_ photo: CapturedPhoto) async throws -> SegmentedPlate
}
protocol MenuClassifying {
    func classify(_ regions: [FoodRegion], photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>) async throws -> [RegionMatch]
}
protocol PortionEstimating {
    func estimate(_ regions: [FoodRegion], matches: [RegionMatch], photo: CapturedPhoto, menu: MenuEnvelope) async throws -> [EstimatedServing]
}
protocol ScanAnalyzing {
    func analyze(photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>,
                 progress: @escaping @Sendable (String) async -> Void) async throws -> ScanResult
}

actor ScanPipeline: ScanAnalyzing {
    private let segmentation: any Segmenting
    private let classification: any MenuClassifying
    private let portions: any PortionEstimating
    init(segmentation: any Segmenting = UnavailableStages(), classification: any MenuClassifying = UnavailableStages(),
         portions: any PortionEstimating = UnavailableStages()) {
        self.segmentation = segmentation
        self.classification = classification
        self.portions = portions
    }

    func analyze(photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>,
                 progress: @escaping @Sendable (String) async -> Void) async throws -> ScanResult {
        try Self.validateMenu(menu, capturedAt: photo.capturedAt)
        try Task.checkCancellation()
        await progress("Finding food regions…")
        let segmented = try await segmentation.segment(photo)
        guard !segmented.foods.isEmpty, segmented.foods.count <= 32,
              Set(segmented.foods.map(\.id)).count == segmented.foods.count else { throw PipelineFailure.invalidOutput }
        try segmented.foods.forEach { try $0.validate() }
        try segmented.plate?.validate()
        try Task.checkCancellation()
        await progress("Matching today’s menu…")
        let matches = try await classification.classify(segmented.foods, photo: photo, menu: menu,
            expected: expected.intersection(Set(menu.items.map(\.id))))
        guard matches.count == segmented.foods.count,
              Set(matches.map(\.regionId)) == Set(segmented.foods.map(\.id)),
              matches.allSatisfy({ $0.similarity.isFinite && (-1...1).contains($0.similarity) }) else {
            throw PipelineFailure.invalidOutput
        }
        guard matches.allSatisfy({ match in match.menuItemId.map { id in menu.items.contains { $0.id == id } } ?? false }) else {
            throw PipelineFailure.needsIdentification
        }
        try Task.checkCancellation()
        await progress("Checking portion measurements…")
        // Stage C must replace the RGB-only capture contract with synchronized, calibrated depth.
        guard photo.hasMetricDepth else { throw PipelineFailure.metricDepthRequired }
        let estimates = try await portions.estimate(segmented.foods, matches: matches, photo: photo, menu: menu)
        guard estimates.count == matches.count, Set(estimates.map(\.regionId)) == Set(matches.map(\.regionId)),
              estimates.allSatisfy({ estimate in matches.contains { $0.regionId == estimate.regionId && $0.menuItemId == estimate.menuItemId } }) else {
            throw PipelineFailure.invalidOutput
        }
        try Task.checkCancellation()
        await progress("Adding nutrition…")
        return try NutritionMath.result(estimates, menu: menu)
    }

    static func validateMenu(_ menu: MenuEnvelope, capturedAt: Date, now: Date = Date()) throws {
        guard menu.schemaVersion == 1, menu.status == "published", !menu.items.isEmpty,
              menu.isFresh(at: now), menu.date == BerkeleyClock.serviceDate(capturedAt),
              menu.date == BerkeleyClock.serviceDate(now) else { throw PipelineFailure.staleMenu }
    }
}

struct UnavailableStages: Segmenting, MenuClassifying, PortionEstimating {
    func segment(_ photo: CapturedPhoto) async throws -> SegmentedPlate {
        throw PipelineFailure.unavailable("Food analysis is not installed in this build. Your photo has not been analyzed or uploaded.")
    }
    func classify(_ regions: [FoodRegion], photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>) async throws -> [RegionMatch] {
        throw PipelineFailure.unavailable("Menu classification has not been installed.")
    }
    func estimate(_ regions: [FoodRegion], matches: [RegionMatch], photo: CapturedPhoto, menu: MenuEnvelope) async throws -> [EstimatedServing] {
        throw PipelineFailure.metricDepthRequired
    }
}

enum NutritionMath {
    static let zero = Macros(caloriesKcal: 0, proteinG: 0, carbsG: 0, fatG: 0)
    static func multiply(_ macros: Macros, by factor: Double) -> Macros {
        Macros(caloriesKcal: macros.caloriesKcal * factor, proteinG: macros.proteinG * factor,
               carbsG: macros.carbsG * factor, fatG: macros.fatG * factor)
    }
    static func add(_ lhs: Macros, _ rhs: Macros) -> Macros {
        Macros(caloriesKcal: lhs.caloriesKcal + rhs.caloriesKcal, proteinG: lhs.proteinG + rhs.proteinG,
               carbsG: lhs.carbsG + rhs.carbsG, fatG: lhs.fatG + rhs.fatG)
    }
    static func result(_ estimates: [EstimatedServing], menu: MenuEnvelope) throws -> ScanResult {
        guard !estimates.isEmpty, Set(estimates.map(\.regionId)).count == estimates.count else { throw PipelineFailure.invalidOutput }
        var lines: [EstimatedLine] = []
        var lower = zero, upper = zero
        for estimate in estimates {
            guard [estimate.lowerMultiplier, estimate.multiplier, estimate.upperMultiplier].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 8 }),
                  estimate.lowerMultiplier <= estimate.multiplier, estimate.multiplier <= estimate.upperMultiplier,
                  let item = menu.items.first(where: { $0.id == estimate.menuItemId }) else { throw PipelineFailure.invalidOutput }
            guard item.nutritionStatus == "published", let macros = item.macros else { throw PipelineFailure.missingNutrition }
            guard [macros.caloriesKcal, macros.proteinG, macros.carbsG, macros.fatG].allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw PipelineFailure.invalidOutput }
            lines.append(EstimatedLine(id: estimate.regionId, item: item, multiplier: estimate.multiplier,
                                       macros: multiply(macros, by: estimate.multiplier)))
            lower = add(lower, multiply(macros, by: estimate.lowerMultiplier))
            upper = add(upper, multiply(macros, by: estimate.upperMultiplier))
        }
        let total = lines.reduce(zero) { add($0, $1.macros) }
        guard [total, lower, upper].allSatisfy({ value in
            [value.caloriesKcal, value.proteinG, value.carbsG, value.fatG].allSatisfy(\.isFinite)
        }) else { throw PipelineFailure.invalidOutput }
        return ScanResult(lines: lines, total: total, lower: lower, upper: upper,
                          isDemo: false, menuRevision: menu.revision)
    }
}

#if DEBUG
/// An explicit interface fixture. It does not inspect pixels, identify food or estimate portions.
struct DemoScanPipeline: ScanAnalyzing {
    func analyze(photo: CapturedPhoto, menu: MenuEnvelope, expected: Set<String>,
                 progress: @escaping @Sendable (String) async -> Void) async throws -> ScanResult {
        try ScanPipeline.validateMenu(menu, capturedAt: photo.capturedAt)
        await progress("Preparing example results — no photo analysis…")
        try Task.checkCancellation()
        let selected = menu.items.filter { expected.contains($0.id) }
        guard !selected.isEmpty else { throw PipelineFailure.unavailable("Preselect at least one menu item to preview example results.") }
        let estimates = selected.map { EstimatedServing(regionId: UUID(), menuItemId: $0.id, multiplier: 1, lowerMultiplier: 1, upperMultiplier: 1) }
        let example = try NutritionMath.result(estimates, menu: menu)
        return ScanResult(lines: example.lines, total: example.total, lower: nil, upper: nil, isDemo: true, menuRevision: menu.revision)
    }
}
#endif
