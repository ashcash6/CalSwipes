import SwiftUI
import UIKit

@MainActor
struct ScanScreen: View {
    @StateObject private var controller: ScanController
    @StateObject private var camera = CameraService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(request: ScanRequest) {
        _controller = StateObject(wrappedValue: ScanController(request: request))
    }

    var body: some View {
        NavigationStack {
            Group {
                if controller.phase == .camera { captureView }
                else { reviewView }
            }
            .navigationTitle(controller.phase == .camera ? "Photograph your meal" : "Your plate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        controller.close()
                        camera.stop()
                        camera.discardPhoto()
                        dismiss()
                    }
                }
            }
            .onChange(of: camera.photo?.id) { _, _ in
                if let photo = camera.photo {
                    controller.accept(photo)
                    camera.stop()
                }
            }
            .onChange(of: controller.phase) { _, phase in
                if phase == .camera { camera.start() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    camera.stop()
                    if controller.phase == .processing { controller.cancel() }
                } else if phase == .active, controller.phase == .camera { camera.start() }
            }
            .onDisappear {
                camera.stop()
                camera.discardPhoto()
                controller.close()
            }
        }
        .tint(PlateStyle.green)
        .interactiveDismissDisabled(controller.phase == .processing)
    }

    private var captureView: some View {
        VStack(spacing: 18) {
            Text("\(controller.request.menu.hall.title) · \(controller.request.menu.meal.title)")
                .font(.subheadline).foregroundStyle(.secondary)
            ZStack {
                CameraPreview(session: camera.session)
                    .background(.black)
                if camera.status == .ready || camera.status == .capturing {
                    VStack {
                        Spacer()
                        Text("Keep the full plate visible and hold still.")
                            .font(.subheadline.weight(.medium)).padding(12)
                            .background(.ultraThinMaterial, in: Capsule()).padding()
                    }
                } else { cameraStatus }
            }
            .aspectRatio(3/4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .accessibilityLabel("Rear camera preview")
            Text("Your photo stays on this iPhone.")
                .font(.caption).foregroundStyle(.secondary)
            Button { camera.capture() } label: {
                Label(camera.status == .capturing ? "Capturing…" : "Take photo", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(camera.status != .ready)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(PlateStyle.cream)
        .task { camera.start() }
    }

    @ViewBuilder
    private var cameraStatus: some View {
        VStack(spacing: 16) {
            switch camera.status {
            case .denied:
                Image(systemName: "camera.fill").font(.largeTitle)
                Text("Allow camera access in Settings to photograph a meal.").multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(.borderedProminent)
            case .failed(let message):
                Text(message).multilineTextAlignment(.center)
                Button("Try again") { camera.start() }.buttonStyle(.borderedProminent)
            case .interrupted:
                Text("Camera temporarily unavailable. Return here after the interruption ends.").multilineTextAlignment(.center)
            case .requestingPermission: ProgressView("Waiting for camera permission…")
            default: ProgressView("Opening camera…")
            }
        }
        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
    }

    private var reviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let photo = controller.photo {
                    RegionPhotoView(photo: photo, foods: controller.foods, plate: controller.plate,
                        candidate: controller.candidate, points: controller.points, tap: controller.tap)
                }
                switch controller.phase {
                case .processing:
                    ProgressView(controller.message).frame(maxWidth: .infinity).padding()
                    if controller.demoActive { demoNotice }
                    Button("Cancel analysis") { controller.cancel() }.buttonStyle(.bordered)
                case .result:
                    if let result = controller.result { resultView(result) }
                    retakeButton
                case .blocked:
                    Label("Analysis unavailable", systemImage: "info.circle").font(.headline)
                    Text(controller.message).foregroundStyle(.secondary)
                    Button("Start a new outline") { controller.startNewOutline() }.buttonStyle(.bordered)
                    Text("No calorie estimate has been made. This photo is discarded when you close this screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                    retakeButton
                    debugDemoButton
                default:
                    outlineControls
                    retakeButton
                    debugDemoButton
                }
            }
            .padding(20)
        }
        .background(PlateStyle.cream)
    }

    private var outlineControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Outline your meal").font(.title2.bold())
            Text("First outline the plate, then each food. Tap inside an object; add taps to refine it. Check the orange outline before keeping it.")
                .foregroundStyle(.secondary)
            Picker("Object", selection: $controller.selectingPlate) {
                Text("Plate").tag(true)
                Text("Food").tag(false)
            }.pickerStyle(.segmented)
            Toggle("Exclude the next tapped area", isOn: $controller.excludePoint)
            if controller.candidate != nil {
                Button(controller.selectingPlate ? "Keep plate outline" : "Keep food outline") { controller.confirmOutline() }
                    .buttonStyle(.borderedProminent)
                if controller.candidates.count > 1 {
                    Button("Try another outline (\(controller.candidateIndex+1)/\(controller.candidates.count))") { controller.nextCandidate() }
                }
            }
            if !controller.points.isEmpty { Button("Start a new outline") { controller.startNewOutline() } }
            if !controller.message.isEmpty { Text(controller.message).foregroundStyle(.secondary) }
            Text("\(controller.plate == nil ? "No plate kept" : "Plate kept in blue") · \(controller.foods.count) food outlines in green")
                .font(.subheadline)
            ForEach(Array(controller.foods.enumerated()), id: \.element.id) { index, region in
                Button("Remove food outline \(index+1)", role: .destructive) { controller.removeFood(region.id) }
            }
            Text("Outlines do not identify foods or estimate portions yet. No calorie estimate has been made.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var retakeButton: some View {
        Button("Retake photo") {
            camera.discardPhoto()
            controller.retake()
        }.buttonStyle(.bordered)
    }

    @ViewBuilder
    private var debugDemoButton: some View {
        #if DEBUG
        Divider()
        Text("Developer preview").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        Button("Preview example results") { controller.previewDemo() }
            .buttonStyle(.bordered)
            .disabled(controller.request.expected.isEmpty)
        Text("Uses your preselected items at one serving each. It does not inspect the photo. Preselect items in the menu first.")
            .font(.caption).foregroundStyle(.secondary)
        #endif
    }

    private var demoNotice: some View {
        Label("EXAMPLE ONLY — not a photo estimate", systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.bold()).foregroundStyle(.orange)
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func resultView(_ result: ScanResult) -> some View {
        if result.isDemo {
            demoNotice
            Text("These are the published macros for one serving of each preselected item. No portions or confidence range were estimated.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        Text(result.isDemo ? "Example total" : "Estimated total").font(.headline)
        Text("\(result.total.caloriesKcal.formatted(.number.precision(.fractionLength(0)))) kcal")
            .font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(PlateStyle.green)
        VStack(alignment: .leading, spacing: 6) {
            Text("Protein \(result.total.proteinG.formatted(.number.precision(.fractionLength(0...1)))) g")
            Text("Carbs \(result.total.carbsG.formatted(.number.precision(.fractionLength(0...1)))) g")
            Text("Fat \(result.total.fatG.formatted(.number.precision(.fractionLength(0...1)))) g")
        }.font(.subheadline)
        if !result.isDemo, let lower = result.lower, let upper = result.upper {
            Text("Portion range: \(lower.caloriesKcal.formatted(.number.precision(.fractionLength(0))))–\(upper.caloriesKcal.formatted(.number.precision(.fractionLength(0)))) kcal")
                .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(result.lines) { line in
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(line.item.name).font(.headline)
                    Text("\(line.multiplier.formatted()) × published serving").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(line.macros.caloriesKcal.formatted(.number.precision(.fractionLength(0)))) kcal").font(.subheadline)
            }
            .padding().background(.background, in: RoundedRectangle(cornerRadius: 14))
        }
        Text("Not saved to meal history or HealthKit.").font(.footnote).foregroundStyle(.secondary)
    }
}
