import SwiftUI

/// Step 1: enter an amount in the user's display currency. Big centered
/// amount, secondary USDsui-equivalent line, "MAIN WALLET" pill, custom
/// numpad. No keyboard.
struct SendAmountView: View {
    @Bindable var draft: SendDraft
    var onNext: () -> Void
    var onCancel: () -> Void

    @State private var balance: BalancesDTO?

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 12)

            amountBlock

            Spacer(minLength: 12)

            walletPill
                .padding(.bottom, 18)

            SendNumpad(input: $draft.rawAmount)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            reviewButton
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        .taliseScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { Task { await loadBalance() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .frame(width: 38, height: 38)
                    .glassCircle()
            }
            Spacer()
            MicroLabel(text: "Send", color: TaliseColor.fgMuted).kerning(2.0)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Amount

    private var amountBlock: some View {
        VStack(spacing: 10) {
            // Symbol + number at the SAME font size so the cap-tops
            // and baselines naturally line up. Visual hierarchy comes
            // from weight (.thin symbol vs .medium number) + color
            // (fgMuted vs fg), not from a size delta — that's what
            // produced the misaligned "tiny ₦ next to giant 0" look.
            // Symbol + number live in ONE composed Text so a single
            // width-driven scale-down shrinks BOTH in lockstep (two
            // separate Texts let the number scale while the symbol
            // stayed huge). The symbol is rendered ~0.78× the number
            // size: the Naira/￡/$ glyphs have a taller cap-height than
            // lining digits, so equal point sizes read as an oversized
            // symbol — the smaller size makes their visual heights match.
            amountText
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                // numericText crossfades appearing/disappearing glyphs in
                // place, so the comma slides in cleanly on "999" → "1,000".
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: displayAmount)

            Text(usdsuiSecondary)
                .font(TaliseFont.mono(13, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: usdsuiSecondary)

            // Cross-border only: show what the recipient actually
            // receives in *their* currency. Hidden for same-currency
            // sends (recipientReceiveLine == nil) so the single-currency
            // layout is untouched.
            if let recipientLine = recipientReceiveLine {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TaliseColor.accent)
                    Text(recipientLine)
                        .font(TaliseFont.mono(12, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .contentTransition(.numericText())
                }
                .padding(.top, 1)
                .animation(.snappy(duration: 0.18), value: recipientLine)
            }

            if exceedsBalance {
                MicroLabel(
                    text: "OVER AVAILABLE BALANCE",
                    color: TaliseColor.danger
                )
                .kerning(1.5)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 24)
    }

    /// The big amount as a single composed Text: a muted, slightly-smaller
    /// currency symbol immediately followed by the solid-white figure. One
    /// Text (not an HStack of two) means `minimumScaleFactor` scales the
    /// symbol and digits by the same factor — they can never drift apart.
    private var amountText: Text {
        Text(draft.currency.symbol)
            .font(TaliseFont.heading(56, weight: .thin))
            .foregroundColor(TaliseColor.fgMuted)
        + Text(" ")
            .font(TaliseFont.heading(56, weight: .thin))
        + Text(displayAmount)
            .font(TaliseFont.heading(72, weight: .medium))
            .kerning(-2)
            .foregroundColor(TaliseColor.fg)
    }

    /// What we render inside the big number. Formats the integer part
    /// with thousand-separator commas while preserving the raw decimal
    /// the user has typed — so mid-typing states like "12." stay as
    /// "12." (with the dangling dot) and "1234.5" reads "1,234.5".
    private var displayAmount: String {
        let raw = draft.rawAmount
        if raw.isEmpty { return "0" }
        // Locate the decimal point (if any) and group only the digits
        // to its LEFT. The right side is purely user-controlled — we
        // never reformat what they've typed past the dot.
        if let dotIdx = raw.firstIndex(of: ".") {
            let intPart = String(raw[raw.startIndex..<dotIdx])
            let fracPart = String(raw[raw.index(after: dotIdx)...])
            return "\(groupDigits(intPart)).\(fracPart)"
        }
        return groupDigits(raw)
    }

    /// Insert thousands-separator commas into a pure-digit integer
    /// string. Returns the input unchanged for strings ≤ 3 chars or
    /// for any string containing non-digits (defensive — the input
    /// here is the user's typed amount, but bracket against surprises).
    private func groupDigits(_ s: String) -> String {
        guard s.count > 3, s.allSatisfy({ $0.isNumber }) else { return s }
        var out = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return String(out.reversed())
    }

    /// USDsui equivalent of what's typed, formatted as "1,234.56 USDsui".
    /// Shows "0.00 USDsui" before the user enters anything so the layout
    /// doesn't shift on the first keypress.
    private var usdsuiSecondary: String {
        let amt = typedAmountUsdsui
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        let body = fmt.string(from: NSNumber(value: amt)) ?? "0.00"
        return "\(body) USDsui"
    }

    private var typedAmountUsdsui: Double {
        guard let typed = Double(draft.rawAmount), typed > 0 else { return 0 }
        let rate = CurrencySettings.shared.rates[draft.currency.code] ?? 1
        guard rate > 0 else { return 0 }
        return typed / rate
    }

    /// "Recipient gets ¥15,000" line — present only for cross-border
    /// sends (different recipient currency). Returns nil for same-
    /// currency sends so the secondary block collapses to the existing
    /// single line. Mirrors the post-spread receive figure shown on the
    /// locked-quote block in Review.
    private var recipientReceiveLine: String? {
        guard let recv = draft.liveRecipientReceiveLocal() else { return nil }
        let amount = TaliseCurrency.recipientSymbolic(recv.amount, currency: recv.currency)
        return "Recipient gets \(amount)"
    }

    private var exceedsBalance: Bool {
        guard let have = balance?.usdsui else { return false }
        let amt = typedAmountUsdsui
        return amt > 0 && amt > have
    }

    // MARK: - Wallet pill

    private var walletPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(TaliseColor.greenMint)
                .frame(width: 6, height: 6)
            Text("MAIN WALLET")
                .font(TaliseFont.mono(10, weight: .regular))
                .kerning(1.5)
                .foregroundStyle(TaliseColor.fg)
            if let avail = availableLocal {
                Text("·")
                    .font(TaliseFont.mono(10, weight: .light))
                    .foregroundStyle(TaliseColor.fgDim)
                Text(avail)
                    .font(TaliseFont.mono(10, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCapsule()
    }

    private var availableLocal: String? {
        guard let usdsui = balance?.usdsui else { return nil }
        return TaliseFormat.local2(usdsui)
    }

    // MARK: - Review button

    private var reviewButton: some View {
        Button(action: handleNext) {
            Text("Review")
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
        typedAmountUsdsui > 0 && !exceedsBalance
    }

    private func handleNext() {
        guard canAdvance else { return }
        draft.amountUsdsui = typedAmountUsdsui
        onNext()
    }

    // MARK: - Balance

    private func loadBalance() async {
        do {
            balance = try await APIClient.shared.get("/api/balances")
        } catch {
            balance = nil
        }
    }
}
