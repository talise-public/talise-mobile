import SwiftUI

// MARK: - Off-ramp Phase 3 DTOs (send-to-a-user's-bank)

/// `POST /api/offramp/linq/to-user` response. The server resolves the
/// recipient's PRIMARY bank from their @handle and returns the EXACT
/// `amountUsdsui` we must send to `walletAddress` to credit `amountNgn`.
/// `recipientBankLabel` is the masked destination ("GTBank ••••1234") —
/// the sender never sees the full account number.
private struct LinqToUserResp: Decodable {
    let orderId: String
    let walletAddress: String
    let coinType: String
    let amountUsdsui: Double      // EXACT amount to send
    let amountNgn: Double
    let rate: Double
    let recipientName: String
    let recipientBankLabel: String
}

/// `GET /api/offramp/linq/status/[orderId]` — current state of the order.
/// Same shape the Withdraw flow polls.
private struct LinqToUserStatusResp: Decodable {
    let orderId: String
    let status: String
    let phase: String             // initiated | processing | completed | failed
    let amountUsdsui: Double
    let amountNgn: Double
}

// MARK: - Send to recipient's bank (NGN payout)

/// Off-ramp Phase 3 — when a resolved Send recipient has a PRIMARY linked
/// Nigerian bank, the sender can pay them in Naira instead of on-chain.
///
/// Flow: enter an NGN amount → `POST /api/offramp/linq/to-user` (server
/// locks the order + returns the EXACT USDsui to send + the masked bank
/// label) → sign+send that EXACT amount to the Linq deposit wallet via the
/// same sponsored send path the Withdraw flow uses → poll
/// `/api/offramp/linq/status/{orderId}` until it lands. Shows
/// "Paid {recipientBankLabel}".
struct SendToBankView: View {
    /// The already-resolved Send recipient (we forward `recipient` — the
    /// @handle or address the Send flow resolved — to the backend, which
    /// re-resolves their primary bank server-side).
    let recipient: String
    /// Display name for the recipient ("alice") shown in the header.
    let recipientDisplay: String
    /// Masked primary-bank label from recipient resolution, e.g.
    /// "GTBank ••••1234". Shown before the user even types an amount.
    let bankLabel: String

    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Session-expiry path: an unrecoverable zkLogin session routes to a
    /// clean sign-out → re-auth (mirrors Send) instead of a dead-end error.
    @Environment(AppSession.self) private var session

    @State private var amount: String = ""
    @State private var step: Step = .form
    @State private var sending = false
    @State private var error: String?

    @State private var statusText: String = ""
    @State private var paidLabel: String = ""
    @State private var finalStatus: String?     // completed | failed
    @State private var paidOut = false

    /// Live display rate (1 USDsui = `rate` NGN) for the "≈ $X" estimate.
    @State private var displayRate: Double?

    private enum Step { case form, sending, done }

    private var amountValue: Double { Double(amount) ?? 0 }
    private var canContinue: Bool { amountValue > 0 && !sending }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .form: formView
                case .sending, .done: statusView
                }
            }
            .background(TaliseColor.bg.ignoresSafeArea())
            .navigationTitle("Pay to bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TaliseColor.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if step == .form {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") { close() }
                            .foregroundStyle(TaliseColor.fgMuted)
                    }
                }
            }
            .task { await loadRate() }
        }
        .tint(TaliseColor.fg)
    }

    // MARK: - Form

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Destination summary — name + masked bank. The sender
                // never sees the full account number, only this label.
                destinationCard

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Amount in Naira")
                    amountField
                    estimateLine
                }

                if let error {
                    Text(error)
                        .font(TaliseFont.body(12, weight: .light))
                        .foregroundStyle(TaliseColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }

                Spacer(minLength: 8)

                continueButton.padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    private var destinationCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(TaliseColor.accent)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(TaliseColor.accentSoft)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(recipientDisplay)
                    .font(TaliseFont.body(15, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                    .lineLimit(1)
                Text(bankLabel)
                    .font(TaliseFont.mono(11, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(TaliseColor.surface)
        )
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .font(TaliseFont.mono(10, weight: .light))
            .kerning(1.3)
            .foregroundStyle(TaliseColor.fgDim)
    }

    private var amountField: some View {
        HStack(spacing: 8) {
            Text("₦")
                .font(TaliseFont.heading(20, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            TextField("", text: $amount, prompt: Text("0").foregroundColor(TaliseColor.fgDim))
                .keyboardType(.decimalPad)
                .font(TaliseFont.heading(20, weight: .medium))
                .foregroundStyle(TaliseColor.fg)
                .onChange(of: amount) { _, _ in if error != nil { error = nil } }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .fieldSurfaceToBank()
    }

    /// Display-only estimate of the USDsui that will leave the wallet. The
    /// EXACT debit comes from the `/to-user` response, never this figure.
    @ViewBuilder private var estimateLine: some View {
        if let rate = displayRate, rate > 0, amountValue > 0 {
            Text("≈ \(TaliseFormat.usd2(amountValue / rate)) USDsui leaves your wallet")
                .font(TaliseFont.mono(12, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .padding(.leading, 2)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: amountValue)
        }
    }

    private var continueButton: some View {
        Button(action: { Task { await payToBank() } }) {
            HStack(spacing: 8) {
                if sending { ProgressView().tint(TaliseColor.bg) }
                Text(sending ? "Sending…" : "Pay \(recipientDisplay)")
                    .font(TaliseFont.heading(16, weight: .medium))
                    .foregroundStyle(TaliseColor.bg)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(canContinue ? TaliseColor.fg : TaliseColor.fg.opacity(0.35))
            .clipShape(Capsule())
        }
        .disabled(!canContinue)
    }

    // MARK: - Status

    private var statusView: some View {
        VStack(spacing: 18) {
            Spacer()
            statusIcon
            Text(statusHeadline)
                .font(TaliseFont.heading(24, weight: .medium))
                .kerning(-0.5)
                .foregroundStyle(TaliseColor.fg)
            Text(statusText)
                .font(TaliseFont.body(14, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
            if step == .done {
                VStack(spacing: 12) {
                    if finalStatus == "failed" {
                        Button(action: { step = .form; error = nil }) {
                            Text("Try again")
                                .font(TaliseFont.heading(16, weight: .medium))
                                .foregroundStyle(TaliseColor.bg)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(TaliseColor.fg).clipShape(Capsule())
                        }
                        Button("Close") { close() }
                            .font(TaliseFont.body(14))
                            .foregroundStyle(TaliseColor.fgMuted)
                    } else {
                        Button(action: { close() }) {
                            Text("Done")
                                .font(TaliseFont.heading(16, weight: .medium))
                                .foregroundStyle(TaliseColor.bg)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(TaliseColor.fg).clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if step == .sending {
            TaliseLoadingRing(size: 64, lineWidth: 3.5)
                .frame(width: 96, height: 96)
        } else if finalStatus == "completed" {
            Image(systemName: paidOut ? "checkmark.seal.fill" : "clock.fill")
                .font(.system(size: paidOut ? 56 : 50)).foregroundStyle(TaliseColor.greenMint)
                .frame(width: 96, height: 96)
                .background(Circle().fill(TaliseColor.greenMint.opacity(0.16)))
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52)).foregroundStyle(TaliseColor.danger)
                .frame(width: 96, height: 96)
                .background(Circle().fill(TaliseColor.danger.opacity(0.16)))
        }
    }

    private var statusHeadline: String {
        if step == .sending { return "Paying their bank…" }
        if finalStatus == "failed" { return "Payment failed" }
        return paidOut ? "Paid \(paidLabel)" : "On its way"
    }

    // MARK: - Networking

    /// Public display rate for the "≈ $X" estimate. Silent on failure.
    private func loadRate() async {
        guard displayRate == nil else { return }
        struct RateResp: Decodable { let rate: Double }
        do {
            let r: RateResp = try await APIClient.shared.get("/api/offramp/linq/rate")
            displayRate = r.rate
        } catch { /* display-only — ignore */ }
    }

    /// Create the order, then sign+send the EXACT returned USDsui and poll.
    private func payToBank() async {
        guard canContinue else { return }
        sending = true; error = nil
        defer { sending = false }

        struct Body: Encodable { let recipient: String; let amountNgn: Double }
        do {
            // 1. Lock the order. The server resolves the recipient's primary
            //    bank from their @handle and returns the EXACT USDsui to send.
            let order: LinqToUserResp = try await APIClient.shared.post(
                "/api/offramp/linq/to-user",
                body: Body(recipient: recipient, amountNgn: amountValue)
            )
            paidLabel = order.recipientBankLabel

            // 2. Send EXACTLY `amountUsdsui` to the Linq deposit wallet.
            //    sponsorFallback: try gasless first (free when the user's
            //    funds are in the accumulator); the server sponsors only when
            //    gasless can't build (funds in Coin objects) so the bank
            //    payout still lands.
            let sent = try await ZkLoginCoordinator.shared.signAndSubmitSend(
                to: order.walletAddress,
                amountUsd: order.amountUsdsui,
                asset: "USDsui",
                intent: "Pay \(recipientDisplay) to bank",
                sponsorFallback: true
            )
            guard !sent.digest.isEmpty else {
                error = "Payment didn't land on chain. No funds moved."
                return
            }

            NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                digest: sent.digest, direction: "sent", amountUsdsui: order.amountUsdsui,
                counterparty: order.walletAddress,
                counterpartyName: "Paid \(order.recipientBankLabel)", venue: nil))

            statusText = "Sending ₦\(ngnGrouped(order.amountNgn)) to \(order.recipientBankLabel)…"
            withAnimation { step = .sending }
            await pollStatus(order.orderId, label: order.recipientBankLabel)
        } catch APIError.status(let code, let msg) {
            error = friendlyError(code: code, message: msg)
        } catch APIError.unauthorized {
            error = "Please sign in again."
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            error = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = APIError.honestMoneyError(
                error, fallback: "Couldn't complete the payment right now.")
        }
    }

    /// Poll the Linq order until it lands or fails (or we time out and leave
    /// it in flight — the payout still completes server-side).
    private func pollStatus(_ id: String, label: String) async {
        for _ in 0..<20 {
            do {
                let s: LinqToUserStatusResp = try await APIClient.shared.get("/api/offramp/linq/status/\(id)")
                switch s.phase {
                case "completed":
                    finalStatus = "completed"
                    paidOut = true
                    statusText = "₦\(ngnGrouped(s.amountNgn)) has landed in \(label)."
                    withAnimation { step = .done }
                    return
                case "failed":
                    finalStatus = "failed"
                    statusText = "The payment couldn't be completed — your USDsui has been returned."
                    withAnimation { step = .done }
                    return
                default:
                    break   // initiated / processing — keep polling
                }
            } catch {
                if APIError.isCancellation(error) { return }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        finalStatus = "completed"
        paidOut = false
        statusText = "Your payment is on its way. It can take a few minutes to land in \(label)."
        withAnimation { step = .done }
    }

    private func close() {
        onDone()
        dismiss()
    }

    /// Grouped NGN figure (no symbol — we prefix ₦ at the call site).
    private func ngnGrouped(_ v: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        fmt.minimumFractionDigits = 0
        fmt.maximumFractionDigits = v < 100 ? 2 : 0
        return fmt.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v)
    }

    /// Map rollout / config errors to reassuring copy; pass short real ones through.
    private func friendlyError(code: Int, message: String?) -> String {
        let lower = (message ?? "").lowercased()
        if code == 503 || lower.contains("not configured") || lower.contains("fx_unavailable") {
            return "Bank payouts are rolling out — check back soon."
        }
        if code == 404 || lower.contains("no primary") || lower.contains("no_bank") {
            return "They don't have a bank account set up anymore. Try sending on-chain."
        }
        if lower.contains("\"error\""),
           let data = message?.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = obj["error"] as? String, !e.isEmpty {
            return e
        }
        if let msg = message, !msg.isEmpty, msg.count <= 120,
           !lower.contains("<html"), !lower.contains("<!doctype") {
            return msg
        }
        return "Something went wrong. Please try again."
    }
}

// MARK: - Flat field treatment

/// Flat input-field surface — matches the Withdraw/BankAccounts treatment.
private struct ToBankFieldSurface: ViewModifier {
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(TaliseColor.surface))
            .overlay(shape.strokeBorder(TaliseColor.line, lineWidth: 1))
            .clipShape(shape)
    }
}

private extension View {
    func fieldSurfaceToBank(cornerRadius: CGFloat = 16) -> some View {
        modifier(ToBankFieldSurface(cornerRadius: cornerRadius))
    }
}
