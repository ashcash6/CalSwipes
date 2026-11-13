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
                                MessageBubble(message: message).id(message.id)
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

    private var inputBar: some View {
        HStack(spacing: CP.sp8) {
            TextField("Ask anything about dining…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, CP.sp12).padding(.vertical, CP.sp10)
                .background(CP.surface, in: RoundedRectangle(cornerRadius: CP.r20))
                .submitLabel(.send)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || router.isThinking)
            .tint(CP.navy)
        }
        .padding(.horizontal, CP.sp16)
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

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .padding(CP.sp12)
                    .background(CP.navy, in: RoundedRectangle(cornerRadius: CP.r16))
                    .foregroundStyle(.white)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: CP.sp8) {
                Text((try? AttributedString(markdown: message.text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                    .textSelection(.enabled)
                ForEach(message.scanMatches) { m in
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text(m.name)
                        Spacer()
                        Text("\(Int(m.confidence * 100))%").font(.caption).foregroundStyle(CP.textSec)
                    }
                    .font(.subheadline)
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
