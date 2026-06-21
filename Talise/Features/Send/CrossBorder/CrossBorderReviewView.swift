import SwiftUI

/// Step 3 of the cross-border flow: the transparent, server-locked quote.
///
/// Everything here is rendered from `draft.quote` (the authoritative
/// response from `POST /api/transfers/cross-border/quote`) — the client
/// does NO FX math. Shows:
///   • "You send X <srcCcy>"
///   • "Recipient gets Y <destCcy>"  (the headline, guaranteed figure)
///   • the locked rate (1 src = N dest)
///   • the spread expressed as an explicit fee line
///   • a per-tx cap notice when the corridor is capped
///   • a "Rate held Ns" countdown to `quote.expiresAt` — at 0 we re-quote
///
/// SlideToConfirm commits the held quote via the parent's `onConfirm`,
/// which posts `POST /api/transfers/cross-border/confirm`.
struct CrossBorderReviewView: View {
    @Bindable var draft: CrossBorderDraft
    var onConfirm: () async -> Void
    /// Re-fetch a fresh quote (parent owns the network call). Invoked when
    /// the held rate lapses.
    var onReprice: () async -> Void
    var onBack: () -> Void

    @Environment(AppSession.self) private var session

    /// Seconds left on the held rate, derived from `quote.expiresAt`.
    @State private var secondsLeft: Int = 0
    /// True while a re-quote is in flight (slide disabled).
    @State private var repricing = false
    /// Forces SlideToConfirm back to start if a transient confirm error
    /// keeps this view mounted.
    @State private var resetSlide = false

    private let countdown = Timer.publish(every: 1, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 18) {
                    titleBlock.padding(.top, 10)

                    if let quote = draft.quote {
                        youSendCard(quote)
                        arrow
                        recipientCard(quote)
                        lockedQuoteBlock(quote)
                        if let capNote = capNotice(quote) {
                            capNoticeRow(capNote)
                        }
                    } else {
                        // Shouldn't happen — Amount step guards on a quote
                        // before pushing here. Defensive placeholder.
                        Text("No quote — go back and try again.")
                            .font(TaliseFont.body(13, weight: .light))
                            .foregroundStyle(TaliseColor.fgMuted)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { syncCountdown() }
        .onReceive(countdown) { _ in tick() }
    }

    // MARK: - Countdown

    private func syncCountdown() {
        secondsLeft = remainingSeconds()
    }

    /// Whole seconds until the held rate lapses, clamped at 0.
    private func remainingSeconds() -> Int {
        guard let expiresAt = draft.quote?.quote.expiresAt else { return 0 }
        let nowMs = Date().timeIntervalSince1970 * 1000.0
        let diffSec = (expiresAt - nowMs) / 1000.0
        return max(0, Int(ceil(diffSec)))
    }

    private func tick() {
        let remaining = remainingSeconds()
        if remaining <= 0 && !repricing {
            // Held rate lapsed — fetch a fresh quote so the user never
            // commits a stale rate.
            Task { await reprice() }
        } else {
            secondsLeft = remaining
        }
    }

    private func reprice() async {
        repricing = true
        await onReprice()
        repricing = false
        secondsLeft = remainingSeconds()
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(TaliseColor.surfaceGlass))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var titleBlock: some View {
        Text("Review transfer")
            .font(TaliseFont.heading(24, weight: .medium))
            .kerning(-0.5)
            .foregroundStyle(TaliseColor.fg)
            .frame(maxWidth: .infinity)
    }

    // MARK: - You send

    private func youSendCard(_ quote: CrossBorderQuoteDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "You send · \(draft.origin.flag) \(draft.origin.name)")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(draft.origin.currency.symbol)
                    .font(TaliseFont.heading(28, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                Text(rawSourceNumber)
                    .font(TaliseFont.heading(40, weight: .medium))
                    .kerning(-1)
                    .foregroundStyle(TaliseColor.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(usdsuiEquivalent(quote))
                .font(TaliseFont.mono(12, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taliseGlass(cornerRadius: 22)
    }

    private var sourceDecimals: Int {
        CrossBorderFormat.decimals(for: draft.origin.currencyCode)
    }

    /// The raw source amount formatted with locale-appropriate decimals,
    /// WITHOUT a currency symbol (the symbol is rendered separately).
    private var rawSourceNumber: String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        fmt.minimumFractionDigits = sourceDecimals
        fmt.maximumFractionDigits = sourceDecimals
        return fmt.string(from: NSNumber(value: draft.amountSource)) ?? "0"
    }

    private func usdsuiEquivalent(_ quote: CrossBorderQuoteDTO) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        let body = fmt.string(from: NSNumber(value: quote.amountUsd)) ?? "0.00"
        return "\(body) USDsui moves on chain"
    }

    private var arrow: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(TaliseColor.fgMuted)
            .frame(width: 28, height: 28)
            .background(Circle().fill(TaliseColor.surfaceGlass))
    }

    // MARK: - Recipient card

    private func recipientCard(_ quote: CrossBorderQuoteDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Recipient · \(destFlag) \(quote.recipientGets.currency)")
            Text(recipientPrimary)
                .font(TaliseFont.heading(20, weight: .medium))
                .foregroundStyle(TaliseColor.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(recipientShortAddress)
                .font(TaliseFont.mono(11, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taliseGlass(cornerRadius: 22)
    }

    private var destFlag: String {
        guard let code = draft.destination?.code else { return "" }
        return CrossBorderCatalogue.destination(for: code)?.flag ?? ""
    }

    private var recipientPrimary: String {
        if let r = draft.resolved,
           let name = r.displayName, !name.isEmpty, name != r.address {
            return name
        }
        return recipientShortAddress
    }

    private var recipientShortAddress: String {
        guard let r = draft.resolved else { return "—" }
        let a = r.address
        guard a.count > 14 else { return a }
        return String(a.prefix(8)) + "…" + String(a.suffix(6))
    }

    // MARK: - Locked quote block

    private func lockedQuoteBlock(_ quote: CrossBorderQuoteDTO) -> some View {
        VStack(spacing: 14) {
            // Locked rate + countdown.
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TaliseColor.accent)
                    Text(rateLine(quote))
                        .font(TaliseFont.mono(12, weight: .regular))
                        .foregroundStyle(TaliseColor.fg)
                }
                Spacer()
                if repricing {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini).tint(TaliseColor.fgMuted)
                        Text("Updating…")
                            .font(TaliseFont.mono(11, weight: .light))
                            .foregroundStyle(TaliseColor.fgMuted)
                    }
                } else {
                    Text("Rate held \(secondsLeft)s")
                        .font(TaliseFont.mono(11, weight: .light))
                        .foregroundStyle(secondsLeft <= 5 ? TaliseColor.danger : TaliseColor.fgMuted)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.18), value: secondsLeft)
                }
            }

            Divider().background(TaliseColor.line)

            quoteRow(label: "Fee (\(spreadPct(quote)))", value: feeText(quote))
            quoteRow(label: "Total debit", value: totalDebitText(quote))

            Divider().background(TaliseColor.line)

            // Headline guaranteed receive amount.
            HStack(alignment: .firstTextBaseline) {
                Text("Recipient gets")
                    .font(TaliseFont.body(13, weight: .regular))
                    .foregroundStyle(TaliseColor.fgMuted)
                Spacer()
                Text(recipientGetsText(quote))
                    .font(TaliseFont.heading(20, weight: .medium))
                    .foregroundStyle(TaliseColor.accent)
            }

            Text("Locked at the held rate. Talise settles this as digital dollars, 1:1, then pays out locally.")
                .font(TaliseFont.mono(10, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .taliseGlass(cornerRadius: 22)
    }

    private func quoteRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(TaliseFont.body(13, weight: .regular))
                .foregroundStyle(TaliseColor.fgMuted)
            Spacer()
            Text(value)
                .font(TaliseFont.mono(13, weight: .regular))
                .foregroundStyle(TaliseColor.fg)
        }
    }

    // MARK: - Quote formatting (server figures, rendered verbatim)

    /// "1 $ = ₦1,650" — the locked source→dest rate from the quote.
    private func rateLine(_ quote: CrossBorderQuoteDTO) -> String {
        let dest = quote.recipientGets.currency
        let rate = quote.quote.rate
        let recip = CrossBorderFormat.payout(rate, currencyCode: dest)
        return "1 \(draft.origin.currency.symbol) = \(recip)"
    }

    /// Spread basis points as a percentage label, e.g. "0.45%".
    private func spreadPct(_ quote: CrossBorderQuoteDTO) -> String {
        let pct = Double(quote.quote.spreadBps) / 100.0
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 0
        fmt.maximumFractionDigits = 2
        let body = fmt.string(from: NSNumber(value: pct)) ?? "\(pct)"
        return "\(body)%"
    }

    /// The fee in the source currency, derived from the spread bps applied
    /// to the source amount (display only — the toAmount already nets it).
    private func feeText(_ quote: CrossBorderQuoteDTO) -> String {
        let fee = draft.amountSource * (Double(quote.quote.spreadBps) / 10_000.0)
        return TaliseFormat.symbolic(fee, currency: draft.origin.currency, fixed: sourceDecimals)
    }

    /// Total debited from the sender — the full source amount they typed.
    private func totalDebitText(_ quote: CrossBorderQuoteDTO) -> String {
        TaliseFormat.symbolic(draft.amountSource, currency: draft.origin.currency, fixed: sourceDecimals)
    }

    /// The server's guaranteed receive amount, in the payout currency.
    private func recipientGetsText(_ quote: CrossBorderQuoteDTO) -> String {
        CrossBorderFormat.payout(quote.recipientGets.amount, currencyCode: quote.recipientGets.currency)
    }

    // MARK: - Per-tx cap notice

    private func capNotice(_ quote: CrossBorderQuoteDTO) -> String? {
        guard let cap = quote.corridor.perTxCapUsd, cap > 0 else { return nil }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.maximumFractionDigits = 0
        let capStr = fmt.string(from: NSNumber(value: cap)) ?? "\(Int(cap))"
        return "This corridor caps single transfers at $\(capStr). You're within it."
    }

    private func capNoticeRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(TaliseColor.warmGold)
            Text(text)
                .font(TaliseFont.mono(10, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TaliseColor.warmGold.opacity(0.10))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if let err = draft.error, err == .fx {
                Text("Couldn't refresh the rate. Pull back and try again.")
                    .font(TaliseFont.body(12, weight: .light))
                    .foregroundStyle(TaliseColor.danger)
                    .multilineTextAlignment(.center)
            }
            SlideToConfirm(
                title: payoutGate ? "Slide to send" : "Rate updating…",
                reset: $resetSlide
            ) {
                guard payoutGate else { return }
                await onConfirm()
            }
            .disabled(!payoutGate)
            .opacity(payoutGate ? 1 : 0.5)
        }
    }

    /// Slide is armed only when a fresh, non-lapsed quote is held and
    /// we're not mid-reprice.
    private var payoutGate: Bool {
        draft.quote != nil && !repricing && secondsLeft > 0
    }
}
