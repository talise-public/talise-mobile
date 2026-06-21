import SwiftUI

/// In-flight hold while `POST /api/transfers/cross-border/confirm` runs.
/// Reuses the same paper-plane + shimmer treatment as the same-currency
/// send so the two rails feel like one product.
struct CrossBorderSendingView: View {
    @Bindable var draft: CrossBorderDraft
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                AnimatedPaperPlane(size: 140)
                    .padding(.bottom, 8)
                VStack(spacing: 8) {
                    Text("Sending…")
                        .font(TaliseFont.heading(28, weight: .medium))
                        .kerning(-0.5)
                        .foregroundStyle(TaliseColor.fg)
                    Text("Locking the chain leg, then handing off to the local payout. You can close this — we'll keep going.")
                        .font(TaliseFont.body(14, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                ShimmerBars()
            }
            Spacer()
            doneButton
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var doneButton: some View {
        Button(action: onDone) {
            Text("Done")
                .font(TaliseFont.heading(16, weight: .medium))
                .foregroundStyle(TaliseColor.fg)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Capsule().fill(TaliseColor.surfaceGlass))
                .overlay(Capsule().stroke(TaliseColor.line, lineWidth: 0.5))
        }
    }
}

/// Success state. The headline distinguishes the two honest outcomes:
///   • live NG/Paga corridor settles synchronously → "Sent" with the
///     recipient's payout amount.
///   • partner corridors advance to `fiat_out_pending` → "Sent — landing
///     in their bank", marking the chain leg final WITHOUT overclaiming
///     local delivery.
struct CrossBorderCompleteView: View {
    @Bindable var draft: CrossBorderDraft
    var onDone: () -> Void

    var body: some View {
        SuccessfulTxView(
            amountText: amountText,
            title: title,
            subtitle: subtitle,
            onShareReceipt: nil,
            onDone: onDone
        )
        .toolbar(.hidden, for: .navigationBar)
    }

    /// The recipient's payout amount, formatted in their currency — the
    /// headline figure for a cross-border send.
    private var amountText: String {
        guard let gets = draft.quote?.recipientGets else { return "—" }
        return CrossBorderFormat.payout(gets.amount, currencyCode: gets.currency)
    }

    private var title: String {
        guard let name = draft.resolved?.displayName, !name.isEmpty else {
            return "Sent"
        }
        return "Sent to \(name)"
    }

    /// Subtitle reflects the actual settled state from confirm. We never
    /// claim "delivered" — only the chain leg is final here; the local
    /// payout resolves asynchronously (Home reconciles on the webhook).
    private var subtitle: String {
        let settled = draft.confirmResult?.isPayoutSettled ?? false
        if settled {
            return "Delivered to their account"
        }
        return "On chain now — landing in their bank shortly"
    }
}

/// Failure state. Branches on whether the error is a hard gate (tier
/// block → "Verify identity") or transient (FX hiccup → "Try again").
struct CrossBorderFailureView: View {
    @Bindable var draft: CrossBorderDraft
    var onRetry: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(TaliseColor.danger.opacity(0.15))
                        .frame(width: 84, height: 84)
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(TaliseColor.danger)
                }
                Text(headline)
                    .font(TaliseFont.heading(26, weight: .medium))
                    .kerning(-0.5)
                    .foregroundStyle(TaliseColor.fg)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(TaliseFont.body(14, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            Spacer()
            VStack(spacing: 10) {
                if showsRetry {
                    Button(action: onRetry) {
                        Text("Try again")
                            .font(TaliseFont.heading(16, weight: .medium))
                            .foregroundStyle(TaliseColor.bg)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(TaliseColor.fg)
                            .clipShape(Capsule())
                    }
                }
                Button(action: onDone) {
                    Text(showsRetry ? "Cancel" : "Close")
                        .font(TaliseFont.heading(16, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Capsule().fill(TaliseColor.surfaceGlass))
                        .overlay(Capsule().stroke(TaliseColor.line, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var headline: String {
        switch draft.error {
        case .tierBlocked:   return "Verify your identity"
        case .limitExceeded: return "Over your limit"
        case .overCap:       return "Over the transfer cap"
        case .notBookable, .unknownCorridor: return "Route not open"
        default:             return "Transfer didn't go through"
        }
    }

    private var message: String {
        draft.error?.errorDescription ?? "Something went wrong. No funds moved."
    }

    /// Retry only when re-running the same inputs could plausibly help —
    /// a tier block / limit / cap won't resolve by retrying as-is.
    private var showsRetry: Bool {
        switch draft.error {
        case .tierBlocked, .limitExceeded, .notBookable, .unknownCorridor:
            return false
        default:
            return true
        }
    }
}
