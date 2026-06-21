import SwiftUI

/// Step 3: read-only confirm. Shows the from/to glass cards, the "no
/// network fee" footnote, and a Confirm button that kicks off the
/// sponsor-execute and advances to `SendInProgressView`.
struct SendReviewView: View {
    @Bindable var draft: SendDraft
    var onConfirm: () async -> Void
    var onBack: () -> Void

    @Environment(AppSession.self) private var session

    /// Locked cross-border quote. Nil for same-currency sends — those
    /// keep the original generic fee line and behave exactly as before.
    @State private var quote: CrossBorderQuote?
    /// Seconds left on the 30s hold, mirrored out of `quote` so the
    /// countdown re-renders each tick.
    @State private var secondsLeft: Int = 0

    /// 1Hz tick that drives the "rate held 30s" countdown.
    private let countdown = Timer.publish(every: 1, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 18) {
                    titleBlock
                        .padding(.top, 10)

                    fromCard
                    arrow
                    toCard

                    // Cross-border: transparent locked-quote block.
                    // Same-currency: the original "no network fee" line.
                    if let quote {
                        lockedQuoteBlock(quote)
                            .padding(.top, 4)
                    } else {
                        feeLine
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            VStack(spacing: 8) {
                SlideToConfirm(title: "Slide to send", tint: TaliseColor.greenMint) {
                    await onConfirm()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .taliseScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { lockQuote() }
        .onReceive(countdown) { _ in tick() }
    }

    // MARK: - Quote lifecycle

    /// Lock a fresh quote when the screen appears (cross-border only).
    private func lockQuote() {
        guard draft.isCrossCurrency else {
            quote = nil
            return
        }
        let q = draft.makeCrossBorderQuote()
        quote = q
        secondsLeft = q?.secondsRemaining() ?? 0
    }

    /// Tick the countdown; re-lock the quote at expiry so the held rate
    /// is always honoured (never let a stale rate sit committable).
    private func tick() {
        guard let q = quote else { return }
        let remaining = q.secondsRemaining()
        if remaining <= 0 {
            // Re-lock at the current rate snapshot and restart the hold.
            lockQuote()
        } else {
            secondsLeft = remaining
        }
    }

    // MARK: - Header

    private var header: some View {
        // Dropped the centered "REVIEW" eyebrow — the big "Review send"
        // title block carries the screen identity; this row only needs
        // the back chevron.
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TaliseColor.fg)
                    .frame(width: 38, height: 38)
                    .glassCircle()
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Title

    private var titleBlock: some View {
        // Dropped the subtitle ("Confirm the details. Settles on Sui in
        // a few seconds.") — the screen IS a review and the from/to
        // cards make the action self-evident.
        Text("Review send")
            .font(TaliseFont.heading(24, weight: .medium))
            .kerning(-0.5)
            .foregroundStyle(TaliseColor.fg)
            .frame(maxWidth: .infinity)
    }

    // MARK: - From card

    private var fromCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "From \(myHandle)")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(draft.currency.symbol)
                    .font(TaliseFont.heading(28, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                Text(displayAmount)
                    .font(TaliseFont.heading(40, weight: .medium))
                    .kerning(-1)
                    .foregroundStyle(TaliseColor.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(usdsuiEquivalent)
                .font(TaliseFont.mono(12, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(TaliseColor.surface)
        )
    }

    private var displayAmount: String {
        draft.rawAmount.isEmpty ? "0" : draft.rawAmount
    }

    private var usdsuiEquivalent: String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        let body = fmt.string(from: NSNumber(value: draft.amountUsdsui)) ?? "0.00"
        return "\(body) USDsui"
    }

    private var myHandle: String {
        switch session.phase {
        case .ready(let user), .onboarding(let user):
            return user.displayHandle() ?? "you"
        default:
            return "you"
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TaliseColor.greenMint)
            .frame(width: 32, height: 32)
            .glassCircle()
    }

    // MARK: - To card

    private var toCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "To")
            Text(recipientPrimary)
                .font(TaliseFont.heading(20, weight: .medium))
                .foregroundStyle(TaliseColor.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(recipientShortAddress)
                .font(TaliseFont.mono(11, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
            if let sends = draft.previousSendsToRecipient, sends > 0 {
                Text(sends == 1 ? "1 previous send" : "\(sends) previous sends")
                    .font(TaliseFont.mono(11, weight: .light))
                    .foregroundStyle(TaliseColor.greenMint)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(TaliseColor.surface)
        )
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

    // MARK: - Locked-quote block (cross-border)

    /// Transparent quote card shown instead of the generic fee line when
    /// the recipient is paid in a different currency. Surfaces the locked
    /// rate, the spread AS AN EXPLICIT FEE, the total debit, the
    /// guaranteed receive amount, and a "rate held Ns" countdown.
    private func lockedQuoteBlock(_ q: CrossBorderQuote) -> some View {
        VStack(spacing: 14) {
            // Locked rate + countdown header.
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TaliseColor.greenMint)
                    Text(q.rateLine)
                        .font(TaliseFont.mono(12, weight: .regular))
                        .foregroundStyle(TaliseColor.fg)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassCapsule()
                Spacer()
                Text("Rate held \(secondsLeft)s")
                    .font(TaliseFont.mono(11, weight: .light))
                    .foregroundStyle(secondsLeft <= 5 ? TaliseColor.danger : TaliseColor.fgMuted)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: secondsLeft)
            }

            LiquidGlassDivider()

            quoteRow(
                label: "Fee (\(spreadBpsLabel(q)))",
                value: TaliseFormat.symbolic(q.spreadLocal, currency: q.senderCurrency, fixed: 2)
            )
            quoteRow(
                label: "Total debit",
                value: TaliseFormat.symbolic(q.senderDebitLocal, currency: q.senderCurrency, fixed: 2)
            )

            LiquidGlassDivider()

            // The guaranteed receive amount — the headline of the block.
            HStack(alignment: .firstTextBaseline) {
                Text("Recipient gets")
                    .font(TaliseFont.body(13, weight: .regular))
                    .foregroundStyle(TaliseColor.fgMuted)
                Spacer()
                Text(TaliseCurrency.recipientSymbolic(q.recipientReceiveLocal, currency: q.recipientCurrency))
                    .font(TaliseFont.heading(20, weight: .medium))
                    .foregroundStyle(TaliseColor.greenMint)
            }

            Text("Locked at the held rate. Talise moves this as digital dollars, 1:1.")
                .font(TaliseFont.mono(10, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(TaliseColor.surface)
        )
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

    /// "0.25%" style label for the spread basis points.
    private func spreadBpsLabel(_ q: CrossBorderQuote) -> String {
        let pct = Double(q.spreadBps) / 100
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 0
        fmt.maximumFractionDigits = 2
        let body = fmt.string(from: NSNumber(value: pct)) ?? "\(pct)"
        return "\(body)%"
    }

    // MARK: - Fee line

    private var feeLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(TaliseColor.greenMint)
            Text("Network fee $0.00 — Talise auto-routed the rail and sponsored the gas.")
                .font(TaliseFont.mono(11, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

}
