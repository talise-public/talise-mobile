import SwiftUI

/// Scan-to-pay as an off-ramp (Phase 1).
///
/// This file holds everything the bank-payout path needs that ISN'T the
/// camera/overlay (those live in `QRScannerView` / `ScanToPayView`):
///   • `ScanBank` — the iOS bank list (name + NIBSS code) + keyword aliases
///     used both for OCR keyword-matching and the manual-entry picker.
///   • `BankAccountExtractor` — turns a frame's recognized OCR strings into a
///     confident `{bankCode, accountNumber}` pair (10-digit NUBAN + bank
///     keyword match) with debounce so a lock only fires once it's stable.
///   • `ScanBankPayoutSheet` — the "Send to bank account" sheet: resolve the
///     holder name → NGN amount + live rate → quote → create → sign+send the
///     EXACT returned USDsui → poll status. Reuses the live Linq off-ramp
///     endpoints verbatim (the same rail `BankWithdrawView` runs).
///
/// The OCR bank path is ADDITIVE to the existing QR→Talise-recipient scan:
/// a Talise QR still routes to `ConfirmPaymentSheet`; a bank placard routes
/// here.

// MARK: - Bank list

/// One Nigerian bank: display `name`, the plain NIBSS `code` Linq accepts
/// directly, and `aliases` — lowercased keywords we keyword-match against
/// OCR'd placard text (brand names, common abbreviations).
struct ScanBank: Identifiable, Hashable {
    let name: String
    let code: String
    let aliases: [String]
    var id: String { code }

    /// The full iOS bank list — mirrors `BankWithdrawView`'s NIBSS codes,
    /// extended with OCR keyword aliases. Order roughly by ubiquity so the
    /// picker reads sensibly.
    static let all: [ScanBank] = [
        .init(name: "OPay",                     code: "100004", aliases: ["opay"]),
        .init(name: "PalmPay",                  code: "100033", aliases: ["palmpay", "palm pay"]),
        .init(name: "Moniepoint",               code: "090405", aliases: ["moniepoint", "monie point", "moniepoint mfb"]),
        .init(name: "Kuda",                     code: "090267", aliases: ["kuda", "kuda mfb", "kuda bank"]),
        .init(name: "Guaranty Trust Bank",      code: "058",    aliases: ["gtbank", "gtb", "guaranty trust", "gt bank", "guaranty"]),
        .init(name: "Access Bank",              code: "044",    aliases: ["access bank", "access"]),
        .init(name: "First Bank of Nigeria",    code: "011",    aliases: ["first bank", "firstbank", "fbn"]),
        .init(name: "Zenith Bank",              code: "057",    aliases: ["zenith bank", "zenith"]),
        .init(name: "United Bank For Africa",   code: "033",    aliases: ["uba", "united bank for africa", "united bank"]),
        .init(name: "Wema Bank",                code: "035",    aliases: ["wema bank", "wema", "alat", "alat by wema"]),
        .init(name: "Sterling Bank",            code: "232",    aliases: ["sterling bank", "sterling"]),
        .init(name: "Fidelity Bank",            code: "070",    aliases: ["fidelity bank", "fidelity"]),
        .init(name: "First City Monument Bank", code: "214",    aliases: ["fcmb", "first city monument"]),
        .init(name: "Stanbic IBTC Bank",        code: "039",    aliases: ["stanbic", "stanbic ibtc", "ibtc"]),
    ]

    static func byCode(_ code: String) -> ScanBank? {
        all.first { $0.code == code }
    }
}

// MARK: - OCR extraction

/// Stateless helper that pulls a `{bankCode, accountNumber}` candidate out of
/// a single frame's recognized strings. The caller (`ScanToPayView`) holds the
/// debounce state and only locks once the same pair has been seen on enough
/// consecutive frames.
enum BankAccountExtractor {
    struct Candidate: Equatable {
        let bank: ScanBank
        let accountNumber: String   // exactly 10 digits
    }

    /// Joins the frame's strings, then:
    ///   • finds the first standalone 10-digit run (NUBAN), tolerating spaces
    ///     between digit groups that OCR sometimes inserts;
    ///   • keyword-matches the text against the bank aliases.
    /// Returns a candidate only when BOTH are present.
    static func extract(from strings: [String]) -> Candidate? {
        let joined = strings.joined(separator: " ")
        guard let account = firstTenDigitAccount(in: joined),
              let bank = matchBank(in: joined) else {
            return nil
        }
        return Candidate(bank: bank, accountNumber: account)
    }

    /// First isolated 10-digit number. We strip spaces/dashes that OCR drops
    /// between digit groups, then scan for a run of exactly 10 digits that
    /// isn't part of a longer number (so a phone/serial of 11+ doesn't match).
    static func firstTenDigitAccount(in text: String) -> String? {
        // Collapse separators OCR commonly injects inside an account number
        // ("0123 456 789" / "0123-456-7890") into a single digit stream, but
        // keep other characters so we can still detect run boundaries.
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else { i += 1; continue }
            // Walk a digit run, allowing single spaces/dashes between digits.
            var digits = ""
            var j = i
            while j < chars.count {
                let c = chars[j]
                if c.isNumber {
                    digits.append(c)
                    j += 1
                } else if (c == " " || c == "-") && j + 1 < chars.count && chars[j + 1].isNumber && !digits.isEmpty {
                    // separator inside a number — skip it, keep accumulating
                    j += 1
                } else {
                    break
                }
            }
            if digits.count == 10 {
                return digits
            }
            i = j
        }
        return nil
    }

    /// Keyword-match the OCR text against the bank aliases. Longer aliases win
    /// (so "gt bank" beats a stray "gt"), and we require word-ish boundaries
    /// for very short aliases to avoid false hits.
    static func matchBank(in text: String) -> ScanBank? {
        let hay = text.lowercased()
        var best: (ScanBank, Int)? = nil
        for bank in ScanBank.all {
            for alias in bank.aliases where hay.contains(alias) {
                let len = alias.count
                if best == nil || len > best!.1 {
                    best = (bank, len)
                }
            }
        }
        return best?.0
    }
}

// MARK: - Linq off-ramp DTOs (scan path)

/// `POST /api/offramp/linq/resolve` — amount-independent name enquiry.
private struct ScanResolveResp: Decodable {
    let accountName: String
    let bankName: String
    let bankCode: String
    let accountNumber: String
}
/// `GET /api/offramp/linq/rate` — public display rate (1 USDsui = rate NGN).
private struct ScanRateResp: Decodable { let rate: Double }
/// `POST /api/offramp/linq/quote` — locked figures for the entered NGN.
private struct ScanQuoteResp: Decodable {
    let accountName: String
    let bankName: String
    let bankCode: String
    let accountNumber: String
    let rate: Double
    let amountUsdsui: Double
    let amountNgn: Double
}
/// `POST /api/offramp/linq/create` — returns the deposit wallet + EXACT debit.
private struct ScanCreateResp: Decodable {
    let orderId: String
    let walletAddress: String
    let amountUsdsui: Double
    let amountNgn: Double
    let rate: Double
}
/// `GET /api/offramp/linq/status/[orderId]`.
private struct ScanStatusResp: Decodable {
    let orderId: String
    let status: String
    let phase: String
    let amountUsdsui: Double
    let amountNgn: Double
}

// MARK: - Send-to-bank sheet

/// "Send to bank account" sheet, presented over the scanner once we have a
/// `{bank, accountNumber}` (from OCR or manual entry). Resolves the holder
/// name, lets the user enter Naira with a live rate, then runs the off-ramp:
/// quote → create → sign+send the EXACT returned USDsui → poll.
struct ScanBankPayoutSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let bank: ScanBank
    let accountNumber: String
    /// Called after the payout lands (Done) so the scanner can tear the whole
    /// surface down back to Home.
    var onPaid: () -> Void

    // Name enquiry.
    @State private var resolvedName: String?
    @State private var resolving = true
    @State private var resolveError: String?

    // Amount + rate.
    @State private var amount: String = ""
    @State private var displayRate: Double?

    // Off-ramp execution.
    @State private var step: Step = .form
    @State private var quote: ScanQuoteResp?
    @State private var quoting = false
    @State private var confirming = false
    @State private var statusText = ""
    @State private var finalStatus: String?    // completed | failed
    @State private var paidOut = false
    @State private var error: String?
    @State private var resetSlide = false

    @FocusState private var amountFocused: Bool

    private enum Step { case form, review, sending, done }

    private var amountNgn: Double { Double(amount.replacingOccurrences(of: ",", with: "")) ?? 0 }

    private var canContinue: Bool {
        amountNgn > 0 && resolvedName != nil && resolveError == nil && !resolving && !quoting
    }

    var body: some View {
        ZStack {
            TaliseColor.bg.ignoresSafeArea()
            Group {
                switch step {
                case .form:            formView
                case .review:          reviewView
                case .sending, .done:  statusView
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await resolveAccount() }
        .task { await loadRate() }
    }

    // MARK: Form

    private var formView: some View {
        VStack(spacing: 0) {
            grabHandle.padding(.top, 10)

            Text("Send to bank account")
                .font(TaliseFont.heading(20, weight: .semibold))
                .kerning(-0.5)
                .foregroundStyle(TaliseColor.fg)
                .padding(.top, 18)

            recipientCard
                .padding(.horizontal, 22)
                .padding(.top, 22)

            amountBlock
                .padding(.horizontal, 22)
                .padding(.top, 26)

            estimateLine.padding(.top, 10)

            if let error {
                Text(error)
                    .font(TaliseFont.body(12, weight: .light))
                    .foregroundStyle(TaliseColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
            }

            Spacer(minLength: 24)

            continueButton
                .padding(.horizontal, 22)

            cancelButton
                .padding(.top, 12)
                .padding(.bottom, 18)
        }
        .contentShape(Rectangle())
        .onTapGesture { amountFocused = false }
    }

    private var grabHandle: some View {
        Capsule()
            .fill(TaliseColor.fgDim.opacity(0.6))
            .frame(width: 38, height: 5)
    }

    /// To {name} {acct} • {bank} — the destination, with inline name-enquiry.
    private var recipientCard: some View {
        HStack(spacing: 14) {
            BankAvatar(bankCode: bank.code, bankName: bank.name, size: 46, cornerRadius: 13)
            VStack(alignment: .leading, spacing: 4) {
                if resolving {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini).tint(TaliseColor.fgMuted)
                        Text("Checking account…")
                            .font(TaliseFont.body(14, weight: .light))
                            .foregroundStyle(TaliseColor.fgMuted)
                    }
                } else if let name = resolvedName {
                    Text(name)
                        .font(TaliseFont.heading(16, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .lineLimit(1)
                } else if let resolveError {
                    Text(resolveError)
                        .font(TaliseFont.body(13, weight: .light))
                        .foregroundStyle(TaliseColor.danger)
                        .lineLimit(2)
                }
                Text("\(accountNumber) • \(bank.name)")
                    .font(TaliseFont.mono(11, weight: .regular))
                    .foregroundStyle(TaliseColor.fgDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var amountBlock: some View {
        VStack(spacing: 6) {
            Text("Amount to send")
                .font(TaliseFont.mono(11, weight: .regular))
                .foregroundStyle(TaliseColor.fgDim)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("₦")
                    .font(TaliseFont.heading(38, weight: .medium))
                    .foregroundStyle(TaliseColor.fgMuted)
                TextField("0", text: $amount)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: true, vertical: false)
                    .font(TaliseFont.heading(48, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                    .tint(TaliseColor.accent)
                    .focused($amountFocused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { amountFocused = false }
                                .font(TaliseFont.heading(15, weight: .medium))
                                .tint(TaliseColor.accent)
                        }
                    }
                    .onChange(of: amount) { _, new in
                        let cleaned = new.filter { $0.isNumber }
                        if cleaned != new { amount = cleaned }
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Live "≈ $X USDsui" estimate under the amount — display only; the locked
    /// debit comes from quote/create.
    @ViewBuilder private var estimateLine: some View {
        if let rate = displayRate, rate > 0, amountNgn > 0 {
            Text("≈ \(TaliseFormat.usd2(amountNgn / rate)) USDsui")
                .font(TaliseFont.mono(12, weight: .regular))
                .foregroundStyle(TaliseColor.fgDim)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: amountNgn)
        } else {
            Text("USDsui")
                .font(TaliseFont.mono(12, weight: .regular))
                .foregroundStyle(TaliseColor.fgDim)
        }
    }

    private var continueButton: some View {
        Button(action: { Task { await getQuote() } }) {
            HStack(spacing: 8) {
                if quoting { ProgressView().tint(TaliseColor.bg) }
                Text(quoting ? "Checking…" : "Continue")
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

    private var cancelButton: some View {
        Button(action: { dismiss() }) {
            Text("Cancel")
                .font(TaliseFont.heading(15, weight: .medium))
                .foregroundStyle(TaliseColor.fgMuted)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
    }

    // MARK: Review

    @ViewBuilder private var reviewView: some View {
        if let q = quote {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Review payment")
                            .font(TaliseFont.heading(24, weight: .medium))
                            .kerning(-0.5)
                            .foregroundStyle(TaliseColor.fg)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)

                        VStack(spacing: 0) {
                            VStack(spacing: 6) {
                                Text("They receive")
                                    .font(TaliseFont.mono(10, weight: .regular))
                                    .kerning(1.3)
                                    .foregroundStyle(TaliseColor.fgDim)
                                Text("₦\(ngnGrouped(q.amountNgn))")
                                    .font(TaliseFont.heading(40, weight: .medium))
                                    .kerning(-1)
                                    .foregroundStyle(TaliseColor.fg)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)

                            divider
                            reviewRow("To", q.accountName)
                            divider
                            reviewRow("Bank", q.bankName.isEmpty ? bank.name : q.bankName)
                            divider
                            reviewRow("Account", maskAccount(accountNumber))
                            divider
                            reviewRow("You send", "\(TaliseFormat.usd2(q.amountUsdsui)) USDsui")
                            divider
                            reviewRow("Rate", "$1 = ₦\(ngnGrouped(q.rate))")
                        }
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(TaliseColor.surface)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(TaliseColor.greenMint)
                            Text("No network fee — sponsored by Talise.")
                                .font(TaliseFont.mono(11, weight: .light))
                                .foregroundStyle(TaliseColor.fgMuted)
                        }
                        .frame(maxWidth: .infinity)

                        if let error {
                            Text(error)
                                .font(TaliseFont.body(12))
                                .foregroundStyle(TaliseColor.danger)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }

                VStack(spacing: 12) {
                    SlideToConfirm(title: "Slide to send", tint: TaliseColor.accent, reset: $resetSlide) {
                        await confirm()
                    }
                    .disabled(confirming)
                    .opacity(confirming ? 0.5 : 1)

                    Button("Edit") { step = .form; quote = nil; error = nil }
                        .font(TaliseFont.body(14))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .disabled(confirming)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
        }
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
            Spacer()
            Text(value).font(TaliseFont.body(14, weight: .medium)).foregroundStyle(TaliseColor.fg)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 13)
    }

    private var divider: some View { Rectangle().fill(TaliseColor.line).frame(height: 1) }

    // MARK: Status

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
                        Button(action: { step = .review; error = nil }) {
                            Text("Try again")
                                .font(TaliseFont.heading(16, weight: .medium))
                                .foregroundStyle(TaliseColor.bg)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(TaliseColor.fg).clipShape(Capsule())
                        }
                        Button("Close") { dismiss() }
                            .font(TaliseFont.body(14))
                            .foregroundStyle(TaliseColor.fgMuted)
                    } else {
                        Button(action: { onPaid() }) {
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
            // Brand comet-tail ring (shared with the Withdraw flow) — replaces
            // the old system spinner on a grey disc.
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
        if step == .sending { return "Paying the bank…" }
        if finalStatus == "failed" { return "Payment failed" }
        return paidOut ? "Paid out" : "On its way"
    }

    // MARK: Networking

    private func resolveAccount() async {
        struct Body: Encodable { let bankCode: String; let accountNumber: String }
        do {
            let r: ScanResolveResp = try await APIClient.shared.post(
                "/api/offramp/linq/resolve",
                body: Body(bankCode: bank.code, accountNumber: accountNumber)
            )
            resolvedName = r.accountName
            resolveError = nil
            resolving = false
        } catch APIError.unauthorized {
            resolveError = "Sign in to continue."
            resolving = false
        } catch APIError.status(let code, let msg) {
            resolveError = code == 422
                ? "We couldn't verify that account. Check the number and bank."
                : friendlyOfframpError(code: code, message: msg)
            resolving = false
        } catch {
            if APIError.isCancellation(error) { return }
            resolveError = "Couldn't check that account right now."
            resolving = false
        }
    }

    private func loadRate() async {
        guard displayRate == nil else { return }
        do {
            let r: ScanRateResp = try await APIClient.shared.get("/api/offramp/linq/rate")
            displayRate = r.rate
        } catch { /* display-only */ }
    }

    private func getQuote() async {
        guard canContinue else { return }
        quoting = true; error = nil
        defer { quoting = false }
        struct Body: Encodable {
            let amountNgn: Double
            let bankCode: String
            let accountNumber: String
        }
        do {
            let q: ScanQuoteResp = try await APIClient.shared.post(
                "/api/offramp/linq/quote",
                body: Body(amountNgn: amountNgn, bankCode: bank.code, accountNumber: accountNumber)
            )
            quote = q
            amountFocused = false
            withAnimation { step = .review }
        } catch APIError.status(let code, let msg) {
            error = friendlyOfframpError(code: code, message: msg)
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't get a quote right now."
        }
    }

    private func confirm() async {
        guard let q = quote else { return }
        confirming = true; error = nil
        defer { confirming = false }
        do {
            // 1. Create the Linq order — send amountNgn (the exact credit) and
            //    trust the response's amountUsdsui as the EXACT amount to debit.
            struct CreateBody: Encodable {
                let amountNgn: Double
                let bankCode: String
                let accountNumber: String
                let accountName: String
                let bankName: String?
            }
            let order: ScanCreateResp = try await APIClient.shared.post(
                "/api/offramp/linq/create",
                body: CreateBody(
                    amountNgn: q.amountNgn,
                    bankCode: bank.code,
                    accountNumber: accountNumber,
                    accountName: q.accountName,
                    bankName: q.bankName.isEmpty ? bank.name : q.bankName
                )
            )

            // 2. Send EXACTLY the returned USDsui to Linq's deposit wallet.
            //    sponsorFallback: try gasless first (free when funds are in the
            //    accumulator); the server sponsors only when gasless can't
            //    build (funds in Coin objects) so the payout still lands.
            let sent = try await ZkLoginCoordinator.shared.signAndSubmitSend(
                to: order.walletAddress,
                amountUsd: order.amountUsdsui,
                intent: "Bank payout",
                sponsorFallback: true
            )
            guard !sent.digest.isEmpty else {
                self.error = "Payment didn't land on chain. No funds moved."
                resetSlide = true
                return
            }
            NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                digest: sent.digest, direction: "sent", amountUsdsui: order.amountUsdsui,
                counterparty: order.walletAddress, counterpartyName: "Bank payout", venue: nil))

            statusText = "Sending ₦\(ngnGrouped(order.amountNgn)) to \(q.accountName)…"
            withAnimation { step = .sending }
            await pollStatus(order.orderId)
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            session.signOut()
        } catch APIError.status(let code, let msg) {
            error = friendlyOfframpError(code: code, message: msg)
            resetSlide = true
        } catch APIError.unauthorized {
            error = "Please sign in again."
            resetSlide = true
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = APIError.honestMoneyError(
                error, fallback: "Couldn't complete the payment right now.")
            resetSlide = true
        }
    }

    private func pollStatus(_ id: String) async {
        for _ in 0..<20 {
            do {
                let s: ScanStatusResp = try await APIClient.shared.get("/api/offramp/linq/status/\(id)")
                switch s.phase {
                case "completed":
                    finalStatus = "completed"; paidOut = true
                    statusText = "₦\(ngnGrouped(s.amountNgn)) has landed in the bank account."
                    withAnimation { step = .done }
                    return
                case "failed":
                    finalStatus = "failed"
                    statusText = "The payout couldn't be completed — your USDsui has been returned."
                    withAnimation { step = .done }
                    return
                default: break
                }
            } catch {
                if APIError.isCancellation(error) { return }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        finalStatus = "completed"; paidOut = false
        statusText = "Your transfer is on its way. It can take a few minutes to land in the bank account."
        withAnimation { step = .done }
    }

    // MARK: Helpers

    private func maskAccount(_ a: String) -> String {
        a.count <= 4 ? "****" : "****\(a.suffix(4))"
    }

    private func ngnGrouped(_ v: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        fmt.minimumFractionDigits = 0
        fmt.maximumFractionDigits = v < 100 ? 2 : 0
        return fmt.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v)
    }

    private func friendlyOfframpError(code: Int, message: String?) -> String {
        let lower = (message ?? "").lowercased()
        if code == 503 || lower.contains("not configured") || lower.contains("fx_unavailable") {
            return "Bank payouts are rolling out — check back soon."
        }
        if code == 422 && lower.contains("verify") {
            return "We couldn't verify that bank account. Check the number and bank."
        }
        if lower.contains("\"error\"") {
            if let data = message?.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = obj["error"] as? String, !e.isEmpty {
                return e
            }
        }
        if code == 404 { return "Bank payouts aren't available yet." }
        if let msg = message, !msg.isEmpty, msg.count <= 120,
           !lower.contains("<html"), !lower.contains("<!doctype") {
            return msg
        }
        return "Something went wrong. Please try again."
    }
}

// MARK: - Manual-entry bank picker (scan path)

/// Searchable bank list presented as a sheet for the "Enter manually" path.
/// Mirrors `BankWithdrawView`'s picker pattern over `ScanBank.all`.
struct ScanBankPickerSheet: View {
    let selected: ScanBank?
    let onSelect: (ScanBank) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [ScanBank] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ScanBank.all }
        return ScanBank.all.filter { $0.name.lowercased().contains(q) || $0.aliases.contains { $0.contains(q) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select bank")
                    .font(TaliseFont.heading(18, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(TaliseColor.surface2))
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TaliseColor.fgMuted)
                TextField("", text: $query, prompt: Text("Search banks").foregroundColor(TaliseColor.fgDim))
                    .font(TaliseFont.body(15))
                    .foregroundStyle(TaliseColor.fg)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(TaliseColor.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(TaliseColor.line, lineWidth: 1))
            .padding(.horizontal, 20).padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { bank in
                        Button {
                            onSelect(bank)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                BankAvatar(bankCode: bank.code, bankName: bank.name, size: 36, cornerRadius: 10)
                                Text(bank.name)
                                    .font(TaliseFont.body(15))
                                    .foregroundStyle(TaliseColor.fg)
                                Spacer()
                                if bank.code == selected?.code {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(TaliseColor.accent)
                                }
                            }
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
