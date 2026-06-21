import SwiftUI

/// Step 2 of the cross-border flow: enter the amount in the SOURCE
/// currency, see a live estimate of what the recipient gets, then tap to
/// fetch the server-locked quote (`POST /api/transfers/cross-border/quote`).
///
/// The on-screen estimate uses the app's cached FX rates so the figure
/// doesn't jump when the user advances — the quote endpoint returns the
/// authoritative locked numbers, which the Review screen renders verbatim.
struct CrossBorderAmountView: View {
    @Bindable var draft: CrossBorderDraft
    /// Called once the server returns a fresh locked quote.
    var onQuoted: () -> Void
    var onBack: () -> Void

    @State private var balance: BalancesDTO?
    @State private var fetching = false
    @State private var inlineError: String?

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

            if let inlineError {
                Text(inlineError)
                    .font(TaliseFont.body(12, weight: .light))
                    .foregroundStyle(TaliseColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
            }

            getRateButton
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { Task { await loadBalance() } }
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
            VStack(spacing: 2) {
                MicroLabel(text: "Amount", color: TaliseColor.fgDim).kerning(1.5)
                if let dest = draft.destination {
                    Text("to \(dest.flag) \(dest.name)")
                        .font(TaliseFont.mono(10, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                }
            }
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Amount

    private var amountBlock: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(draft.origin.currency.symbol)
                    .font(TaliseFont.heading(72, weight: .thin))
                    .foregroundStyle(TaliseColor.fgMuted)
                Text(displayAmount)
                    .font(TaliseFont.heading(72, weight: .medium))
                    .kerning(-2)
                    .foregroundStyle(TaliseColor.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.18), value: displayAmount)
            }

            // Live recipient-gets estimate (cached FX). The locked figure
            // comes from the server when the user taps Get rate.
            if let line = recipientEstimateLine {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TaliseColor.accent)
                    Text(line)
                        .font(TaliseFont.mono(12, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .contentTransition(.numericText())
                }
                .animation(.snappy(duration: 0.18), value: line)
            } else {
                Text("\(usdsuiSecondary) USDsui")
                    .font(TaliseFont.mono(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgDim)
            }

            if exceedsBalance {
                MicroLabel(text: "OVER AVAILABLE BALANCE", color: TaliseColor.danger)
                    .kerning(1.5)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 24)
    }

    private var displayAmount: String {
        let raw = draft.rawAmount
        if raw.isEmpty { return "0" }
        if let dotIdx = raw.firstIndex(of: ".") {
            let intPart = String(raw[raw.startIndex..<dotIdx])
            let fracPart = String(raw[raw.index(after: dotIdx)...])
            return "\(groupDigits(intPart)).\(fracPart)"
        }
        return groupDigits(raw)
    }

    private func groupDigits(_ s: String) -> String {
        guard s.count > 3, s.allSatisfy({ $0.isNumber }) else { return s }
        var out = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return String(out.reversed())
    }

    /// "Recipient gets ≈ ¥15,000" — an estimate from cached FX. Nil until
    /// the user types a positive amount and a destination is chosen.
    private var recipientEstimateLine: String? {
        guard let dest = draft.destination, draft.amountSource > 0 else { return nil }
        let rates = CurrencySettings.shared.rates
        let sourceRate = rates[draft.origin.currencyCode] ?? 1
        let destRate = rates[dest.currencyCode] ?? 1
        guard sourceRate > 0 else { return nil }
        let usd = draft.amountSource / sourceRate
        let amount = usd * destRate
        let formatted = CrossBorderFormat.payout(amount, currencyCode: dest.currencyCode)
        return "Recipient gets ≈ \(formatted)"
    }

    /// USDsui equivalent of the typed source amount, formatted.
    private var usdsuiSecondary: String {
        let rates = CurrencySettings.shared.rates
        let sourceRate = rates[draft.origin.currencyCode] ?? 1
        let usd = sourceRate > 0 ? draft.amountSource / sourceRate : 0
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        return fmt.string(from: NSNumber(value: usd)) ?? "0.00"
    }

    private var amountUsdsui: Double {
        let rates = CurrencySettings.shared.rates
        let sourceRate = rates[draft.origin.currencyCode] ?? 1
        guard sourceRate > 0 else { return 0 }
        return draft.amountSource / sourceRate
    }

    private var exceedsBalance: Bool {
        guard let have = balance?.usdsui else { return false }
        let amt = amountUsdsui
        return amt > 0 && amt > have
    }

    // MARK: - Wallet pill

    private var walletPill: some View {
        HStack(spacing: 8) {
            Circle().fill(TaliseColor.accent).frame(width: 6, height: 6)
            Text("MAIN WALLET")
                .font(TaliseFont.mono(10, weight: .light))
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
        .background(Capsule().fill(TaliseColor.surfaceGlass))
        .overlay(Capsule().stroke(TaliseColor.line, lineWidth: 0.5))
    }

    private var availableLocal: String? {
        guard let usdsui = balance?.usdsui else { return nil }
        return TaliseFormat.local2(usdsui)
    }

    // MARK: - Get rate

    private var getRateButton: some View {
        Button(action: { Task { await fetchQuote() } }) {
            HStack(spacing: 10) {
                if fetching {
                    ProgressView().progressViewStyle(.circular).tint(TaliseColor.bg)
                }
                Text(fetching ? "Locking rate…" : "Get rate")
                    .font(TaliseFont.heading(16, weight: .medium))
            }
            .foregroundStyle(TaliseColor.bg)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(canAdvance ? TaliseColor.fg : TaliseColor.fg.opacity(0.35))
            .clipShape(Capsule())
        }
        .disabled(!canAdvance || fetching)
    }

    private var canAdvance: Bool {
        draft.destination != nil && draft.amountSource > 0 && !exceedsBalance
    }

    /// Hit the server for an authoritative locked quote, then advance.
    private func fetchQuote() async {
        guard let dest = draft.destination, draft.amountSource > 0 else { return }
        fetching = true
        inlineError = nil
        defer { fetching = false }
        do {
            let q = try await CrossBorderAPI.quote(
                fromCountry: draft.origin.code,
                toCountry: dest.code,
                amount: draft.amountSource
            )
            draft.quote = q
            draft.error = nil
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            onQuoted()
        } catch {
            let cb = CrossBorderError.from(error)
            if cb == .cancelled { return }
            // Surface the typed gate inline so the user can react without
            // leaving the amount screen (e.g. lower the amount for OVER_CAP).
            inlineError = cb.errorDescription
        }
    }

    private func loadBalance() async {
        do {
            balance = try await APIClient.shared.get("/api/balances")
        } catch {
            balance = nil
        }
    }
}
