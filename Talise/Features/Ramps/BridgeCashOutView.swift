import SwiftUI

/// Bridge CASH-OUT screen for a chosen corridor.
///
/// The wallet holds USDsui; Bridge pays out from USDC, so cashing out is a
/// single Onara-sponsored PTB (swap USDsui→USDC, 1% fee to treasury, send the
/// rest to the user's Bridge address) built server-side. The Bridge address is
/// abstracted away entirely — the user just enters an amount and taps Withdraw.
///
/// First-time users (no payout route yet) see a one-time bank-details form;
/// once a route exists, the screen is purely "enter amount → Withdraw".
struct BridgeCashOutView: View {
    let corridor: RampCorridor

    // ── Withdraw (route already exists) ──
    @State private var checking = true        // initial reuse-first lookup
    @State private var hasRoute = false        // a payout route exists for this corridor
    @State private var payoutBank: CashOutResponse?  // destination bank + USDC pocket
    @State private var balanceUsdsui: Double?
    @State private var usdcPocket: Double = 0  // USDC pocket balance
    // Step 1 — swap USDsui → USDC into the pocket
    @State private var swapText = ""
    @State private var swapping = false
    @State private var swapError: String?
    // Step 2 — send USDC out to the bank
    @State private var amountText = ""
    @State private var sending = false
    @State private var withdrawDone = false
    @State private var withdrawError: String?

    // ── One-time bank setup form (no route yet) ──
    @State private var ownerName = ""
    @State private var accountNumber = ""
    @State private var routingNumber = ""
    @State private var savings = false
    @State private var street = ""
    @State private var city = ""
    @State private var state = ""
    @State private var zip = ""
    // EUR / SEPA
    @State private var iban = ""
    @State private var bic = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var submitting = false
    @State private var setupError: String?

    private var isEur: Bool { corridor.currencyCode == "EUR" }
    private var isUsd: Bool { corridor.currencyCode == "USD" }
    private var supported: Bool { isUsd || isEur }

    // Bridge won't pay out below $1.00 USDC.
    private let minSend: Double = 1.0

    private var swapAmount: Double { Double(swapText) ?? 0 }
    private var canSwap: Bool {
        swapAmount > 0 && swapAmount <= (balanceUsdsui ?? 0) && !swapping
    }
    private var sendAmount: Double { Double(amountText) ?? 0 }
    private var canSend: Bool {
        sendAmount >= minSend && sendAmount <= usdcPocket && !sending
    }

    private var canSubmitSetup: Bool {
        guard !ownerName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isUsd {
            return accountNumber.count >= 4 && routingNumber.count >= 6
                && !street.isEmpty && !city.isEmpty && state.count >= 2 && zip.count >= 3
        }
        if isEur {
            return iban.count >= 10 && bic.count >= 6 && !firstName.isEmpty && !lastName.isEmpty
        }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if checking {
                    lookupCard
                } else if !supported {
                    unsupportedCard
                } else if withdrawDone {
                    successCard
                } else if hasRoute {
                    pocketCard
                    sendCard
                } else {
                    setupForm
                    if let setupError {
                        Text(setupError)
                            .font(TaliseFont.body(13, weight: .light))
                            .foregroundStyle(Color(hex: 0xFF6B6B))
                    }
                    submitButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .task { await lookupExisting() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedFlag(code: corridor.code, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Cash out · \(corridor.name)")
                    .font(TaliseFont.heading(20, weight: .medium))
                    .kerning(-0.4)
                    .foregroundStyle(TaliseColor.fg)
                Text("Pay out to your \(corridor.currencyCode) bank account.")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var lookupCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(TaliseColor.greenMint)
            Text("Checking your cash-out details…")
                .font(TaliseFont.body(14, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            Spacer(minLength: 0)
        }
        .padding(18)
        .rampCard()
    }

    // ── Step 1: USDC pocket — swap USDsui → USDC ───────────────────────
    private var pocketCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("USDC POCKET")
                        .font(TaliseFont.mono(10, weight: .regular)).kerning(1)
                        .foregroundStyle(TaliseColor.fgDim)
                    Text("\(String(format: "%.2f", usdcPocket)) USDC")
                        .font(TaliseFont.heading(28, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                }
                Spacer(minLength: 0)
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(TaliseColor.greenMint)
            }
            Divider().overlay(TaliseColor.line)
            Text("Top up your pocket by swapping USDsui → USDC.")
                .font(TaliseFont.body(12.5, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    TextField("0", text: $swapText)
                        .font(TaliseFont.body(16, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: .infinity)
                    Text("USDsui").font(TaliseFont.mono(11, weight: .regular)).foregroundStyle(TaliseColor.fgDim)
                }
                .padding(.horizontal, 12).frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(TaliseColor.surface2))
                Button {
                    Task { await doSwapToUsdc() }
                } label: {
                    HStack(spacing: 6) {
                        if swapping { ProgressView().tint(.black) }
                        Text(swapping ? "Swapping…" : "Swap")
                    }
                    .font(TaliseFont.body(15, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 22).frame(height: 46)
                    .background(Capsule().fill(canSwap ? TaliseColor.greenMint : TaliseColor.surface2))
                }
                .buttonStyle(.plain).disabled(!canSwap).opacity(canSwap ? 1 : 0.6)
            }
            Text(balanceUsdsui.map { "\(String(format: "%.2f", $0)) USDsui available" } ?? "Loading…")
                .font(TaliseFont.body(11.5, weight: .light)).foregroundStyle(TaliseColor.fgDim)
            if let swapError {
                Text(swapError).font(TaliseFont.body(12.5, weight: .light)).foregroundStyle(Color(hex: 0xFF6B6B))
            }
        }
        .padding(18).rampCard()
    }

    // ── Step 2: send USDC → bank ───────────────────────────────────────
    private var sendCard: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("WITHDRAW TO BANK")
                    .font(TaliseFont.mono(10, weight: .regular)).kerning(1)
                    .foregroundStyle(TaliseColor.fgDim)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    TextField("0", text: $amountText)
                        .font(TaliseFont.heading(44, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .keyboardType(.decimalPad).multilineTextAlignment(.center).fixedSize()
                    Text("USDC").font(TaliseFont.mono(13, weight: .regular)).foregroundStyle(TaliseColor.fgMuted)
                }
                Text(sendLine)
                    .font(TaliseFont.body(12.5, weight: .light))
                    .foregroundStyle(sendAmount > usdcPocket ? Color(hex: 0xFF6B6B) : TaliseColor.fgMuted)
            }
            .frame(maxWidth: .infinity).padding(.top, 6)

            if let b = payoutBank, let bank = b.bankName, let last4 = b.accountLast4 {
                HStack(spacing: 8) {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(TaliseColor.greenMint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Paying out to \(bank) ••\(last4)")
                            .font(TaliseFont.body(13.5, weight: .regular)).foregroundStyle(TaliseColor.fg)
                        if let owner = b.accountOwnerName {
                            Text("\(owner) · \((b.accountType ?? "").capitalized) · \(b.destinationPaymentRail.uppercased())")
                                .font(TaliseFont.mono(10, weight: .regular)).foregroundStyle(TaliseColor.fgDim)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TaliseColor.surface2.opacity(0.6)))
            }

            if let withdrawError {
                Text(withdrawError).font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(Color(hex: 0xFF6B6B)).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }

            Button {
                Task { await doSendUsdc() }
            } label: {
                HStack(spacing: 8) {
                    if sending { ProgressView().tint(.black) }
                    Text(sending ? "Sending…" : "Withdraw")
                }
                .font(TaliseFont.body(16, weight: .semibold)).foregroundStyle(.black)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(Capsule().fill(canSend ? TaliseColor.greenMint : TaliseColor.surface2))
            }
            .buttonStyle(.plain).disabled(!canSend).opacity(canSend ? 1 : 0.6)

            HStack(spacing: 7) {
                Image(systemName: "building.columns").font(.system(size: 10, weight: .medium)).foregroundStyle(TaliseColor.fgDim)
                Text(wireTimingText).font(TaliseFont.mono(10, weight: .light)).kerning(0.2)
                    .foregroundStyle(TaliseColor.fgDim).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(18).rampCard()
    }

    private var sendLine: String {
        if sendAmount > usdcPocket { return "Over your \(String(format: "%.2f", usdcPocket)) USDC pocket" }
        if sendAmount > 0 && sendAmount < minSend { return "Minimum is $1.00" }
        return "\(String(format: "%.2f", usdcPocket)) USDC in pocket · min $1.00"
    }

    /// USD → Wire; EUR → SEPA. Honest, non-committal timing language.
    private var wireTimingText: String {
        isEur
            ? "Paid out by SEPA — typically arrives within a business day."
            : "Paid out by wire — typically arrives within a business day."
    }

    private var successCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Withdrawal on its way", systemImage: "checkmark.circle.fill")
                .font(TaliseFont.heading(16, weight: .semibold))
                .foregroundStyle(TaliseColor.greenMint)
            Text("Your USDC was sent for payout. The \(isEur ? "SEPA" : "wire") transfer to your \(corridor.currencyCode) bank typically arrives within a business day.")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .rampCard()
    }

    // ── One-time bank setup form ───────────────────────────────────────
    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add your \(corridor.currencyCode) bank")
                .font(TaliseFont.heading(15, weight: .semibold))
                .foregroundStyle(TaliseColor.fg)
            Text("One-time setup. After this you'll just enter an amount to withdraw.")
                .font(TaliseFont.body(12.5, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            field("Account holder name", text: $ownerName)
            if isUsd {
                field("Account number", text: $accountNumber, keyboard: .numberPad)
                field("Routing number", text: $routingNumber, keyboard: .numberPad)
                Toggle(isOn: $savings) {
                    Text("Savings account")
                        .font(TaliseFont.body(14, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                }
                .tint(TaliseColor.greenDeep)
                field("Street address", text: $street)
                HStack(spacing: 10) {
                    field("City", text: $city)
                    field("State", text: $state)
                }
                field("ZIP code", text: $zip, keyboard: .numbersAndPunctuation)
            } else if isEur {
                HStack(spacing: 10) {
                    field("First name", text: $firstName)
                    field("Last name", text: $lastName)
                }
                field("IBAN", text: $iban)
                field("BIC / SWIFT", text: $bic)
            }
        }
        .padding(18)
        .rampCard()
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(TaliseFont.mono(10, weight: .regular))
                .kerning(0.4)
                .foregroundStyle(TaliseColor.fgDim)
            TextField("", text: text)
                .font(TaliseFont.body(15, weight: .regular))
                .foregroundStyle(TaliseColor.fg)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(label.contains("name") ? .words : .never)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(TaliseColor.surface2)
                )
        }
    }

    private var submitButton: some View {
        Button {
            Task { await setupRoute() }
        } label: {
            HStack(spacing: 8) {
                if submitting { ProgressView().tint(.black) }
                Text(submitting ? "Setting up…" : "Save bank")
            }
            .font(TaliseFont.body(15, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(canSubmitSetup ? TaliseColor.greenMint : TaliseColor.surface2))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmitSetup || submitting)
        .opacity(canSubmitSetup ? 1 : 0.6)
    }

    private var unsupportedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cash-out coming soon")
                .font(TaliseFont.heading(16, weight: .semibold))
                .foregroundStyle(TaliseColor.fg)
            Text("Direct bank cash-out for \(corridor.name) is on the way. USD is supported today.")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .rampCard()
    }

    // ── Actions ────────────────────────────────────────────────────────

    /// Reuse-first: does a payout route already exist for this corridor? If so,
    /// go straight to the amount entry. Also loads the spendable USDsui balance.
    private func lookupExisting() async {
        guard supported else { checking = false; return }
        defer { checking = false }
        let probe = isUsd
            ? CashOutRequest(rail: "wire", currency: "usd", accountOwnerName: "")
            : CashOutRequest(rail: "sepa", currency: "eur", accountOwnerName: "")
        if let res = try? await BridgeRampAPI.cashOutAddress(probe) {
            hasRoute = true
            payoutBank = res
            usdcPocket = (res.usdcMicros.flatMap { Double($0) } ?? 0) / 1_000_000
        }
        let bal: BalancesDTO? = try? await APIClient.shared.get("/api/balances")
        balanceUsdsui = bal?.usdsui
    }

    /// Re-read the route + USDC pocket balance (e.g. after a swap fills it).
    private func refreshPocket() async {
        let probe = isUsd
            ? CashOutRequest(rail: "wire", currency: "usd", accountOwnerName: "")
            : CashOutRequest(rail: "sepa", currency: "eur", accountOwnerName: "")
        if let res = try? await BridgeRampAPI.cashOutAddress(probe) {
            payoutBank = res
            usdcPocket = (res.usdcMicros.flatMap { Double($0) } ?? 0) / 1_000_000
        }
        let bal: BalancesDTO? = try? await APIClient.shared.get("/api/balances")
        balanceUsdsui = bal?.usdsui
    }

    /// First-time bank registration → creates the persistent payout route, then
    /// flips into the amount-entry withdraw UI (address never shown).
    private func setupRoute() async {
        submitting = true
        setupError = nil
        defer { submitting = false }
        let req: CashOutRequest
        if isUsd {
            req = CashOutRequest(
                rail: "wire", currency: "usd", accountOwnerName: ownerName,
                accountNumber: accountNumber, routingNumber: routingNumber,
                checkingOrSavings: savings ? "savings" : "checking",
                country: "USA",
                street: street, city: city, state: state, postalCode: zip
            )
        } else {
            req = CashOutRequest(
                rail: "sepa", currency: "eur", accountOwnerName: ownerName,
                firstName: firstName, lastName: lastName,
                iban: iban, bic: bic, country: "DEU"
            )
        }
        do {
            _ = try await BridgeRampAPI.cashOutAddress(req)
            if balanceUsdsui == nil {
                let bal: BalancesDTO? = try? await APIClient.shared.get("/api/balances")
                balanceUsdsui = bal?.usdsui
            }
            hasRoute = true
        } catch {
            let msg = (error as NSError).localizedDescription
            if msg.contains("503") || msg.contains("disabled") {
                setupError = "Cash-out isn't switched on yet. Please try again soon."
            } else if msg.contains("409") || msg.contains("CUSTOMER") {
                setupError = "Finish identity verification (Add money) first, then cash out."
            } else {
                setupError = "We couldn't save your bank. Check your details and try again."
            }
        }
    }

    /// Step 1 — swap USDsui → USDC into the pocket (1% fee), then refresh.
    private func doSwapToUsdc() async {
        guard canSwap else { return }
        swapping = true
        swapError = nil
        defer { swapping = false }
        do {
            let prep = try await BridgeRampAPI.swapToUsdc(amountUsdsui: swapAmount)
            _ = try await ZkLoginCoordinator.shared.signAndExecuteRaw(
                bytesB64: prep.bytes,
                meta: ["kind": "swap", "amountUsd": swapAmount]
            )
            swapText = ""
            await refreshPocket()
        } catch {
            swapError = "Couldn't swap to USDC. Please try again."
        }
    }

    /// Step 2 — plain USDC send from the pocket to the Bridge address.
    private func doSendUsdc() async {
        guard canSend else { return }
        sending = true
        withdrawError = nil
        defer { sending = false }
        do {
            let prep = try await BridgeRampAPI.sendUsdc(
                amountUsdc: sendAmount,
                currency: corridor.currencyCode
            )
            _ = try await ZkLoginCoordinator.shared.signAndExecuteRaw(
                bytesB64: prep.bytes,
                meta: ["kind": "withdraw", "amountUsd": sendAmount]
            )
            withdrawDone = true
        } catch {
            let msg = (error as NSError).localizedDescription
            if msg.contains("NO_ROUTE") {
                withdrawError = "Set up your bank first, then withdraw."
                hasRoute = false
            } else if msg.contains("BELOW_BRIDGE_MIN") {
                withdrawError = "Bridge's minimum is $1.00 — send at least $1.00 in USDC."
            } else if msg.contains("INSUFFICIENT_USDC") {
                withdrawError = "Not enough USDC in your pocket — swap USDsui → USDC first."
            } else {
                withdrawError = "We couldn't complete your withdrawal. Please try again."
            }
        }
    }
}
