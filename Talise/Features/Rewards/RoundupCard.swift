import SwiftUI

/// Round-up & Save card — Phase 2 of the Rewards refresh.
///
/// Lets the user opt in to auto-saving a small percentage of every
/// outbound send (default 2%, configurable 1-10) to NAVI. Funds stay
/// in their wallet; they earn 5 pts per $1 swept.
///
/// State flow:
///   1. Card renders from `summary.roundup` + `summary.roundupSavedUsd`
///      (read on the parent's `load()`).
///   2. Toggling on/off or sliding the % POSTs to
///      `/api/rewards/roundup` and on success invokes `onChange()` —
///      the parent re-fetches the summary so the displayed values
///      come from the server, not local state. This keeps the
///      "saved via round-up" line and the toggle in lock-step with
///      DB truth.
///
/// The card sits between the lifetime-stats row and the earn-rules
/// card on RewardsView — see the `// ANCHOR: roundup-section` marker.
struct RoundupCard: View {
    /// Latest rewards summary from the parent. May be nil while the
    /// initial fetch is still in flight — the card renders in a
    /// disabled-skeleton state until config lands.
    let summary: RewardsSummary?

    /// Called after a successful config POST so the parent can refetch
    /// `/api/referral/summary` and pick up the new `roundup` + lifetime
    /// numbers. Wrapped in `Task { await load() }` at the call site.
    let onChange: () -> Void

    @State private var pendingToggle: Bool? = nil
    @State private var pendingPercentage: Int? = nil
    @State private var saving = false
    @State private var error: String? = nil

    /// What the UI currently shows — `pendingX` overrides while the
    /// optimistic flip is in flight so the toggle / slider feel instant.
    /// The shadow is held (NOT cleared on the POST response) until the
    /// parent's refetched `summary` actually carries the new value — then
    /// the `onChange` reconciler below drops it seamlessly. Clearing it on
    /// the response (as before) exposed the stale pre-refetch `summary`
    /// for a frame, snapping the toggle back and forth — the reported glitch.
    private var enabled: Bool {
        pendingToggle ?? summary?.roundup?.enabled ?? false
    }
    private var percentage: Int {
        pendingPercentage ?? summary?.roundup?.percentage ?? 2
    }
    private var savedUsd: Double {
        summary?.roundupSavedUsd ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if enabled {
                RowDivider(inset: 18)
                slider
                RowDivider(inset: 18)
                savedLine
            }

            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opacity(enabled ? 1.0 : 0.92)
        .animation(.easeInOut(duration: 0.18), value: enabled)
        // Drop each optimistic shadow ONLY once the parent's refetched
        // summary has caught up to it. Because the incoming value equals
        // the value we're already showing, the clear is invisible — no
        // snap-back to stale server state.
        .onChange(of: summary?.roundup?.enabled) { _, server in
            if let p = pendingToggle, server == p { pendingToggle = nil }
        }
        .onChange(of: summary?.roundup?.percentage) { _, server in
            if let p = pendingPercentage, server == p { pendingPercentage = nil }
        }
    }

    // MARK: - Header (eyebrow + subtitle + toggle)

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ROUND-UP & SAVE")
                    .font(TaliseFont.mono(10, weight: .regular))
                    .tracking(2.0)
                    .foregroundStyle(TaliseColor.fgMuted)
                Text(subtitleCopy)
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // The Toggle drives an optimistic local flip + a backend
            // POST. SwiftUI's binding semantics make a custom Binding
            // the cleanest way to keep the visual instant while the
            // network round-trip completes.
            Toggle(
                "",
                isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        // Stamp the optimistic value SYNCHRONOUSLY before
                        // kicking off the save Task. Without this the
                        // Toggle's binding can re-read `enabled` before
                        // the Task body sets `pendingToggle`, briefly
                        // snapping back to the server value.
                        pendingToggle = newValue
                        Task { await save(enabled: newValue, percentage: nil) }
                    }
                )
            )
            .labelsHidden()
            .tint(TaliseColor.accent)
            .disabled(saving)
        }
    }

    /// One-line subtitle that updates with the current %. When the
    /// toggle is off we still show the default 2% to telegraph what
    /// the user is opting INTO — same copy the prompt called out.
    private var subtitleCopy: String {
        "Auto-save \(percentage)% of every send and earn on the saved balance"
    }

    // MARK: - Slider (% picker)

    private var slider: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("SAVE PERCENTAGE")
                    .font(TaliseFont.mono(10, weight: .regular))
                    .tracking(2.0)
                    .foregroundStyle(TaliseColor.fgMuted)
                Spacer()
                Text("\(percentage)%")
                    .font(TaliseFont.heading(22, weight: .medium))
                    .kerning(-0.8)
                    // White, not green — this is a setting readout, not an
                    // earnings figure. The ONE green hero on this card is the
                    // "Saved via round-up" total below.
                    .foregroundStyle(TaliseColor.fg)
            }
            // Step:1 keeps the slider on integer percents (the backend
            // clamps to 1..10 ints anyway). onEditingChanged fires the
            // POST only on release, so dragging doesn't spam the API.
            Slider(
                value: Binding(
                    get: { Double(percentage) },
                    set: { pendingPercentage = clamp(Int($0.rounded()), 1, 10) }
                ),
                in: 1...10,
                step: 1,
                onEditingChanged: { editing in
                    if !editing, let p = pendingPercentage {
                        Task { await save(enabled: nil, percentage: p) }
                    }
                }
            )
            .tint(TaliseColor.accent)
            .disabled(saving)
        }
    }

    // MARK: - Saved-via-roundup line

    private var savedLine: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SAVED VIA ROUND-UP")
                    .font(TaliseFont.mono(10, weight: .regular))
                    .tracking(2.0)
                    .foregroundStyle(TaliseColor.fgMuted)
                Text(TaliseFormat.local2(savedUsd))
                    .font(TaliseFont.heading(20, weight: .medium))
                    .kerning(-0.8)
                    .foregroundStyle(TaliseColor.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer()
            Image(systemName: "leaf.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(TaliseColor.fgMuted)
        }
    }

    // MARK: - Footer (how-it-works)

    @ViewBuilder
    private var footer: some View {
        // Only show the one-line explainer in the OFF (opt-in) state — once
        // enabled, the slider + "saved via round-up" total already carry the
        // meaning, so the line is redundant. Keeps the active card spare.
        if !enabled {
            Text("Funds stay in your wallet and earn 5 pts per $1 saved.")
                .font(TaliseFont.body(12, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error {
            Text(error)
                .font(TaliseFont.mono(10, weight: .regular))
                .foregroundStyle(TaliseColor.danger)
                .padding(.top, 2)
        }
    }

    // MARK: - Network

    /// POSTs the updated config to `/api/rewards/roundup`. Optimistic:
    /// the pending* state lets the toggle/slider feel instant; on
    /// success we clear pendings + invoke `onChange()` to refetch the
    /// summary; on failure we revert + surface the error inline.
    private func save(enabled: Bool?, percentage: Int?) async {
        if saving { return }
        saving = true
        error = nil
        defer { saving = false }

        // Stage the optimistic value so the UI reflects intent
        // immediately (the explicit assignment also covers the case
        // where the caller passed `enabled` but the toggle was driven
        // by a tap that already set `pendingToggle` to the new value).
        if let enabled { pendingToggle = enabled }
        if let percentage { pendingPercentage = percentage }

        struct Body: Encodable { let enabled: Bool?; let percentage: Int? }
        struct Resp: Decodable { let enabled: Bool; let percentage: Int; let savedUsd: Double }

        do {
            let resp: Resp = try await APIClient.shared.post(
                "/api/rewards/roundup",
                body: Body(enabled: enabled, percentage: percentage)
            )
            // Pin the shadow to the SERVER-CONFIRMED values and keep showing
            // it. The `onChange` reconciler clears it once the parent's
            // refetched summary carries the same value — so the toggle never
            // flickers back to the stale pre-refetch snapshot.
            pendingToggle = resp.enabled
            pendingPercentage = resp.percentage
            onChange()
        } catch {
            // Revert the optimistic flip so the toggle doesn't lie
            // about a state the server didn't accept.
            pendingToggle = nil
            pendingPercentage = nil
            self.error = "Couldn't update — try again."
        }
    }

    private func clamp(_ n: Int, _ lo: Int, _ hi: Int) -> Int {
        max(lo, min(hi, n))
    }
}
