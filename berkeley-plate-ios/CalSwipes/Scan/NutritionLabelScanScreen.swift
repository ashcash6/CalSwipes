import SwiftUI

@MainActor
struct NutritionLabelScanScreen: View {
    @StateObject private var camera = CameraService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let onLog: (String, Macros) -> Void

    @State private var phase: Phase = .camera
    @State private var labelResult: NutritionLabelResult?
    @State private var productName = ""
    @State private var logged = false

    private enum Phase { case camera, processing, result, failed }

    var body: some View {
        NavigationStack {
            Group {
                if phase == .camera { cameraView }
                else { reviewView }
            }
            .navigationTitle(phase == .camera ? "Scan nutrition label" : "Nutrition facts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { camera.stop(); dismiss() }
                }
            }
            .onChange(of: camera.photo?.id) { _, _ in
                guard let photo = camera.photo else { return }
                camera.stop()
                Task { await processPhoto(photo.image) }
            }
            .onChange(of: scenePhase) { _, sp in
                if sp == .background { camera.stop() }
                else if sp == .active, phase == .camera { camera.start() }
            }
            .onDisappear { camera.stop(); camera.discardPhoto() }
        }
        .tint(PlateStyle.green)
    }

    // MARK: - Camera view

    private var cameraView: some View {
        VStack(spacing: 18) {
            Text("Point the camera at the Nutrition Facts panel")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

            ZStack {
                CameraPreview(session: camera.session).background(.black)
                if camera.status == .ready || camera.status == .capturing {
                    VStack {
                        Spacer()
                        Text("Hold the label flat and well-lit.")
                            .font(.subheadline.weight(.medium)).padding(12)
                            .background(.ultraThinMaterial, in: Capsule()).padding()
                    }
                }
            }
            .aspectRatio(3/4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .accessibilityLabel("Camera preview for nutrition label scan")

            Text("All text recognition stays on this iPhone.")
                .font(.caption).foregroundStyle(.secondary)

            Button { camera.capture() } label: {
                Label(camera.status == .capturing ? "Capturing…" : "Scan label",
                      systemImage: "barcode.viewfinder")
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

    // MARK: - Review view

    @ViewBuilder
    private var reviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch phase {
                case .processing:
                    ProgressView("Reading nutrition label…")
                        .frame(maxWidth: .infinity).padding(40)

                case .result:
                    if let r = labelResult { resultContent(r) }

                case .failed:
                    VStack(spacing: 16) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Couldn't read the label").font(.headline)
                        Text("Make sure the Nutrition Facts text is in focus, well-lit, and the label is held flat.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(40)
                    scanAnotherButton

                default: EmptyView()
                }
            }
            .padding(20)
        }
        .background(PlateStyle.cream)
    }

    @ViewBuilder
    private func resultContent(_ r: NutritionLabelResult) -> some View {
        Label("Scanned on this iPhone", systemImage: "barcode.viewfinder")
            .font(.subheadline.weight(.medium)).foregroundStyle(PlateStyle.green)

        VStack(alignment: .leading, spacing: 6) {
            Text("Product name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("e.g. David Sunflower Seeds", text: $productName)
                .textFieldStyle(.roundedBorder)
        }

        VStack(spacing: 10) {
            LabelMacroRow(label: "Calories", value: r.calories, unit: "kcal")
            LabelMacroRow(label: "Protein",  value: r.proteinG,  unit: "g")
            LabelMacroRow(label: "Carbs",    value: r.carbsG,    unit: "g")
            LabelMacroRow(label: "Fat",      value: r.fatG,      unit: "g")
        }

        if !r.isComplete {
            Label("Some values weren't detected — the label may be partially obscured or at an angle.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }

        if let macros = r.asMacros {
            if !logged {
                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onLog(productName.isEmpty ? "Packaged Food" : productName, macros)
                    withAnimation { logged = true }
                } label: {
                    Label("Log this food", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(PlateStyle.green)
                    Text("Logged!").font(.headline).foregroundStyle(PlateStyle.green)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(PlateStyle.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }

        scanAnotherButton
    }

    private var scanAnotherButton: some View {
        Button("Scan another label") {
            camera.discardPhoto()
            labelResult = nil
            productName = ""
            logged = false
            phase = .camera
            camera.start()
        }
        .buttonStyle(.bordered)
    }

    // MARK: - OCR

    private func processPhoto(_ image: CGImage) async {
        phase = .processing
        let result = await NutritionLabelPipeline.scan(image)
        labelResult = result
        phase = (result.calories != nil || result.proteinG != nil) ? .result : .failed
    }
}

// MARK: - Row

private struct LabelMacroRow: View {
    let label: String
    let value: Double?
    let unit: String

    var body: some View {
        HStack {
            Text(label).font(.headline)
            Spacer()
            if let v = value {
                Text("\(v.formatted(.number.precision(.fractionLength(0)))) \(unit)")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(PlateStyle.green)
            } else {
                Text("Not detected").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}
