import SwiftUI

/// Plan 12 — the AI finance chat tab.
///
/// Layout (top → bottom):
///   1. Greeting header (time-of-day aware, first-name from /api/me).
///      Subtitle: "Let's make sense of your numbers."
///   2. Scrollable transcript. User bubbles right-aligned in accent green,
///      assistant bubbles left-aligned in surface gray. Auto-scrolls to
///      the newest message as SSE deltas arrive.
///   3. Suggested-prompt chips (only when the transcript is empty AND no
///      stream is in flight — they get out of the way after the first turn).
///   4. "Ask anything" input pill — glass capsule, submit on return.
///
/// Streaming token rendering happens entirely inside `ChatViewModel` —
/// the view just observes `messages` and re-renders. The bottom nav pill
/// from `MainTabView` floats over the input so we add bottom safe padding.
struct ChatTabView: View {
    @Environment(AppSession.self) private var session
    @State private var vm = ChatViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 30)
                .padding(.top, 8)

            transcript

            if vm.messages.isEmpty && !vm.streaming {
                suggestedPrompts
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            inputPill
                .padding(.horizontal, 24)
                // Float above the bottom nav pill (≈ 84pt tall incl. shadow).
                .padding(.bottom, 110)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(TaliseFont.heading(26, weight: .medium))
                .foregroundStyle(TaliseColor.fg)
            Text("Let's make sense of your numbers.")
                .font(TaliseFont.body(14, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let slot: String
        switch hour {
        case 5..<12: slot = "Good morning"
        case 12..<17: slot = "Good afternoon"
        case 17..<22: slot = "Good evening"
        default: slot = "Hey"
        }
        let name = firstName(from: session.phase) ?? "there"
        return "\(slot), \(name)"
    }

    private func firstName(from phase: AppSession.Phase) -> String? {
        let n: String?
        switch phase {
        case .ready(let user): n = user.name
        case .onboarding(let user): n = user.name
        default: n = nil
        }
        guard let raw = n?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw.split(separator: " ").first.map(String.init)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if vm.messages.isEmpty {
                        emptyState
                            .padding(.top, 60)
                    } else {
                        ForEach(vm.messages) { msg in
                            bubble(for: msg).id(msg.id)
                        }
                    }
                    Color.clear.frame(height: 8).id(scrollAnchorId)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
            }
            .onChange(of: vm.messages.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(scrollAnchorId, anchor: .bottom)
                }
            }
            .onChange(of: vm.messages.last?.content) { _, _ in
                // Newest tokens trickling in — keep the tail pinned.
                proxy.scrollTo(scrollAnchorId, anchor: .bottom)
            }
        }
    }

    private let scrollAnchorId = "chat-bottom"

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(TaliseColor.fgDim)
            Text("Ask anything about your money.")
                .font(TaliseFont.body(14, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func bubble(for msg: ChatMessage) -> some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.content + (msg.streaming ? "▍" : ""))
                    .font(TaliseFont.body(15, weight: .regular))
                    .foregroundStyle(msg.role == .user ? Color.black : TaliseColor.fg)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .modifier(BubbleBackground(role: msg.role))
            if msg.role == .assistant { Spacer(minLength: 36) }
        }
    }

    /// User bubbles keep their accent-green fill (brand voice, "your turn");
    /// assistant bubbles get a flat solid surface plate — clean Apple-system
    /// gray, no material/blur.
    private struct BubbleBackground: ViewModifier {
        let role: ChatMessage.Role
        func body(content: Content) -> some View {
            switch role {
            case .user:
                content
                    .background(TaliseColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            case .assistant:
                content
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(TaliseColor.surface)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    // MARK: - Suggested prompts

    private var suggestedPrompts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.suggested, id: \.self) { prompt in
                    LiquidGlassPill(title: prompt) {
                        vm.fillPrompt(prompt)
                        inputFocused = true
                    }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private static let suggested: [String] = [
        "Am I undercharging on fees?",
        "Where's most of my money going?",
        "Should I move more to earnings?",
    ]

    // MARK: - Input pill

    private var inputPill: some View {
        HStack(spacing: 10) {
            TextField(
                "Ask anything",
                text: Binding(
                    get: { vm.input },
                    set: { vm.input = $0 }
                ),
                axis: .horizontal
            )
            .focused($inputFocused)
            .submitLabel(.send)
            .onSubmit { vm.send() }
            .font(TaliseFont.body(15, weight: .regular))
            .foregroundStyle(TaliseColor.fg)
            .tint(TaliseColor.accent)
            .disabled(vm.streaming)

            Button {
                vm.send()
            } label: {
                Image(systemName: vm.streaming ? "ellipsis" : "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(
                            vm.input.isEmpty || vm.streaming
                                ? TaliseColor.fgDim
                                : TaliseColor.accent
                        )
                    )
            }
            .buttonStyle(.plain)
            .disabled(vm.input.isEmpty || vm.streaming)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Capsule().fill(TaliseColor.surface2))
        .clipShape(Capsule())
    }
}
