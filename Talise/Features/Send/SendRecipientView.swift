import SwiftUI

/// Step 2: pick a recipient. Text input at the top + recent contacts
/// from /api/contacts. Tapping a contact auto-resolves and advances; the
/// "Next" button is the keyboard-only path for hand-typed addresses.
struct SendRecipientView: View {
    @Bindable var draft: SendDraft
    var onNext: () -> Void
    var onBack: () -> Void
    /// Closes the entire Send flow. Used by the off-ramp "Their bank" payout
    /// path, which settles in its own sheet and then dismisses Send wholesale
    /// rather than continuing to the on-chain review/sending steps.
    var onClose: () -> Void
    /// Off-ramp "Their bank" (NGN, PUBLIC) payout is allowed in the normal Send
    /// flow but MUST be suppressed in the shielded private-send flow — a public
    /// bank transfer there would contradict the privacy guarantee and tear down
    /// the flow. PrivateSendFlowView passes `false`.
    var allowBankPayout: Bool = true

    @State private var contacts: [ContactDTO] = []
    @State private var loadingContacts = true
    @State private var resolving = false
    @State private var resolveTask: Task<Void, Never>?
    /// Identifies the in-flight contact-pick bank enrichment. A manual "Next"
    /// (or a different pick) clears it so the async auto-advance can't fire
    /// after the user has already moved on.
    @State private var pendingPickToken: UUID?
    /// Set by `pickContact` so the next `onChange(of: recipientInput)`
    /// skips its scheduleResolve call. Without this, picking a contact
    /// also fires a name-based server resolve that races the
    /// authoritative address set by the pick — typically clobbering it.
    @State private var suppressNextResolve = false
    @FocusState private var inputFocused: Bool

    /// Off-ramp Phase 3: when the resolved recipient has a primary linked
    /// bank, the user can choose to pay them in NGN instead of on-chain.
    /// `.onchain` keeps the existing flow untouched; `.bank` presents the
    /// `SendToBankView` payout sheet.
    private enum PayMode { case onchain, bank }
    @State private var payMode: PayMode = .onchain
    @State private var showBankSheet = false

    /// True only when the resolved recipient has a PRIMARY bank — gates the
    /// segmented control. No bank → Send works exactly as today (no toggle).
    private var recipientHasBank: Bool {
        allowBankPayout && draft.resolved?.recipientBank?.hasPrimary == true
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            inputCard
                .padding(.horizontal, 24)
                .padding(.top, 16)

            resolveStatus
                .padding(.horizontal, 28)
                .padding(.top, 8)

            if recipientHasBank {
                payModeToggle
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            }

            Eyebrow(text: "Recent")
                .padding(.horizontal, 28)
                .padding(.top, 26)

            contactsList

            Spacer(minLength: 0)

            nextButton
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        .taliseScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            inputFocused = true
            Task { await loadContacts() }

            // Pick up the recipient prefill (set by ContactsSheet on Home)
            // exactly once so a fresh visit doesn't accidentally re-seed.
            let key = "io.talise.send.prefillRecipient"
            if let prefill = UserDefaults.standard.string(forKey: key),
               !prefill.isEmpty,
               draft.recipientInput.isEmpty {
                draft.recipientInput = prefill
                scheduleResolve(prefill)
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        .onDisappear {
            inputFocused = false
            resolveTask?.cancel()
        }
        // A changed recipient resets the pay-mode back to on-chain so the
        // toggle never carries a stale "Their bank" choice onto a different
        // person (or one with no primary bank).
        .onChange(of: draft.resolved?.address) { _, _ in
            payMode = .onchain
        }
        .sheet(isPresented: $showBankSheet) {
            if let r = draft.resolved, let bank = r.recipientBank, bank.hasPrimary {
                SendToBankView(
                    recipient: bankRecipientArg(r),
                    recipientDisplay: r.displayName ?? shortAddress(r.address),
                    bankLabel: bank.label,
                    onDone: {
                        // Bank payout completed (or cancelled) — close the
                        // whole Send flow so the user lands back on Home.
                        showBankSheet = false
                        onClose()
                    }
                )
            }
        }
    }

    /// What to forward to `/api/offramp/linq/to-user` as `recipient`. Prefer
    /// the typed @handle the user resolved against (so the server re-resolves
    /// the primary bank by handle); fall back to the resolved address.
    private func bankRecipientArg(_ r: RecipientResolution) -> String {
        let typed = draft.recipientInput.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? r.address : typed
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TaliseColor.fg)
                    .frame(width: 38, height: 38)
                    .glassCircle()
            }
            Spacer()
            MicroLabel(text: "Send to", color: TaliseColor.fgMuted).kerning(2.0)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel(text: "To", color: TaliseColor.fgDim).kerning(1.5)
            TextField(
                "alice / 0x6487… / +44 7…",
                text: $draft.recipientInput
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .textContentType(.username)
            .keyboardType(.asciiCapable)
            .font(TaliseFont.body(17, weight: .regular))
            .foregroundStyle(TaliseColor.fg)
            .tint(TaliseColor.accent)
            .focused($inputFocused)
            .onChange(of: draft.recipientInput) { _, new in
                // Don't re-resolve when `pickContact` programmatically
                // sets the input — it already set `draft.resolved` with
                // the authoritative address, and re-resolving on the
                // contact's *name* would either fail or return a
                // different result, clobbering the pick. `pickContact`
                // raises this flag for one onChange cycle.
                if suppressNextResolve {
                    suppressNextResolve = false
                    return
                }
                scheduleResolve(new)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TaliseColor.surface)
        )
    }

    @ViewBuilder
    private var resolveStatus: some View {
        if resolving {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(TaliseColor.fgDim)
                MicroLabel(text: "Resolving…", color: TaliseColor.fgDim)
                Spacer()
            }
        } else if let r = draft.resolved {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TaliseColor.greenMint)
                Text(r.displayName ?? r.address)
                    .font(TaliseFont.mono(11, weight: .light))
                    .foregroundStyle(TaliseColor.greenMint)
                Text(shortAddress(r.address))
                    .font(TaliseFont.mono(10, weight: .light))
                    .foregroundStyle(TaliseColor.fgDim)
                Spacer()
            }
        } else if draft.recipientInput.count >= 3 {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(TaliseColor.danger)
                Text("No match yet for \"\(draft.recipientInput)\"")
                    .font(TaliseFont.mono(11, weight: .light))
                    .foregroundStyle(TaliseColor.danger)
                Spacer()
            }
        } else {
            Color.clear.frame(height: 14)
        }
    }

    // MARK: - Pay mode toggle (off-ramp Phase 3)

    /// Segmented control shown only when the resolved recipient has a primary
    /// linked bank: [On-chain · instant] vs [Their bank · NGN].
    private var payModeToggle: some View {
        HStack(spacing: 4) {
            payModeTab(.onchain, title: "On-chain", sub: "in seconds")
            payModeTab(.bank, title: "Their bank", sub: "NGN")
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(TaliseColor.surface)
        )
    }

    private func payModeTab(_ mode: PayMode, title: String, sub: String) -> some View {
        let selected = payMode == mode
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { payMode = mode }
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(TaliseFont.heading(14, weight: .medium))
                    .foregroundStyle(selected ? Color(hex: 0x0A140C) : TaliseColor.fg)
                Text(sub)
                    .font(TaliseFont.mono(10, weight: .light))
                    .foregroundStyle(selected ? Color(hex: 0x0A140C).opacity(0.6) : TaliseColor.fgMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? TaliseColor.greenMint : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Contacts

    private var contactsList: some View {
        Group {
            if loadingContacts {
                HStack {
                    ProgressView().controlSize(.small).tint(TaliseColor.fgDim)
                    Text("Loading contacts…")
                        .font(TaliseFont.mono(11, weight: .light))
                        .foregroundStyle(TaliseColor.fgDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 12)
            } else if contacts.isEmpty {
                Text("No recent recipients yet — your first send will appear here.")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgDim)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(contacts) { c in
                            contactRow(c)
                            if c.id != contacts.last?.id {
                                LiquidGlassDivider(inset: 70)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private func contactRow(_ c: ContactDTO) -> some View {
        Button {
            pickContact(c)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(TaliseColor.surface2)
                        .frame(width: 38, height: 38)
                    Text(initials(for: c))
                        .font(TaliseFont.heading(13, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.display)
                        .font(TaliseFont.body(15, weight: .regular))
                        .foregroundStyle(TaliseColor.fg)
                    Text(shortAddress(c.address))
                        .font(TaliseFont.mono(10, weight: .light))
                        .foregroundStyle(TaliseColor.fgDim)
                }
                Spacer()
                if c.sentCount > 0 {
                    Text("\(c.sentCount) sent")
                        .font(TaliseFont.mono(10, weight: .light))
                        .foregroundStyle(TaliseColor.fgDim)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func initials(for c: ContactDTO) -> String {
        let src = c.name ?? c.address
        let cleaned = src.replacingOccurrences(of: "@talise.sui", with: "")
            .replacingOccurrences(of: ".sui", with: "")
        let parts = cleaned.split(separator: " ")
        if parts.count >= 2,
           let a = parts[0].first, let b = parts[1].first {
            return "\(a)\(b)".uppercased()
        }
        let trimmed = cleaned.drop(while: { $0 == "0" || $0 == "x" })
        return String(trimmed.prefix(2)).uppercased()
    }

    private func pickContact(_ c: ContactDTO) {
        // Cancel any in-flight resolve and raise the suppression flag
        // BEFORE writing recipientInput — otherwise the onChange handler
        // re-resolves on the contact's *name* and clobbers the
        // authoritative address we're about to set.
        resolveTask?.cancel()
        resolving = false
        suppressNextResolve = true

        draft.recipientInput = c.name ?? c.address
        // Optimistic resolution so the recipient shows instantly.
        draft.resolved = RecipientResolution(
            address: c.address,
            displayName: c.name ?? shortAddress(c.address),
            display: nil,
            source: "contact"
        )
        draft.previousSendsToRecipient = c.sentCount
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        inputFocused = false

        // Enrich with the recipient's payout bank (a contact pick carries no
        // bank info). If they have a primary bank connected, STAY on this
        // screen so the "Their bank" rail pops up; otherwise continue straight
        // through as before. The token guards against the async branch firing
        // after the user has already tapped Next.
        let token = UUID()
        pendingPickToken = token
        resolveTask?.cancel()
        resolveTask = Task {
            let enriched = await resolveRecipientFull(c.address)
            if Task.isCancelled || pendingPickToken != token { return }
            if let enriched, enriched.recipientBank?.hasPrimary == true {
                draft.resolved = enriched
                pendingPickToken = nil
                // Stay — the rail toggle is now visible.
            } else {
                pendingPickToken = nil
                onNext()
            }
        }
    }

    /// Resolve a recipient through the server so the response carries the
    /// masked PRIMARY payout bank (`recipientBank`). Accepts a @handle or a raw
    /// address (the resolve route derives the bank from the address). Returns
    /// nil on any failure — the caller falls back to the on-chain-only flow.
    private func resolveRecipientFull(_ q: String) async -> RecipientResolution? {
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return try? await APIClient.shared.get("/api/recipient/resolve?q=\(encoded)")
    }

    // MARK: - Next button

    private var nextButton: some View {
        Button(action: {
            guard canAdvance else { return }
            // A manual Next cancels any pending contact-pick auto-advance so it
            // can't double-fire navigation after this tap.
            pendingPickToken = nil
            inputFocused = false
            // "Their bank" branches into the NGN off-ramp payout sheet; it
            // settles there and closes the whole flow. "On-chain" (the
            // default, and the only option when there's no primary bank)
            // continues to the existing review step — unchanged.
            if recipientHasBank && payMode == .bank {
                showBankSheet = true
            } else {
                onNext()
            }
        }) {
            Text(recipientHasBank && payMode == .bank ? "Pay their bank" : "Next")
                .font(TaliseFont.heading(16, weight: .medium))
                .foregroundStyle(canAdvance ? Color(hex: 0x0A140C) : TaliseColor.fgDim)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    Capsule()
                        .fill(canAdvance ? TaliseColor.greenMint : TaliseColor.surface2)
                )
        }
        .disabled(!canAdvance)
    }

    private var canAdvance: Bool {
        draft.resolved != nil
    }

    // MARK: - Resolve

    private func scheduleResolve(_ input: String) {
        resolveTask?.cancel()
        draft.resolved = nil
        let q = input.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { resolving = false; return }
        if let addr = SuiAddress(q) {
            draft.resolved = RecipientResolution(
                address: addr.raw,
                displayName: addr.short,
                display: nil,
                source: "address"
            )
            resolving = false
            // Enrich with the recipient's payout bank so the "Their bank" rail
            // appears for a pasted address too — not just typed @handles.
            resolveTask = Task {
                let enriched = await resolveRecipientFull(addr.raw)
                if Task.isCancelled { return }
                if let enriched, enriched.recipientBank?.hasPrimary == true,
                   draft.resolved?.address == addr.raw {
                    draft.resolved = enriched
                }
            }
            return
        }
        resolving = true
        resolveTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            do {
                let encoded = q.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed
                ) ?? q
                let r: RecipientResolution = try await APIClient.shared.get(
                    "/api/recipient/resolve?q=\(encoded)"
                )
                if Task.isCancelled { return }
                draft.resolved = r
                // Carry over historical sent-count if this address is in
                // our contacts list — keeps the "N previous sends" hint
                // working for typed addresses, not just contact picks.
                if let match = contacts.first(where: { $0.address == r.address }) {
                    draft.previousSendsToRecipient = match.sentCount
                } else {
                    draft.previousSendsToRecipient = nil
                }
            } catch {
                if Task.isCancelled { return }
                draft.resolved = nil
            }
            resolving = false
        }
    }

    private func loadContacts() async {
        do {
            let r: ContactsResponse = try await APIClient.shared.get("/api/contacts")
            contacts = r.contacts
        } catch {
            contacts = []
        }
        loadingContacts = false
    }

    private func shortAddress(_ a: String) -> String {
        guard a.count > 14 else { return a }
        return String(a.prefix(8)) + "…" + String(a.suffix(6))
    }
}
