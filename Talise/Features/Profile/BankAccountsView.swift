import SwiftUI

// MARK: - Bank account DTOs
//
// Mirrors the off-ramp Phase 2 backend contract:
//   GET    /api/me/bank                → [BankAccountDTO]
//   POST   /api/me/bank/link/prepare   → BankLinkPrepareResp
//   POST   /api/me/bank/link/confirm   → BankAccountDTO
//   DELETE /api/me/bank/[id]           → { ok }

/// One linked bank account as stored server-side. `attested` is the
/// on-chain / signed-attestation flag that earns the "verified" check.
struct BankAccountDTO: Decodable, Identifiable, Hashable {
    let id: String
    let bankCode: String
    let bankName: String
    let accountName: String
    let last4: String
    let attested: Bool
}

/// `POST /api/me/bank/link/prepare` response. The server returns EITHER
/// `bytes` — a sponsored attestation tx to sign + submit — OR
/// `attestMessage` — a string to sign as a personal message. We handle
/// whichever is present. The resolved `accountName` lets the user confirm
/// the holder before committing.
private struct BankLinkPrepareResp: Decodable {
    let bytes: String?
    let attestMessage: String?
    let accountName: String
    let bankName: String
    let bankCode: String
    let accountNumber: String
    let last4: String
}

/// `DELETE /api/me/bank/[id]` response.
private struct OkResp: Decodable { let ok: Bool }

// MARK: - One bank option (NIBSS code + display name)

/// Matches the `OfframpBank` shape used by the Withdraw flow — `bankCode`
/// is the plain NIBSS code the backend accepts directly.
struct LinkBank: Identifiable, Hashable {
    let name: String
    let bankCode: String
    var id: String { bankCode }
}

/// Shared NIBSS bank list — same set the Withdraw off-ramp uses. Kept here
/// (rather than imported from the `private` Withdraw list) so this screen
/// is self-contained.
enum NIBSSBanks {
    static let all: [LinkBank] = [
        .init(name: "Access Bank",              bankCode: "044"),
        .init(name: "Guaranty Trust Bank",      bankCode: "058"),
        .init(name: "First Bank of Nigeria",    bankCode: "011"),
        .init(name: "Zenith Bank",              bankCode: "057"),
        .init(name: "United Bank For Africa",   bankCode: "033"),
        .init(name: "Wema Bank",                bankCode: "035"),
        .init(name: "Sterling Bank",            bankCode: "232"),
        .init(name: "Fidelity Bank",            bankCode: "070"),
        .init(name: "First City Monument Bank", bankCode: "214"),
        .init(name: "Stanbic IBTC Bank",        bankCode: "039"),
        .init(name: "Union Bank",               bankCode: "032"),
        .init(name: "Polaris Bank",             bankCode: "076"),
        .init(name: "Ecobank",                  bankCode: "050"),
        .init(name: "Keystone Bank",            bankCode: "082"),
        .init(name: "Heritage Bank",            bankCode: "030"),
        .init(name: "Unity Bank",               bankCode: "215"),
        .init(name: "Providus Bank",            bankCode: "101"),
        .init(name: "Kuda",                     bankCode: "090267"),
        .init(name: "OPay",                     bankCode: "100004"),
        .init(name: "PalmPay",                  bankCode: "100033"),
        .init(name: "Moniepoint",               bankCode: "090405"),
    ]
}

// MARK: - Linked bank accounts management screen

/// Off-ramp Phase 2 — manage the bank accounts linked to the user's
/// Talise @handle. Lists existing linked accounts (bank + ••••last4 + a
/// verified check), lets the user add a new one (bank picker + account
/// number → name-resolved prepare → attestation sign → confirm), and
/// remove one with a confirm.
struct BankAccountsView: View {
    @State private var accounts: [BankAccountDTO] = []
    @State private var loading = true
    @State private var loadError: String?

    @State private var showAdd = false
    @State private var removing: BankAccountDTO?       // drives the confirm alert
    @State private var removingId: String?             // in-flight DELETE id

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if loading {
                    loadingState
                } else if accounts.isEmpty {
                    emptyState
                } else {
                    accountsSection
                }

                addButton

                if let loadError {
                    Text(loadError)
                        .font(TaliseFont.body(12, weight: .light))
                        .foregroundStyle(TaliseColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .navigationTitle("Bank accounts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TaliseColor.bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showAdd) {
            AddBankAccountView { newAccount in
                // Optimistically insert, then re-sync to pick up server fields.
                if !accounts.contains(where: { $0.id == newAccount.id }) {
                    accounts.insert(newAccount, at: 0)
                }
                Task { await load() }
            }
        }
        .alert(
            "Remove this account?",
            isPresented: Binding(
                get: { removing != nil },
                set: { if !$0 { removing = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let acct = removing { Task { await remove(acct) } }
            }
        } message: {
            if let acct = removing {
                Text("\(acct.bankName) ••••\(acct.last4) will be unlinked from your @handle.")
            }
        }
    }

    // MARK: Sections

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(TaliseColor.fg)
            Text("Loading your accounts…")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Linked bank accounts")
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "building.columns")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .padding(.bottom, 4)
                Text("No accounts linked yet")
                    .font(TaliseFont.heading(15, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                Text("Link a Nigerian bank account to your @handle so you can cash out faster.")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(TaliseColor.surface)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Linked bank accounts")
            VStack(spacing: 0) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { idx, acct in
                    if idx > 0 { LiquidGlassDivider(inset: 18) }
                    accountRow(acct)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(TaliseColor.surface)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func accountRow(_ acct: BankAccountDTO) -> some View {
        HStack(spacing: 12) {
            BankAvatar(bankCode: acct.bankCode, bankName: acct.bankName, size: 38, cornerRadius: 11)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(acct.accountName)
                        .font(TaliseFont.body(14, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .lineLimit(1)
                    if acct.attested {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TaliseColor.accent)
                    }
                }
                Text("\(acct.bankName) ••••\(acct.last4)")
                    .font(TaliseFont.mono(11, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .lineLimit(1)
            }
            Spacer()
            if removingId == acct.id {
                ProgressView().controlSize(.small).tint(TaliseColor.fgMuted)
            } else {
                Button {
                    removing = acct
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color(hex: 0xE08D8A))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var addButton: some View {
        Button {
            showAdd = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("Add bank account")
                    .font(TaliseFont.heading(15, weight: .medium))
            }
            .foregroundStyle(TaliseColor.bg)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(TaliseColor.fg))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Networking

    private func load() async {
        loadError = nil
        do {
            let list: [BankAccountDTO] = try await APIClient.shared.get("/api/me/bank")
            accounts = list
            loading = false
        } catch APIError.unauthorized {
            loadError = "Sign in to manage your bank accounts."
            loading = false
        } catch {
            if APIError.isCancellation(error) { return }
            // Soft-fail on first load; show error only if we have nothing.
            if accounts.isEmpty { loadError = "Couldn't load your bank accounts." }
            loading = false
        }
    }

    private func remove(_ acct: BankAccountDTO) async {
        removing = nil
        removingId = acct.id
        defer { removingId = nil }
        do {
            let _: OkResp = try await APIClient.shared.delete("/api/me/bank/\(acct.id)")
            accounts.removeAll { $0.id == acct.id }
        } catch {
            if APIError.isCancellation(error) { return }
            loadError = "Couldn't remove that account. Please try again."
        }
    }
}

// MARK: - Add bank account flow

/// Two-step add flow inside its own sheet:
///   1. Bank picker + 10-digit account number.
///   2. `/link/prepare` resolves the account name (shown as "✓ NAME") for
///      the user to confirm, then "Link account" signs the attestation
///      (sponsored `bytes` OR a personal `attestMessage`) and POSTs
///      `/link/confirm` with the resulting digest/signature.
/// `internal` (was `private`) so the onboarding bank-link step
/// (`OnboardingBankLinkView`, Nigeria only) can present the exact same
/// add-flow — bank picker → account → `/link/prepare` → sign consent →
/// `/link/confirm` — rather than duplicating it. The first account a user
/// links auto-becomes primary server-side.
struct AddBankAccountView: View {
    /// Called with the stored record once `/link/confirm` succeeds.
    let onLinked: (BankAccountDTO) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedBank: LinkBank?
    @State private var accountNumber = ""
    @State private var showBankPicker = false

    // Prepare / resolved-name state.
    @State private var preparing = false
    @State private var prepared: BankLinkPrepareResp?
    @State private var prepareError: String?

    // Confirm (sign + record) state.
    @State private var linking = false
    @State private var linkError: String?

    private var canPrepare: Bool {
        selectedBank != nil && accountNumber.count == 10 && !preparing
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Bank")
                        bankPickerRow
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Account number")
                        accountField
                        resolvedNameLine
                    }

                    if let prepareError {
                        errorLine(prepareError)
                    }
                    if let linkError {
                        errorLine(linkError)
                    }

                    Spacer(minLength: 8)

                    primaryButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .background(TaliseColor.bg.ignoresSafeArea())
            .navigationTitle("Add bank account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TaliseColor.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(TaliseColor.fgMuted)
                }
            }
            .sheet(isPresented: $showBankPicker) {
                LinkBankPickerSheet(banks: NIBSSBanks.all, selected: selectedBank) { bank in
                    selectedBank = bank
                    // Bank changed — invalidate any resolved name.
                    prepared = nil
                    prepareError = nil
                }
            }
        }
    }

    // MARK: Fields

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .font(TaliseFont.mono(10, weight: .light))
            .kerning(1.3)
            .foregroundStyle(TaliseColor.fgDim)
    }

    private func errorLine(_ s: String) -> some View {
        Text(s)
            .font(TaliseFont.body(12, weight: .light))
            .foregroundStyle(TaliseColor.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bankPickerRow: some View {
        Button { showBankPicker = true } label: {
            HStack(spacing: 12) {
                if let bank = selectedBank {
                    BankAvatar(bankCode: bank.bankCode, bankName: bank.name, size: 34, cornerRadius: 9)
                }
                Text(selectedBank?.name ?? "Select bank")
                    .font(TaliseFont.body(15))
                    .foregroundStyle(selectedBank == nil ? TaliseColor.fgDim : TaliseColor.fg)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .fieldSurfaceBank()
        }
        .buttonStyle(.plain)
    }

    private var accountField: some View {
        TextField("", text: $accountNumber, prompt: Text("10-digit account number").foregroundColor(TaliseColor.fgDim))
            .keyboardType(.numberPad)
            .font(TaliseFont.body(15))
            .foregroundStyle(TaliseColor.fg)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .fieldSurfaceBank()
            .onChange(of: accountNumber) { _, new in
                let cleaned = String(new.filter { $0.isNumber }.prefix(10))
                if cleaned != new { accountNumber = cleaned }
                // Editing the number invalidates a prior resolve.
                if prepared != nil { prepared = nil }
                prepareError = nil
            }
    }

    /// Shows the resolved holder name as "✓ NAME" once `/link/prepare`
    /// returns, so the user can confirm it's the right account.
    @ViewBuilder private var resolvedNameLine: some View {
        if let p = prepared {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TaliseColor.accent)
                Text(p.accountName)
                    .font(TaliseFont.body(13, weight: .medium))
                    .foregroundStyle(TaliseColor.accent)
                    .lineLimit(1)
            }
            .padding(.leading, 2)
        }
    }

    // MARK: Primary action

    /// Before resolve → "Check account" (calls `/link/prepare`).
    /// After resolve → "Link account" (signs attestation + `/link/confirm`).
    @ViewBuilder private var primaryButton: some View {
        if prepared == nil {
            Button { Task { await prepare() } } label: {
                buttonBody(preparing ? "Checking…" : "Check account", busy: preparing)
            }
            .disabled(!canPrepare)
            .opacity(canPrepare ? 1 : 0.4)
        } else {
            Button { Task { await link() } } label: {
                buttonBody(linking ? "Linking…" : "Link account", busy: linking)
            }
            .disabled(linking)
            .opacity(linking ? 0.6 : 1)
        }
    }

    private func buttonBody(_ title: String, busy: Bool) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView().tint(TaliseColor.bg) }
            Text(title)
                .font(TaliseFont.heading(16, weight: .medium))
                .foregroundStyle(TaliseColor.bg)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(TaliseColor.fg)
        .clipShape(Capsule())
    }

    // MARK: Networking

    private func prepare() async {
        guard let bank = selectedBank else { return }
        preparing = true
        prepareError = nil
        linkError = nil
        defer { preparing = false }

        struct Body: Encodable { let bankCode: String; let accountNumber: String }
        do {
            let resp: BankLinkPrepareResp = try await APIClient.shared.post(
                "/api/me/bank/link/prepare",
                body: Body(bankCode: bank.bankCode, accountNumber: accountNumber)
            )
            prepared = resp
        } catch APIError.unauthorized {
            prepareError = "Sign in to link a bank account."
        } catch APIError.status(let code, let msg) {
            prepareError = friendlyError(code: code, message: msg)
        } catch {
            if APIError.isCancellation(error) { return }
            prepareError = "Couldn't verify that account. Check the number and bank."
        }
    }

    private func link() async {
        guard let p = prepared else { return }
        linking = true
        linkError = nil
        defer { linking = false }

        do {
            // Sign the attestation. The server returns EITHER sponsored
            // `bytes` (submit through the Onara pipeline → tx digest) OR an
            // `attestMessage` string (sign as a personal message → zkLogin
            // signature). Use whichever is present.
            let digest: String
            if let bytes = p.bytes, !bytes.isEmpty {
                let submission = try await ZkLoginCoordinator.shared.executeSponsorReady(
                    bytesB64: bytes, intent: "Link bank account"
                )
                digest = submission.digest
            } else if let message = p.attestMessage, !message.isEmpty {
                digest = try await ZkLoginCoordinator.shared.signPersonalMessage(message)
            } else {
                linkError = "Couldn't prepare the attestation. Please try again."
                return
            }

            struct ConfirmBody: Encodable {
                let bankCode: String
                let accountNumber: String
                let accountName: String
                let digest: String
            }
            let record: BankAccountDTO = try await APIClient.shared.post(
                "/api/me/bank/link/confirm",
                body: ConfirmBody(
                    bankCode: p.bankCode,
                    accountNumber: p.accountNumber,
                    accountName: p.accountName,
                    digest: digest
                )
            )
            onLinked(record)
            dismiss()
        } catch APIError.unauthorized {
            linkError = "Sign in to link a bank account."
        } catch APIError.status(let code, let msg) {
            linkError = friendlyError(code: code, message: msg)
        } catch {
            if APIError.isCancellation(error) { return }
            linkError = "Couldn't link that account right now. Please try again."
        }
    }

    /// Map config/rollout errors to reassuring copy; pass short real ones through.
    private func friendlyError(code: Int, message: String?) -> String {
        let lower = (message ?? "").lowercased()
        if code == 503 || lower.contains("not configured") {
            return "Bank linking is rolling out — check back soon."
        }
        if code == 422 {
            return "We couldn't verify that account. Check the number and bank."
        }
        if code == 409 {
            return "That account is already linked to your handle."
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

// MARK: - Searchable bank picker (self-contained copy)

/// Clean, searchable bank list presented as a sheet. Same pattern as the
/// Withdraw flow's picker (which is `private` to that file). Letter-avatar +
/// name + a checkmark on the selected one; tapping selects and dismisses.
private struct LinkBankPickerSheet: View {
    let banks: [LinkBank]
    let selected: LinkBank?
    let onSelect: (LinkBank) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [LinkBank] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return banks }
        return banks.filter { $0.name.lowercased().contains(q) }
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
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TaliseColor.fgMuted)
                TextField("", text: $query, prompt: Text("Search banks").foregroundColor(TaliseColor.fgDim))
                    .font(TaliseFont.body(15))
                    .foregroundStyle(TaliseColor.fg)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .fieldSurfaceBank()
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { bank in
                        Button {
                            onSelect(bank)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                BankAvatar(bankCode: bank.bankCode, bankName: bank.name, size: 36, cornerRadius: 10)
                                Text(bank.name)
                                    .font(TaliseFont.body(15))
                                    .foregroundStyle(TaliseColor.fg)
                                Spacer()
                                if bank.bankCode == selected?.bankCode {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(TaliseColor.accent)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
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

// MARK: - Flat field treatment

/// Flat input-field surface — solid `surface` plate + 1px `line` hairline +
/// continuous corners. Mirrors the Withdraw flow's `FieldSurface` (which is
/// file-private there) so this screen's fields read identically.
private struct BankFieldSurface: ViewModifier {
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
    func fieldSurfaceBank(cornerRadius: CGFloat = 16) -> some View {
        modifier(BankFieldSurface(cornerRadius: cornerRadius))
    }
}

// MARK: - Bank branding (logos + avatar)

/// Bank codes we ship a brand logo for (BankLogos asset catalog, from the
/// vendored Nigerian-Bank-Logos set). Everything else falls back to a letter.
enum BankBranding {
    static let logoCodes: Set<String> = [
        "011", "033", "035", "039", "044", "050", "057", "058",
        "070", "214", "215", "232", "301",
        // Fintechs / MFBs (raster brand marks)
        "100004", "100033", "090405", "090267", // OPay, PalmPay, Moniepoint, Kuda
    ]
    static func assetName(for bankCode: String) -> String? {
        logoCodes.contains(bankCode) ? "bank-\(bankCode)" : nil
    }
}

/// A bank's brand logo when we have one, else a letter-circle fallback.
/// Square rounded tile — used by every bank row (linked accounts, pickers,
/// withdraw, scan, send-to-bank) so they all look consistent.
struct BankAvatar: View {
    let bankCode: String
    let bankName: String
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 11

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if let asset = BankBranding.assetName(for: bankCode) {
                // Brand marks are designed for light backgrounds — set them on a
                // clean white tile (Apple-Wallet style) so they read on any surface.
                shape.fill(.white)
                    .overlay(
                        Image(asset)
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .padding(size * 0.16)
                    )
                    .overlay(shape.strokeBorder(TaliseColor.line, lineWidth: 1))
            } else {
                Text(String(bankName.prefix(1)).uppercased())
                    .font(TaliseFont.heading(size * 0.4, weight: .medium))
                    .foregroundStyle(TaliseColor.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(shape.fill(TaliseColor.accentSoft))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}
