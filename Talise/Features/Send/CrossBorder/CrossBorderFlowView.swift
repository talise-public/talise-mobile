import SwiftUI

/// State the cross-border flow accumulates before + after the backend
/// round-trip. Distinct from `SendDraft` (the same-currency rail) — this
/// rail is server-authoritative end-to-end, so the draft holds the
/// server's locked quote verbatim rather than computing FX on device.
@MainActor
@Observable
final class CrossBorderDraft {
    /// Sender side — where fiat is collected. Resolved from the user's
    /// profile country (falls back to the US/USD live beachhead).
    var origin: CrossBorderOrigin

    /// Destination the user picked. Nil until they choose one.
    var destination: CrossBorderCountry?

    /// Recipient text + the resolved on-chain address (recipient handle /
    /// 0x). Reuses the same `RecipientResolution` shape the send rail uses.
    var recipientInput: String = ""
    var resolved: RecipientResolution?

    /// User-entered amount string, in the SOURCE currency (origin.currency).
    var rawAmount: String = ""

    /// The server-locked quote — the source of truth for the review +
    /// confirm screens. Set by the Amount step when the user advances.
    var quote: CrossBorderQuoteDTO?

    /// Terminal outcome after confirm.
    var confirmResult: CrossBorderConfirmDTO?

    /// Surfaced error (typed code from the contract, or transport).
    var error: CrossBorderError?

    init(origin: CrossBorderOrigin) {
        self.origin = origin
    }

    /// Parsed numeric amount in the source currency, or 0.
    var amountSource: Double {
        Double(rawAmount.trimmingCharacters(in: .whitespaces)) ?? 0
    }
}

/// Cursor for the cross-border flow. A separate enum from `SendStep` so
/// the two rails never share a NavigationStack path type.
enum CrossBorderStep: Hashable {
    case recipient
    case amount
    case review
    case sending
    case complete
    case failure
}

/// Root container for the cross-border send flow.
///
/// Spine mirrors `SendFlowView` (NavigationStack driven by an enum path,
/// a shared `@Observable` draft, SlideToConfirm as the commit gesture),
/// but every money figure comes from the server: the Amount step calls
/// `POST /api/transfers/cross-border/quote`, Review renders the locked
/// quote with a 30s "rate held" countdown, and SlideToConfirm posts
/// `POST /api/transfers/cross-border/confirm` to drive the transfers
/// state machine.
struct CrossBorderFlowView: View {
    var onDone: (() -> Void)?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var path: [CrossBorderStep] = []
    @State private var draft: CrossBorderDraft

    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
        // Seed the source country from the user's profile country if known.
        let origin = CrossBorderCatalogue.resolveOrigin(profileCountry: nil)
        _draft = State(initialValue: CrossBorderDraft(origin: origin))
    }

    var body: some View {
        NavigationStack(path: $path) {
            CrossBorderRecipientView(
                draft: draft,
                onNext: { path.append(.amount) },
                onCancel: { close() }
            )
            .navigationDestination(for: CrossBorderStep.self) { step in
                switch step {
                case .recipient:
                    Color.clear.onAppear { path.removeAll() }
                case .amount:
                    CrossBorderAmountView(
                        draft: draft,
                        onQuoted: { path.append(.review) },
                        onBack: { pop() }
                    )
                case .review:
                    CrossBorderReviewView(
                        draft: draft,
                        onConfirm: { await confirm() },
                        onReprice: { await reprice() },
                        onBack: { pop() }
                    )
                case .sending:
                    CrossBorderSendingView(draft: draft, onDone: { close() })
                        .navigationBarBackButtonHidden(true)
                case .complete:
                    CrossBorderCompleteView(draft: draft, onDone: { close() })
                        .navigationBarBackButtonHidden(true)
                case .failure:
                    CrossBorderFailureView(
                        draft: draft,
                        onRetry: {
                            draft.error = nil
                            // Drop back to the amount step so the user can
                            // re-quote (rate may have moved) or correct input.
                            path = [.amount]
                        },
                        onDone: { close() }
                    )
                    .navigationBarBackButtonHidden(true)
                }
            }
        }
        .tint(TaliseColor.fg)
        .onAppear { seedOrigin() }
    }

    // MARK: - Origin

    /// Re-resolve the source country once the session is in view (init
    /// runs before `session` is injected into the environment).
    private func seedOrigin() {
        let country = sessionCountry()
        draft.origin = CrossBorderCatalogue.resolveOrigin(profileCountry: country)
    }

    private func sessionCountry() -> String? {
        switch session.phase {
        case .ready(let user), .onboarding(let user):
            return user.country
        default:
            return nil
        }
    }

    // MARK: - Navigation

    private func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    private func close() {
        onDone?()
        dismiss()
    }

    // MARK: - Confirm

    /// Commit the held quote: push the in-flight page, POST confirm, then
    /// route to success or failure based on the returned state.
    private func confirm() async {
        guard let quote = draft.quote else { return }
        draft.error = nil
        path.append(.sending)
        do {
            let result = try await CrossBorderAPI.confirm(transferId: quote.transferId)
            draft.confirmResult = result

            // Success = the transfer was COMMITTED (funds debited, on-chain
            // leg in flight or done). The live NG corridor returns
            // `onchain_settling` here — finality + the local payout land via
            // the server's broadcast-confirm hook — so gating on `isChainFinal`
            // wrongly flagged a good NG confirm as failed. A 4xx lands in the
            // `catch` below; only a non-committed 200 (e.g. failed/refunded)
            // falls through to the failure screen.
            guard result.isCommitted else {
                draft.error = .other("The transfer didn't complete. No funds moved.")
                path = [.amount, .review, .failure]
                return
            }

            // Optimistic Home update — same notification the same-currency
            // rail posts so the balance + activity reconcile. We don't have
            // an on-chain digest from confirm (the server owns the chain
            // leg), so key the optimistic entry on the transferId.
            NotificationCenter.default.post(
                name: .taliseTxCompleted,
                object: TaliseTxEvent(
                    digest: "xb:\(result.transferId)",
                    direction: "sent",
                    amountUsdsui: quote.amountUsd,
                    counterparty: draft.resolved?.address ?? "",
                    counterpartyName: draft.resolved?.displayName,
                    venue: nil
                )
            )

            path = [.amount, .review, .complete]
        } catch {
            draft.error = CrossBorderError.from(error)
            // A cancellation isn't a real failure — back off to review
            // so the user can re-slide once the network settles.
            if draft.error == .cancelled {
                path = [.amount, .review]
            } else {
                path = [.amount, .review, .failure]
            }
        }
    }

    /// Re-fetch a fresh quote when the held rate lapses on the review
    /// screen. Keeps the same recipient + amount; only the rate refreshes.
    private func reprice() async {
        guard let destination = draft.destination, draft.amountSource > 0 else { return }
        do {
            let q = try await CrossBorderAPI.quote(
                fromCountry: draft.origin.code,
                toCountry: destination.code,
                amount: draft.amountSource
            )
            draft.quote = q
            draft.error = nil
        } catch {
            // Leave the stale quote in place but surface the error; the
            // review screen disables the slide until a fresh quote lands.
            draft.error = CrossBorderError.from(error)
        }
    }
}
