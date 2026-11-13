import PhotosUI
import SwiftUI

/// The assistant chat sheet: quick-action chips (Tier 1), free text (Tier 2/3), and tray scan (Tier 3).
struct AssistantChatView: View {
    @Bindable var router: AssistantRouter
    var subscription: SubscriptionStore
    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: CP.sp12) {
                            header
                            ForEach(router.messages) { message in
                                MessageBubble(message: message, onLogScan: { router.logScan($0) }).id(message.id)
                            }
                            if router.isThinking {
                                HStack(spacing: CP.sp8) {
                                    ProgressView()
                                    Text(router.thinkingLabel).font(.subheadline).foregroundStyle(CP.textSec)
                                }
                                .padding(CP.sp12)
                                .background(CP.textSec.opacity(0.08), in: RoundedRectangle(cornerRadius: CP.r16))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("thinking")
                            }
                        }
                        .padding(CP.sp16)
                    }
                    .onChange(of: router.isThinking) { _, thinking in
                        if thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                    }
                    .onChange(of: router.messages.count) { _, _ in
                        if let last = router.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                chips
                inputBar
            }
            .background(CP.bg)
            .navigationTitle("Ask CalSwipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.7) {
                        await router.scan(jpeg: jpeg)
                    }
                    photoItem = nil
                }
            }
            .alert("Use CalSwipes AI?", isPresented: $router.showConsent) {
                Button("Allow") { router.grantConsent() }
                Button("Not now", role: .cancel) { router.declineConsent() }
            } message: {
                Text("To answer this, your question (or tray photo) and the dining hall and meal you picked are sent to Google's Gemini AI through CalSwipes' server. Nothing else about you is shared. You can keep using the quick buttons without AI.")
            }
            .sheet(isPresented: $router.showPaywall) {
                CalSwipesPlusPaywall(subscription: subscription)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CP.sp8) {
            if let summary = router.context.mealSummary {
                Text("Asking about").font(.caption.weight(.semibold)).foregroundStyle(CP.textSec)
                Text(summary).font(.subheadline).padding(CP.sp12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r12))
            } else if router.messages.isEmpty {
                Text("Ask about today's menus, your macros, or snap your tray.")
                    .font(.subheadline).foregroundStyle(CP.textSec)
                Label(router.onDeviceAvailable ? "On-device AI is on: most questions never leave your phone."
                                               : "Quick actions work offline. Other questions use the cloud assistant.",
                      systemImage: router.onDeviceAvailable ? "iphone" : "bolt.fill")
                    .font(.caption).foregroundStyle(CP.textSec)
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CP.sp8) {
                ForEach(router.mealQuestions, id: \.self) { q in
                    Chip(title: q, icon: "questionmark.bubble") { Task { await router.send(q) } }
                }
                ForEach(router.quickActions) { action in
                    Chip(title: action.title, icon: action.icon) {
                        if action == .scanTray { showPhotoPicker = true }
                        Task { await router.tap(action) }
                    }
                }
            }
            .padding(.horizontal, CP.sp16)
            .padding(.vertical, CP.sp8)
        }
        .disabled(router.isThinking)
    }

    private var inputPlaceholder: String {
        if router.isThinking { return "Getting your answer…" }
        if router.cloudRemaining == 0 { return "Out of AI answers today. Try the buttons above" }
        return "Ask anything about dining…"
    }

    @ViewBuilder
    private var quotaLine: some View {
        if let left = router.cloudRemaining {
            Label(left == 0 ? "No AI answers left today · the quick buttons above are free"
                            : "\(left) AI answer\(left == 1 ? "" : "s") left today · quick buttons are free",
                  systemImage: left == 0 ? "exclamationmark.circle" : "sparkles")
                .font(.caption)
                .foregroundStyle(left == 0 ? Color.orange : CP.textSec)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CP.sp16)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
        quotaLine
        HStack(spacing: CP.sp8) {
            TextField(inputPlaceholder, text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, CP.sp12).padding(.vertical, CP.sp10)
                .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r20))
                .submitLabel(.send)
                .onSubmit(submit)
                .disabled(router.isThinking)
                .opacity(router.isThinking ? 0.6 : 1)
            if router.isThinking {
                ProgressView().frame(width: 34, height: 34)
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .tint(CP.navy)
            }
        }
        .padding(.horizontal, CP.sp16)
        }
        .padding(.vertical, CP.sp10)
        .background(.regularMaterial)
    }

    private func submit() {
        let text = draft
        draft = ""
        Task { await router.send(text) }
    }
}

private struct Chip: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, CP.sp12).padding(.vertical, CP.sp8)
                .background(CP.navy.opacity(0.1), in: Capsule())
                .foregroundStyle(CP.navy)
        }
        .buttonStyle(.plain)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var onLogScan: (([(ScanMatch, Double)]) -> Bool)? = nil

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .padding(CP.sp12)
                    .background(CP.navy, in: RoundedRectangle(cornerRadius: CP.r16))
                    .foregroundStyle(CP.onAccent)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: CP.sp8) {
                Text((try? AttributedString(markdown: message.text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                    .textSelection(.enabled)
                if !message.scanMatches.isEmpty, let onLogScan {
                    ScanResultCard(matches: message.scanMatches, onLog: onLogScan)
                }
                if !message.citations.isEmpty {
                    Text("Sources: " + message.citations.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(CP.textSec)
                }
                if let tier = message.tier {
                    Label(tier.label, systemImage: tier.icon).font(.caption2).foregroundStyle(CP.textSec)
                }
            }
            .padding(CP.sp12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r16))
        case .system:
            Label(message.text, systemImage: "info.circle")
                .font(.footnote).foregroundStyle(CP.textSec)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
    }
}


/// Tray-scan results: check items on/off, adjust estimated servings, see totals, log.
private struct ScanResultCard: View {
    let matches: [ScanMatch]
    let onLog: ([(ScanMatch, Double)]) -> Bool
    @State private var servings: [String: Double] = [:]
    @State private var included: Set<String> = []
    @State private var logged = false

    private func amount(_ m: ScanMatch) -> Double { servings[m.id] ?? m.servings ?? 1 }

    private var picks: [(ScanMatch, Double)] {
        matches.filter { included.contains($0.id) }.map { ($0, amount($0)) }
    }

    private var totalKcal: Int {
        Int(picks.reduce(0) { $0 + ($1.0.macros?.caloriesKcal ?? 0) * $1.1 }.rounded())
    }
    private var totalProtein: Int {
        Int(picks.reduce(0) { $0 + ($1.0.macros?.proteinG ?? 0) * $1.1 }.rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CP.sp8) {
            ForEach(matches) { m in
                HStack(spacing: CP.sp8) {
                    Button {
                        if included.contains(m.id) { included.remove(m.id) } else { included.insert(m.id) }
                    } label: {
                        Image(systemName: included.contains(m.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(included.contains(m.id) ? CP.navy : CP.textSec)
                    }
                    .buttonStyle(.plain)
                    .disabled(logged)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name).font(.subheadline)
                        Text(detail(m)).font(.caption).foregroundStyle(CP.textSec)
                    }
                    Spacer()
                    Stepper(value: Binding(get: { amount(m) }, set: { servings[m.id] = $0 }),
                            in: 0.5...4, step: 0.5) {
                        Text("\(amount(m).formatted())×").font(.subheadline.monospacedDigit())
                    }
                    .fixedSize()
                    .disabled(logged || !included.contains(m.id))
                }
            }
            HStack {
                Text("Total: \(totalKcal) kcal · \(totalProtein)g protein")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(logged ? "Logged" : "Log meal") {
                    if onLog(picks) { logged = true }
                }
                .buttonStyle(.borderedProminent)
                .tint(CP.navy)
                .disabled(logged || picks.isEmpty)
            }
            Text("Servings are estimates from the photo. Adjust before logging.")
                .font(.caption2).foregroundStyle(CP.textSec)
        }
        .padding(CP.sp12)
        .background(CP.textSec.opacity(0.08), in: RoundedRectangle(cornerRadius: CP.r16))
        .onAppear {
            // Pre-check confident matches; leave "maybe" ones for the user to tick.
            if included.isEmpty { included = Set(matches.filter { $0.confidence >= 0.5 }.map(\.id)) }
        }
    }

    private func detail(_ m: ScanMatch) -> String {
        var parts: [String] = []
        if let s = m.serving { parts.append("per \(s)") }
        if let k = m.macros?.caloriesKcal { parts.append("\(Int((k * amount(m)).rounded())) kcal") }
        if m.confidence < 0.5 { parts.append("not sure") }
        return parts.joined(separator: " · ")
    }
}
