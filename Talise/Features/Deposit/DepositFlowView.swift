import SwiftUI
import SafariServices

/// Top-level Deposit flow. Replaces the old direct-to-Receive sheet
/// the `+` button used to open. Now lands on a full-page options
/// screen with two paths:
///
///   - Deposit into account → fiat onramp (Stripe). Hosted standalone
///     URL flow at `/api/onramp/hosted-session`; we open the returned
///     `crypto.link.com` URL in `SFSafariViewController` since Stripe
///     ships no first-party iOS SDK for the crypto rail. Apple permits
///     SFSafari for fiat → crypto purchase flows (it's not a digital
///     good purchase under the IAP rules).
///   - Onchain Deposit → embeds the existing `ReceiveView` (QR + Sui
///     address) as a pushed page, not a sheet.
///
/// The whole flow lives inside its own `NavigationStack` so sub-pages
/// PUSH (slide from the trailing edge) instead of slide up — matching
/// the user's request that "those pages should be whole pages, not
/// slide ups."
struct DepositFlowView: View {
    var onClose: () -> Void

    /// "Coming soon" toast for funding paths not yet wired to a backend
    /// (bank/cash rail). Auto-dismisses; never blocks the user.
    @State private var comingSoonToast: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inlineHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // "Deposit with" section — funding paths as large
                        // soft cards (icon disc + title + muted subtitle),
                        // structured like the inspiration's deposit sheet
                        // but in Talise's dark/glass theme + brand greens.
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow(text: "Deposit with")
                                .padding(.leading, 4)

                            // Card on-ramp — LOCKED (2026-06-10): the Stripe
                            // hosted onramp doesn't work in production, so the
                            // path is honest about it ("Soon") instead of
                            // dead-ending the user in a broken Stripe flow.
                            // Re-wire to DepositOnrampView when the onramp is
                            // actually live.
                            Button {
                                showComingSoon("Card top-ups are coming soon.")
                            } label: {
                                FundingPathCard(
                                    icon: "hi.card",
                                    title: "Cash",
                                    subtitle: "Buy USDsui with your bank card",
                                    soon: true
                                )
                            }
                            .buttonStyle(TilePress())

                            // Onchain receive (QR / address). Live.
                            NavigationLink {
                                DepositOnchainView()
                            } label: {
                                FundingPathCard(
                                    icon: "hi.qr",
                                    title: "Crypto",
                                    subtitle: "Receive USDsui to your Talise QR or address"
                                )
                            }
                            .buttonStyle(TilePress())

                            // Bank transfer — Bridge corridors (USD/EUR/GBP…).
                            // Live only once the Bridge account is approved
                            // (RampFlags.bridgeLive); until then it's an honest
                            // "Soon" so we don't dead-end testers in an empty
                            // picker. Flip the flag to open the corridor flow.
                            if RampFlags.bridgeLive {
                                NavigationLink {
                                    AddMoneyCorridorFlow()
                                } label: {
                                    FundingPathCard(
                                        icon: "hi.bank",
                                        title: "Bank transfer",
                                        subtitle: "From your bank — USD, EUR, GBP and more"
                                    )
                                }
                                .buttonStyle(TilePress())
                            } else {
                                Button {
                                    showComingSoon("Bank transfers are coming soon.")
                                } label: {
                                    FundingPathCard(
                                        icon: "hi.bank",
                                        title: "Bank transfer",
                                        subtitle: "From a local bank account — no card needed",
                                        soon: true
                                    )
                                }
                                .buttonStyle(TilePress())
                            }
                        }

                        footer
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
            }
            .background(TaliseColor.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottom) { comingSoonOverlay }
            .animation(.snappy(duration: 0.25), value: comingSoonToast)
        }
        .tint(TaliseColor.fg)
    }

    /// Inline page title — Talise heading font, medium weight, 26pt.
    /// Replaces the system large-title which read as too heavy / too
    /// large against the rest of the surface.
    private var inlineHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("Deposit")
                    .font(TaliseFont.heading(26, weight: .medium))
                    .kerning(-0.6)
                    .foregroundStyle(TaliseColor.fg)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(TaliseColor.surface2))
                }
            }
            Text("Add money to your Talise wallet.")
                .font(TaliseFont.body(14, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    /// Trust footer — reassurance copy under the funding paths, mono
    /// micro-label aesthetic so it sits quietly at the bottom.
    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TaliseColor.fgDim)
            Text("Funds land as USDsui — pegged 1:1 to USD on Sui.")
                .font(TaliseFont.mono(10, weight: .light))
                .kerning(0.2)
                .foregroundStyle(TaliseColor.fgDim)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var comingSoonOverlay: some View {
        if let comingSoonToast {
            Text(comingSoonToast)
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fg)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Capsule().fill(TaliseColor.surface2))
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showComingSoon(_ message: String) {
        comingSoonToast = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            comingSoonToast = nil
        }
    }
}

// MARK: - FundingPathCard
//
// One deposit path — the SAME visual grammar as the Move-money sheet
// (WithdrawFlowView): 42pt squircle IconChip in a soft mint wash, 16pt
// semibold title, muted 12.5 caption, radius-24 card with a hairline ring,
// TilePress feedback. No badge pills — a not-yet-live path gets a quiet
// "Soon" suffix and a dimmed chip instead.

private struct FundingPathCard: View {
    let icon: String              // Hugeicon asset name (Assets/HugeIcons)
    let title: String
    let subtitle: String
    var soon: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            IconChip(icon: icon, tint: soon ? TaliseColor.fgMuted : TaliseColor.greenMint)
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(TaliseFont.heading(16, weight: .semibold))
                        .kerning(-0.3)
                        .foregroundStyle(TaliseColor.fg)
                    if soon {
                        Text("Soon")
                            .font(TaliseFont.mono(10, weight: .regular))
                            .kerning(0.6)
                            .foregroundStyle(TaliseColor.fgDim)
                    }
                }
                Text(subtitle)
                    .font(TaliseFont.body(12.5, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TaliseColor.fgDim)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .opacity(soon ? 0.75 : 1)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}


// MARK: - "Deposit into account" — Stripe Crypto Onramp landing
//
// Visual recipe mirrors Send/Withdraw: black bg, mono amount line,
// monochrome chips, single CTA pill. The chips select a preset USD
// amount; tapping "Custom" promotes the amount line into an editable
// field. Stripe-side hard min is $1 and hard max is $10 000 (Onramp
// limit), which we mirror client-side so the CTA disables instead of
// the Safari sheet erroring out post-tap.

private struct DepositOnrampView: View {
    /// Closes the entire Deposit flow once a purchase completes so the
    /// user lands back on Home (where the balance is about to refresh
    /// from the polling loop below).
    var onClose: () -> Void

    @State private var selected: AmountChoice = .preset(100)
    @State private var customText: String = ""
    @State private var customFocused: Bool = false
    @FocusState private var customFieldFocus: Bool

    @State private var loading = false
    @State private var errorMessage: String?

    // Safari sheet state.
    @State private var safariURL: URL?
    @State private var showingSafari = false

    // Balance-polling state.
    @State private var startingBalance: Double = 0
    @State private var pollingActive = false
    @State private var pollingResult: PollingOutcome?
    @State private var pollingToast: String?

    private enum AmountChoice: Equatable {
        case preset(Int)
        case custom
    }

    private enum PollingOutcome: Equatable {
        case credited(delta: Double)
        case pending
    }

    private let presets: [Int] = [100, 250, 500, 1_000]
    private let minUsd: Double = 1
    // Soft-launch cap. Stripe's first-time-buyer KYC threshold sits just
    // above this, so $2k keeps the onramp friction-free for ~95% of pilot
    // users. Server clamp matches — see api/onramp/hosted-session/route.ts.
    private let maxUsd: Double = 2_000

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                iconHero
                    .padding(.top, 10)

                amountDisplay

                chipsRow
                    .padding(.horizontal, 20)

                if let errorMessage {
                    Text(errorMessage)
                        .font(TaliseFont.body(12, weight: .light))
                        .foregroundStyle(TaliseColor.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                Spacer(minLength: 12)

                payButton
                    .padding(.horizontal, 20)

                footnote
                    .padding(.horizontal, 28)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .navigationTitle("Deposit into account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TaliseColor.bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showingSafari, onDismiss: handleSafariDismiss) {
            if let safariURL {
                SafariView(url: safariURL)
                    .ignoresSafeArea()
            }
        }
        .overlay(alignment: .bottom) {
            if let pollingToast {
                Text(pollingToast)
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fg)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(TaliseColor.surface2))
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: pollingToast)
    }

    // MARK: - Subviews

    private var iconHero: some View {
        ZStack {
            Circle()
                .fill(TaliseColor.greenMint.opacity(0.16))
                .frame(width: 72, height: 72)
            Image(systemName: "creditcard.fill")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(TaliseColor.greenMint)
        }
    }

    /// Big monospace amount line — matches the Send amount aesthetic
    /// (huge symbol + number, secondary descriptor underneath). When the
    /// user is in `.custom`, we promote a TextField in place of the
    /// static number.
    private var amountDisplay: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("$")
                    .font(TaliseFont.heading(56, weight: .thin))
                    .foregroundStyle(TaliseColor.fgMuted)

                if case .custom = selected {
                    // Inline editable amount. The placeholder mirrors
                    // the current preset's would-be value so the field
                    // never reads as totally empty.
                    TextField("", text: $customText, prompt: Text("0").foregroundColor(TaliseColor.fgDim))
                        .focused($customFieldFocus)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.leading)
                        .font(TaliseFont.heading(56, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .frame(minWidth: 60, maxWidth: 220)
                        .fixedSize()
                } else {
                    Text(displayAmount)
                        .font(TaliseFont.heading(56, weight: .medium))
                        .kerning(-1.5)
                        .foregroundStyle(TaliseColor.fg)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.18), value: displayAmount)
                }
            }

            Text("You'll receive USDsui · powered by Stripe")
                .font(TaliseFont.mono(11, weight: .light))
                .kerning(0.6)
                .foregroundStyle(TaliseColor.fgDim)
        }
        .padding(.horizontal, 20)
    }

    private var chipsRow: some View {
        HStack(spacing: 8) {
            ForEach(presets, id: \.self) { value in
                chip(label: "$\(formatGrouped(value))", isSelected: selected == .preset(value)) {
                    selected = .preset(value)
                    customFieldFocus = false
                    errorMessage = nil
                }
            }
            chip(label: "Custom", isSelected: isCustom) {
                if !isCustom {
                    // Seed the custom field with whatever preset was
                    // previously selected so the user doesn't lose the
                    // amount they had picked.
                    if case .preset(let v) = selected {
                        customText = String(v)
                    }
                }
                selected = .custom
                errorMessage = nil
                DispatchQueue.main.async { customFieldFocus = true }
            }
        }
    }

    private func chip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(TaliseFont.heading(13, weight: .medium))
                .foregroundStyle(isSelected ? TaliseColor.bg : TaliseColor.fg)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    Capsule().fill(isSelected ? TaliseColor.fg : TaliseColor.surface2)
                )
        }
        .buttonStyle(.plain)
    }

    private var payButton: some View {
        Button(action: handleBuyTap) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView()
                        .tint(TaliseColor.bg)
                        .scaleEffect(0.9)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TaliseColor.bg)
                }
                Text(loading ? "Opening Stripe…" : "Buy with card · powered by Stripe")
                    .font(TaliseFont.heading(15, weight: .medium))
                    .foregroundStyle(TaliseColor.bg)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(canPay ? TaliseColor.fg : TaliseColor.fg.opacity(0.35))
            .clipShape(Capsule())
        }
        .disabled(!canPay || loading)
    }

    private var footnote: some View {
        VStack(spacing: 4) {
            Text("Card and bank purchases are processed by Stripe.")
            Text("Funds arrive as USDsui in your wallet — usually within 2 minutes.")
        }
        .font(TaliseFont.body(11, weight: .light))
        .foregroundStyle(TaliseColor.fgDim)
        .multilineTextAlignment(.center)
    }

    // MARK: - Derived state

    private var isCustom: Bool {
        if case .custom = selected { return true }
        return false
    }

    /// Numeric amount the user has picked — for chips it's the preset,
    /// for custom it's the parsed text (0 on garbage).
    private var amountUsd: Double {
        switch selected {
        case .preset(let v): return Double(v)
        case .custom:
            // Strip grouping commas (the display formatter inserts them
            // on whole-number runs) then trim. EU users on a decimalPad
            // get "," as their decimal separator; we resolve that by
            // converting the LAST comma to a period if there's no period
            // in the string (e.g. "1500,50" → "1500.50") AFTER stripping
            // any earlier grouping commas.
            var s = customText.trimmingCharacters(in: .whitespaces)
            if !s.contains(".") {
                if let last = s.lastIndex(of: ","),
                   s.distance(from: last, to: s.endIndex) <= 3 {
                    s.replaceSubrange(last...last, with: ".")
                }
            }
            s = s.replacingOccurrences(of: ",", with: "")
            return Double(s) ?? 0
        }
    }

    private var displayAmount: String {
        switch selected {
        case .preset(let v): return formatGrouped(v)
        case .custom:
            // Honour the user's keystrokes (decimals + partial digits)
            // but inject thousands separators on whole-number runs so
            // 1500 reads as "1,500" the moment they pause. `contentTransition`
            // (.numericText()) makes the comma slide in smoothly.
            if customText.isEmpty { return "0" }
            let cleaned = customText.replacingOccurrences(of: ",", with: "")
            if let dot = cleaned.firstIndex(of: ".") {
                let whole = String(cleaned[..<dot])
                let frac = String(cleaned[cleaned.index(after: dot)...])
                if let n = Int(whole) {
                    return "\(formatGrouped(n)).\(frac)"
                }
                return cleaned
            }
            if let n = Int(cleaned) { return formatGrouped(n) }
            return cleaned
        }
    }

    /// Whole-number → `1,000` formatter. Currency style would also add the
    /// `$` and decimals — we keep the symbol + amount separated for the
    /// big mono display.
    private func formatGrouped(_ value: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.groupingSeparator = ","
        fmt.usesGroupingSeparator = true
        return fmt.string(from: NSNumber(value: value)) ?? String(value)
    }

    private var canPay: Bool {
        amountUsd >= minUsd && amountUsd <= maxUsd
    }

    // MARK: - Actions

    private func handleBuyTap() {
        guard canPay else {
            errorMessage = "Enter an amount between $\(formatGrouped(Int(minUsd))) and $\(formatGrouped(Int(maxUsd)))."
            return
        }
        errorMessage = nil
        loading = true
        let amount = amountUsd

        Task {
            // Snapshot the pre-purchase USDsui balance so the polling
            // loop after Safari dismiss can detect the credit.
            do {
                let bal: BalancesDTO = try await APIClient.shared.get("/api/balances")
                startingBalance = bal.usdsui
            } catch {
                // Don't fail the purchase if the balance read fails —
                // we'll skip the credited detection and just show the
                // pending toast.
                startingBalance = 0
            }

            do {
                let resp = try await OnrampAPI.hostedSession(amount: amount)
                guard let url = URL(string: resp.redirectUrl) else {
                    throw APIError.invalidResponse
                }
                safariURL = url
                showingSafari = true
                loading = false
            } catch {
                loading = false
                errorMessage = (error as? APIError)?.userMessage
                    ?? "Couldn't start your purchase. Please try again."
            }
        }
    }

    /// Called when SFSafariViewController is dismissed (user finished,
    /// cancelled, or swiped down). We don't know which — Stripe doesn't
    /// deep-link back into the app for completion — so we poll the
    /// balance for up to 90s and infer credit from a positive delta.
    private func handleSafariDismiss() {
        pollingActive = true
        pollingResult = nil
        pollingToast = "Checking for your deposit…"

        Task { @MainActor in
            let deadline = Date().addingTimeInterval(90)
            let cadence: TimeInterval = 3
            while Date() < deadline && pollingActive {
                let bal: BalancesDTO? = try? await APIClient.shared.get("/api/balances")
                if let bal {
                    let delta = bal.usdsui - startingBalance
                    // Anything above $0.01 means new funds landed. Stripe
                    // charges a fee so the credited USDC is slightly
                    // less than `amountUsd` — never compare against the
                    // requested amount directly.
                    if delta >= 0.01 {
                        pollingActive = false
                        pollingResult = .credited(delta: delta)
                        pollingToast = "Added \(formatUsd(delta)) USDsui to your wallet"
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        onClose()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(cadence * 1_000_000_000))
            }
            // Timed out — funds may still be processing on Stripe's
            // side. Fall back to a softer "we'll keep watching" toast
            // and bounce the user home so they can keep using the app.
            pollingActive = false
            pollingResult = .pending
            pollingToast = "Your purchase is processing — funds usually arrive within 2 minutes."
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            onClose()
        }
    }

    private func formatUsd(_ amount: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        fmt.maximumFractionDigits = 2
        return fmt.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }
}

// MARK: - SafariView (UIViewControllerRepresentable wrapper)

/// Hosts `SFSafariViewController` inside a SwiftUI `.sheet`. We use
/// SFSafari rather than `ASWebAuthenticationSession` because Stripe's
/// crypto onramp completes in-page (no app deep-link callback) — ASWeb
/// is purpose-built for OAuth-style redirect callbacks and gives the
/// user no good signal of progress for a multi-step purchase flow.
/// Apple's App Review guidelines permit SFSafari for fiat → crypto
/// rails since they aren't digital-good IAP.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let cfg = SFSafariViewController.Configuration()
        cfg.entersReaderIfAvailable = false
        cfg.barCollapsingEnabled = false
        let vc = SFSafariViewController(url: url, configuration: cfg)
        vc.dismissButtonStyle = .done
        vc.preferredControlTintColor = UIColor.white
        vc.preferredBarTintColor = UIColor.black
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Onchain landing (unchanged)

/// "Onchain Deposit" landing — full page (not a sheet) showing the
/// user's QR code + Sui address + handle. Reuses the existing
/// `ReceiveView` body so we don't fork the QR rendering / share /
/// copy logic.
private struct DepositOnchainView: View {
    var body: some View {
        ReceiveView()
            .navigationTitle("Onchain Deposit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TaliseColor.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

// MARK: - APIError convenience

private extension APIError {
    /// Friendly one-liner for the inline error label. We unwrap the
    /// server's `error` field when present and fall through to a
    /// generic copy otherwise.
    var userMessage: String {
        switch self {
        case .unauthorized, .noSession:
            return "Please sign in again to continue."
        case .status(_, let message):
            if let m = message, let data = m.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String {
                return err
            }
            return "Stripe rejected the request. Please try again."
        case .transport:
            return "Network hiccup — check your connection and try again."
        case .pinningFailed:
            return "Couldn't verify Talise's server. Try again on a trusted network."
        case .cancelled, .decode, .invalidResponse:
            return "Couldn't start your purchase. Please try again."
        }
    }
}
