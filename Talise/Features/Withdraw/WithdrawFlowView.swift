import SwiftUI
import WebKit
import Security

/// Top-level Withdraw flow. Replaces the old direct-to-Send sheet the
/// paper-plane button used to open. Now lands on a full-page options
/// screen with two paths:
///
///   - Withdraw to Bank → Nigerian bank transfer, wired to the live Linq
///     off-ramp (`/api/offramp/linq/{quote,create,status}`): quote →
///     slide-to-confirm (USDsui → Linq deposit wallet) → poll until completed.
///   - Onchain Send → existing multi-step `SendFlowView`, now hosted
///     as a pushed page inside this stack rather than a separate
///     fullScreenCover from MainTabView.
///
/// All sub-pages PUSH from this stack. The stack itself is presented
/// as a fullScreenCover from MainTabView — that initial bottom-up
/// slide is unavoidable, but everything beyond it slides in from the
/// trailing edge as the user asked.
struct WithdrawFlowView: View {
    var onClose: () -> Void

    @Environment(AppSession.self) private var session

    /// Which action group (if any) is expanded inline.
    private enum ActionGroup { case cheques, work }
    @State private var expanded: ActionGroup?
    @State private var showPrivateSoon = false

    /// Dismiss the cover, then post the target cover's notification with a
    /// 220ms delay so the dismiss settles before the next cover slides up.
    /// (We can't push these flows inside this stack — each runs its own
    /// NavigationStack and nesting breaks the multi-step paths.)
    private func handOff(_ name: Notification.Name) {
        onClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inlineHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // ── Primary actions: a clean 2×2 grid ──
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                            spacing: 14
                        ) {
                            // Cash-out to bank is server-gated (FEATURE_CASHOUT).
                            // Hidden until the flag opens it — fail-closed when
                            // `me` hasn't loaded.
                            if session.currentUser?.cashoutEnabled == true {
                                NavigationLink {
                                    UnifiedCashOutFlow()
                                } label: {
                                    ActionTile(icon: "hi.bank", title: "Cash out", caption: "To your bank")
                                }
                                .buttonStyle(TilePress())
                            }

                            Button { handOff(.taliseRequestSendCover) } label: {
                                ActionTile(icon: "hi.send", title: "Send", caption: "@handle or address")
                            }
                            .buttonStyle(TilePress())

                            Button { handOff(.taliseRequestCrossBorderCover) } label: {
                                ActionTile(icon: "hi.globe", title: "Send abroad", caption: "Paid in their currency")
                            }
                            .buttonStyle(TilePress())

                            // Private transactions — shielded USDsui (Talise's
                            // own ZK privacy layer). Opens the native
                            // PrivateSendFlowView (amount ≤ $10 → recipient →
                            // review → hidden in-app prover/relayer). The prover
                            // harness fails CLEANLY (SendFailureView) if the
                            // web prover route isn't reachable — never a crash,
                            // never a faked success, never moves funds.
                            Button { showPrivateSoon = true } label: {
                                ActionTile(icon: "hi.lock", title: "Send privately", caption: "Amount stays hidden")
                            }
                            .buttonStyle(TilePress())
                        }
                        .zIndex(3)

                        // ── Cheques group: full-width dropdown row (like Work) ──
                        Button {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                                expanded = expanded == .cheques ? nil : .cheques
                            }
                        } label: {
                            GroupRow(
                                icon: "hi.cheque",
                                title: "Cheques",
                                caption: "Write · Cash · My cheques",
                                isExpanded: expanded == .cheques
                            )
                        }
                        .buttonStyle(TilePress())
                        .zIndex(3)

                        if expanded == .cheques {
                            SubActionList(rows: [
                                .init(icon: "hi.write", title: "Write a cheque") {
                                    handOff(.taliseRequestChequeWriteCover)
                                },
                                .init(icon: "hi.cash", title: "Cash a cheque") {
                                    handOff(.taliseRequestChequeClaimCover)
                                },
                                .init(icon: "hi.list", title: "My cheques") {
                                    handOff(.taliseRequestMyChequesCover)
                                },
                            ])
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(1)
                        }

                        // ── Work group: streams, invoices, contracts ──
                        Button {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                                expanded = expanded == .work ? nil : .work
                            }
                        } label: {
                            GroupRow(
                                icon: "hi.briefcase",
                                title: "Work",
                                caption: "Streams · Invoices · Contracts",
                                isExpanded: expanded == .work
                            )
                        }
                        .buttonStyle(TilePress())
                        .zIndex(2)

                        if expanded == .work {
                            SubActionList(rows: [
                                .init(icon: "hi.stream", title: "Stream a payment") {
                                    handOff(.taliseRequestStreamCover)
                                },
                                .init(icon: "hi.list", title: "My streams") {
                                    handOff(.taliseRequestMyStreamsCover)
                                },
                                .init(icon: "hi.invoice", title: "Invoices") {
                                    handOff(.taliseRequestInvoicesCover)
                                },
                                .init(icon: "hi.contract", title: "Contracts") {
                                    handOff(.taliseRequestContractsCover)
                                },
                            ])
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(0)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 32)
                }
            }
            .background(TaliseColor.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $showPrivateSoon) {
                ShieldedBalanceView(onDone: { showPrivateSoon = false })
            }
        }
        .tint(TaliseColor.fg)
    }

    /// Custom inline header instead of the system large title. Lets us
    /// use the app's Talise sans font, lighter weight, smaller size.
    private var inlineHeader: some View {
        HStack(alignment: .center) {
            Text("Move money")
                .font(TaliseFont.heading(26, weight: .medium))
                .kerning(-0.6)
                .foregroundStyle(TaliseColor.fg)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(TaliseColor.surface2))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

// MARK: - Unified cash-out
//
// ONE country picker for cashing out; the settlement rail is chosen by the
// corridor, not the user: Nigeria settles via Linq (NGN), US/Europe via Bridge
// (USD/EUR). Lives here (not the Ramps module) because the Linq
// `BankWithdrawView` is file-private to this flow.

private struct UnifiedCashOutFlow: View {
    @Environment(AppSession.self) private var session
    @State private var selected: RampCorridor?
    var body: some View {
        CorridorPickerView(direction: .offramp, userCountry: session.currentUser?.country) {
            selected = $0
        }
            .navigationDestination(item: $selected) { corridor in
                switch corridor.availability {
                case .local:
                    BankWithdrawView()                  // Nigeria → Linq (NGN)
                case .bridge, .soon:
                    BridgeCashOutView(corridor: corridor) // US / Europe → Bridge
                }
            }
    }
}

// MARK: - Action tiles + groups
//
// CashApp-grammar: generous tiles, one squircle icon chip in a SUBTLE brand
// green per action, confident type, soft hairline ring — no badge pills, no
// loud filled discs. Icons are the Hugeicons set (Assets.xcassets/HugeIcons,
// template-rendered SVGs extracted from the same @hugeicons set the web app
// uses), so web + iOS finally share one icon language.

/// Hugeicon image, template-tinted.
/// INTERNAL (not private): shared with DepositFlowView so the Deposit and
/// Move-money sheets speak the same visual language. Lives here (not in
/// DesignSystem/) only because this pbxproj predates synchronized groups —
/// adding a file means hand-editing project.pbxproj.
struct HugeIcon: View {
    let name: String
    var size: CGFloat = 20
    var tint: Color = TaliseColor.greenMint

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(tint)
    }
}

/// The squircle icon chip — soft mint wash, mint glyph. INTERNAL: shared
/// with DepositFlowView (see HugeIcon note).
struct IconChip: View {
    let icon: String
    var side: CGFloat = 42
    var iconSize: CGFloat = 20
    /// Glyph + wash colour — mint by default; pass fgMuted for dimmed
    /// not-yet-live rows.
    var tint: Color = TaliseColor.greenMint

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
            .fill(tint.opacity(0.12))
            .frame(width: side, height: side)
            .overlay(HugeIcon(name: icon, size: iconSize, tint: tint))
    }
}

/// Press feedback for the big tiles — a gentle scale, CashApp-style.
/// INTERNAL: shared with DepositFlowView (see HugeIcon note).
struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// One square-ish primary tile in the 2×2 grid.
private struct ActionTile: View {
    let icon: String
    let title: String
    let caption: String
    var expandable = false
    var isExpanded = false
    /// Locked = a not-yet-available feature: dimmed, non-interactive, with a
    /// small "Coming soon" pill instead of the chevron.
    var locked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                IconChip(icon: icon)
                Spacer()
                if locked {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                        Text("SOON").font(TaliseFont.mono(8, weight: .regular)).tracking(1)
                    }
                    .foregroundStyle(TaliseColor.fgDim)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(TaliseColor.surface2))
                    .padding(.top, 2)
                } else if expandable {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TaliseColor.fgDim)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 16)
            Text(title)
                .font(TaliseFont.heading(16, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(locked ? TaliseColor.fgMuted : TaliseColor.fg)
            Text(caption)
                .font(TaliseFont.body(12.5, weight: .light))
                .foregroundStyle(TaliseColor.fgDim)
                .lineLimit(1)
                .padding(.top, 3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 132)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .opacity(locked ? 0.5 : 1)
        .saturation(locked ? 0.4 : 1)
    }
}

/// Slim full-width group header row (Work).
private struct GroupRow: View {
    let icon: String
    let title: String
    let caption: String
    var isExpanded = false

    var body: some View {
        HStack(spacing: 14) {
            IconChip(icon: icon)
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(TaliseFont.heading(16, weight: .semibold))
                    .kerning(-0.3)
                    .foregroundStyle(TaliseColor.fg)
                Text(caption)
                    .font(TaliseFont.body(12.5, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TaliseColor.fgDim)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// The expanded rows of a group — one rounded container, hairline dividers.
private struct SubActionList: View {
    struct Row: Identifiable {
        let icon: String
        let title: String
        let action: () -> Void
        var id: String { title }
    }
    let rows: [Row]

    /// Per-row reveal stagger: rows fade + settle in 45ms apart once the
    /// container lands, so the expand reads as a composed motion rather
    /// than a block popping in.
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                Button(action: row.action) {
                    HStack(spacing: 14) {
                        IconChip(icon: row.icon, side: 34, iconSize: 16)
                        Text(row.title)
                            .font(TaliseFont.body(15, weight: .regular))
                            .foregroundStyle(TaliseColor.fg)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TaliseColor.fgDim)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : -7)
                .animation(
                    .spring(response: 0.34, dampingFraction: 0.86)
                        .delay(0.04 + Double(i) * 0.045),
                    value: revealed
                )
                if i < rows.count - 1 {
                    Divider().overlay(TaliseColor.fg.opacity(0.06)).padding(.leading, 66)
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(TaliseColor.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
        )
        .onAppear { revealed = true }
        .onDisappear { revealed = false }
    }
}

// MARK: - Linq off-ramp DTOs

/// `POST /api/offramp/linq/quote` response. Resolves the destination
/// account name and the live NGN you'll receive for `amountUsdsui`.
private struct LinqQuoteResp: Decodable {
    let accountName: String
    let bankName: String
    let bankCode: String
    let accountNumber: String
    let rate: Double
    let amountUsdsui: Double
    let amountNgn: Double
}
/// `POST /api/offramp/linq/create` response. `walletAddress` is the Sui
/// address the user must send exactly `amountUsdsui` USDSUI to; the order
/// is then settled by Linq and tracked via `orderId`.
private struct LinqCreateResp: Decodable {
    let orderId: String
    let linqOrderId: String
    let walletAddress: String
    let coinType: String
    let amountUsdsui: Double
    let amountNgn: Double
    let rate: Double
    let depositWindowMinutes: Int
}
/// `GET /api/offramp/linq/status/[orderId]` — current state of the order.
private struct LinqStatusResp: Decodable {
    let orderId: String
    let status: String
    let phase: String             // initiated | processing | completed | failed
    let amountUsdsui: Double
    let amountNgn: Double
}

/// `POST /api/offramp/linq/resolve` response. Amount-independent name
/// enquiry — detects the account holder so the user never types it.
private struct LinqResolveResp: Decodable {
    let accountName: String
    let bankName: String
    let bankCode: String
    let accountNumber: String
}
/// `GET /api/offramp/linq/rate` — public display rate for the live estimate.
private struct LinqRateResp: Decodable {
    let rate: Double
}

/// One bank option for the picker. `name` is what we show; `bankCode` is
/// the plain NIBSS code Linq accepts directly (no UUID resolution).
private struct OfframpBank: Identifiable, Hashable {
    let name: String
    let bankCode: String
    var id: String { bankCode }
}

/// Nigerian bank transfer — wired to the live Linq off-ramp.
///
/// Flow: enter USDsui amount + account + bank → QUOTE (name-check + rate) →
/// slide to confirm (creates a Linq order, then signs a USDsui transfer to
/// the Linq deposit wallet) → POLL status until completed/failed.
private struct BankWithdrawView: View {
    /// Session-expiry path: an unrecoverable zkLogin session routes to a
    /// clean sign-out → re-auth (mirrors Send) instead of a dead-end error.
    @Environment(AppSession.self) private var session
    @State private var accountNumber: String = ""
    @State private var selectedBank: OfframpBank? = nil
    @State private var amount: String = ""

    @State private var step: Step = .form
    @State private var quote: LinqQuoteResp?
    @State private var quoting = false
    @State private var confirming = false
    @State private var statusText: String = ""
    @State private var finalStatus: String?      // completed | failed
    @State private var error: String?

    // Inline account-name resolution. The user never types their own name —
    // we name-enquire the (bank, account) pair and detect the holder.
    @State private var resolvedName: String?
    @State private var resolving = false
    @State private var resolveError: String?
    @State private var resolveTask: Task<Void, Never>?

    // Live display rate (1 USDsui = `rate` NGN) for the "≈ ₦X" estimate.
    @State private var displayRate: Double?

    // Searchable bank-picker sheet.
    @State private var showBankPicker = false

    private enum Step { case form, review, sending, done }

    /// Common Nigerian banks, name + plain NIBSS code (Linq codes).
    private let banks: [OfframpBank] = [
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
        .init(name: "Kuda",                     bankCode: "090267"),
        .init(name: "OPay",                     bankCode: "100004"),
        .init(name: "PalmPay",                  bankCode: "100033"),
        .init(name: "Moniepoint",               bankCode: "090405"),
    ]

    /// Whether the user's display currency is NGN. When true the amount
    /// field is denominated in Naira (the exact NGN they want credited) and
    /// the backend debits the precise USDsui from Linq's locked rate; when
    /// false (USD or any other display currency) the field stays in USDsui.
    /// Branch on this everywhere rather than hardcoding NGN.
    private var isNgnInput: Bool { CurrencySettings.shared.current.code == "NGN" }

    /// Raw numeric value the user typed (NGN when `isNgnInput`, else USDsui).
    private var amountValue: Double { Double(amount) ?? 0 }

    /// The USDsui amount this input *implies* — only meaningful for the
    /// USD path or for gating "can continue". For the NGN path the exact
    /// debit comes from the server quote/create, never this estimate.
    private var usdsuiAmount: Double { Double(amount) ?? 0 }

    /// The account must be NAME-RESOLVED before we'll let the user move on —
    /// a wrong/unverifiable account can't proceed.
    private var canContinue: Bool {
        amountValue > 0
            && selectedBank != nil
            && accountNumber.count == 10
            && resolvedName != nil
            && resolveError == nil
            && !resolving
    }

    var body: some View {
        Group {
            switch step {
            case .form: formView
            case .review: reviewView
            case .sending, .done: statusView
            }
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .navigationTitle("Withdraw to Bank")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TaliseColor.bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showBankPicker) {
            BankPickerSheet(banks: banks, selected: selectedBank) { bank in
                selectedBank = bank
                scheduleResolve()
            }
        }
        .task { await loadRate() }
        .onChange(of: accountNumber) { _, _ in scheduleResolve() }
    }

    // MARK: Form

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(isNgnInput ? "Amount in Naira" : "Amount in USDsui")
                    amountField
                    estimateLine
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Bank")
                    bankPickerRow
                }

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Receiver's account")
                    accountField
                    resolvedNameLine
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

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .font(TaliseFont.mono(10, weight: .light))
            .kerning(1.3)
            .foregroundStyle(TaliseColor.fgDim)
    }

    private var amountField: some View {
        HStack(spacing: 8) {
            Text(isNgnInput ? "₦" : "$")
                .font(TaliseFont.heading(20, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            TextField("", text: $amount, prompt: Text("0").foregroundColor(TaliseColor.fgDim))
                .keyboardType(.decimalPad)
                .font(TaliseFont.heading(20, weight: .medium))
                .foregroundStyle(TaliseColor.fg)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .fieldSurface()
    }

    /// Live estimate under the amount. Display-only — the locked figures
    /// still come from the quote at review.
    ///   - NGN input → "≈ {ngn / rate} USDsui" (what will be debited).
    ///   - USD input → "≈ ₦{usdsui × rate}" (what the recipient receives).
    @ViewBuilder private var estimateLine: some View {
        if let rate = displayRate, rate > 0, amountValue > 0 {
            Text(isNgnInput
                 ? "≈ \(TaliseFormat.usd2(amountValue / rate)) USDsui"
                 : "≈ ₦\(ngnGrouped(amountValue * rate))")
                .font(TaliseFont.mono(12, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .padding(.leading, 2)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.18), value: amountValue)
        }
    }

    private var accountField: some View {
        TextField("", text: $accountNumber, prompt: Text("10-digit account number").foregroundColor(TaliseColor.fgDim))
            .keyboardType(.numberPad)
            .font(TaliseFont.body(15))
            .foregroundStyle(TaliseColor.fg)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .fieldSurface()
            .onChange(of: accountNumber) { _, new in
                let cleaned = new.filter { $0.isNumber }
                let trimmed = String(cleaned.prefix(10))
                if trimmed != new { accountNumber = trimmed }
            }
    }

    /// Inline detected-name feedback under the account field: resolving →
    /// success (green check + holder name) → failure (red line).
    @ViewBuilder private var resolvedNameLine: some View {
        if resolving {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini).tint(TaliseColor.fgMuted)
                Text("Checking account…")
                    .font(TaliseFont.body(12, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
            .padding(.leading, 2)
        } else if let name = resolvedName {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TaliseColor.accent)
                Text(name)
                    .font(TaliseFont.body(13, weight: .medium))
                    .foregroundStyle(TaliseColor.accent)
                    .lineLimit(1)
            }
            .padding(.leading, 2)
        } else if let resolveError {
            Text(resolveError)
                .font(TaliseFont.body(12, weight: .light))
                .foregroundStyle(TaliseColor.danger)
                .lineLimit(2)
                .padding(.leading, 2)
        }
    }

    /// Tappable row that opens the searchable bank-picker sheet.
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
            .fieldSurface()
        }
        .buttonStyle(.plain)
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
            .background(canContinue && !quoting ? TaliseColor.fg : TaliseColor.fg.opacity(0.35))
            .clipShape(Capsule())
        }
        .disabled(!canContinue || quoting)
    }

    // MARK: Review (quote)

    @ViewBuilder private var reviewView: some View {
        if let q = quote {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Review withdrawal")
                            .font(TaliseFont.heading(24, weight: .medium))
                            .kerning(-0.5)
                            .foregroundStyle(TaliseColor.fg)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)

                        // Summary card — headline receive amount, then details.
                        VStack(spacing: 0) {
                            VStack(spacing: 6) {
                                Eyebrow(text: "You receive")
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

                            VStack(spacing: 0) {
                                reviewRow("To", q.accountName)
                                divider
                                reviewRow("Bank", q.bankName.isEmpty ? (selectedBank?.name ?? "—") : q.bankName)
                                divider
                                reviewRow("Account", maskAccount(accountNumber))
                                divider
                                reviewRow("You send", "\(TaliseFormat.usd2(q.amountUsdsui)) USDsui")
                                divider
                                reviewRow("Rate", "$1 = ₦\(ngnGrouped(q.rate))")
                            }
                            .padding(.horizontal, 16)
                        }
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
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }

                VStack(spacing: 12) {
                    SlideToConfirm(title: "Slide to withdraw", tint: TaliseColor.greenMint) {
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
                        Button(action: { dismiss() }) {
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
            // Clean comet-tail ring in the brand mint — no grey backdrop.
            TaliseLoadingRing(size: 64, lineWidth: 3.5)
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

    /// True once Linq confirms the payout landed; false while it's in flight
    /// (poll timed out) — drives "Paid out" vs "On its way" copy + icon.
    @State private var paidOut = false

    private var statusHeadline: String {
        if step == .sending { return "Paying your bank…" }
        if finalStatus == "failed" { return "Withdrawal failed" }
        return paidOut ? "Paid out" : "On its way"
    }

    @Environment(\.dismiss) private var dismiss

    // MARK: Networking

    /// Load the public display rate for the live "≈ ₦X" estimate. Silent —
    /// the estimate just doesn't render if it's unavailable.
    private func loadRate() async {
        guard displayRate == nil else { return }
        do {
            let r: LinqRateResp = try await APIClient.shared.get("/api/offramp/linq/rate")
            displayRate = r.rate
        } catch { /* display-only — ignore */ }
    }

    /// Debounce (~0.4s) then resolve the account name whenever the bank or
    /// account number changes. Cancels any in-flight resolve first so only
    /// the latest (bank, account) pair is name-enquired.
    private func scheduleResolve() {
        resolveTask?.cancel()
        // Clear stale state immediately so a changed field never shows a
        // name that belongs to the previous input.
        resolvedName = nil
        resolveError = nil

        guard let bank = selectedBank, accountNumber.count == 10 else {
            resolving = false
            return
        }

        resolving = true
        let bankCode = bank.bankCode
        let account = accountNumber
        resolveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await resolveAccount(bankCode: bankCode, accountNumber: account)
        }
    }

    private func resolveAccount(bankCode: String, accountNumber: String) async {
        struct Body: Encodable { let bankCode: String; let accountNumber: String }
        do {
            let r: LinqResolveResp = try await APIClient.shared.post(
                "/api/offramp/linq/resolve",
                body: Body(bankCode: bankCode, accountNumber: accountNumber)
            )
            // Guard against a late response landing after the user edited the
            // field again (state moved on while we were in flight).
            guard !Task.isCancelled,
                  self.accountNumber == accountNumber,
                  self.selectedBank?.bankCode == bankCode else { return }
            resolvedName = r.accountName
            resolveError = nil
            resolving = false
        } catch APIError.unauthorized {
            guard self.accountNumber == accountNumber,
                  self.selectedBank?.bankCode == bankCode else { return }
            resolveError = "Sign in to continue."
            resolvedName = nil
            resolving = false
        } catch APIError.status(let code, let msg) {
            guard !Task.isCancelled,
                  self.accountNumber == accountNumber,
                  self.selectedBank?.bankCode == bankCode else { return }
            resolveError = code == 422
                ? "We couldn't verify that account. Check the number and bank."
                : friendlyOfframpError(code: code, message: msg)
            resolvedName = nil
            resolving = false
        } catch {
            if APIError.isCancellation(error) { return }
            guard self.accountNumber == accountNumber,
                  self.selectedBank?.bankCode == bankCode else { return }
            resolveError = "Couldn't check that account right now."
            resolvedName = nil
            resolving = false
        }
    }

    private func getQuote() async {
        guard canContinue, let bank = selectedBank else { return }
        quoting = true; error = nil
        defer { quoting = false }
        // The backend accepts either amountNgn (NGN display currency — debits
        // the exact USDsui from Linq's locked rate) or amountUsdsui (USD/other
        // display currencies). Send whichever the user entered; leave the
        // other nil so it's omitted from the JSON body.
        struct Body: Encodable {
            let amountNgn: Double?
            let amountUsdsui: Double?
            let bankCode: String
            let accountNumber: String
        }
        do {
            let q: LinqQuoteResp = try await APIClient.shared.post(
                "/api/offramp/linq/quote",
                body: Body(
                    amountNgn: isNgnInput ? amountValue : nil,
                    amountUsdsui: isNgnInput ? nil : amountValue,
                    bankCode: bank.bankCode,
                    accountNumber: accountNumber
                )
            )
            quote = q
            withAnimation { step = .review }
        } catch APIError.status(let code, let msg) {
            error = friendlyOfframpError(code: code, message: msg)
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't get a quote right now."
        }
    }

    private func confirm() async {
        guard let q = quote, let bank = selectedBank else { return }
        confirming = true; error = nil
        defer { confirming = false }
        do {
            // 1. Create the Linq order — returns the deposit wallet to fund.
            //    For NGN we send amountNgn (the exact credit) and trust the
            //    response's amountUsdsui as the EXACT amount to debit; for
            //    USD/other we send the quoted amountUsdsui. Send only the
            //    field that matches the input so the other is omitted.
            struct CreateBody: Encodable {
                let amountNgn: Double?
                let amountUsdsui: Double?
                let bankCode: String
                let accountNumber: String
                let accountName: String
                let bankName: String?
            }
            let order: LinqCreateResp = try await APIClient.shared.post(
                "/api/offramp/linq/create",
                body: CreateBody(
                    amountNgn: isNgnInput ? q.amountNgn : nil,
                    amountUsdsui: isNgnInput ? nil : q.amountUsdsui,
                    bankCode: bank.bankCode,
                    accountNumber: accountNumber,
                    accountName: q.accountName,
                    bankName: q.bankName.isEmpty ? bank.name : q.bankName
                )
            )

            // 2. Send exactly the quoted USDsui to Linq's deposit wallet
            //    (sponsored/gasless — same rail as a normal send).
            // sponsorFallback: a cash-out is fee-free to the user ("No network
            // fee — sponsored by Talise" on the review screen). Try the
            // gasless rail first (free for Talise when the user's USDsui is in
            // the accumulator); if it can't build (funds in Coin objects — the
            // common case, and the cause of the prior "Couldn't complete the
            // withdrawal" error) the server sponsors it so the cash-out still
            // lands.
            let sent = try await ZkLoginCoordinator.shared.signAndSubmitSend(
                to: order.walletAddress, amountUsd: order.amountUsdsui,
                intent: "Bank withdrawal", sponsorFallback: true
            )
            NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                digest: sent.digest, direction: "sent", amountUsdsui: order.amountUsdsui,
                counterparty: order.walletAddress, counterpartyName: "Bank withdrawal", venue: nil))

            // "Sending ₦100 to EROMONSELE ODIGIE…" — amount AND the resolved
            // account holder (the old string put the amount after "to", which
            // read as "sending the money to 100"). Falls back to "your bank"
            // if the name-enquiry didn't resolve.
            let payee = quote?.accountName ?? resolvedName ?? "your bank"
            statusText = order.amountNgn > 0
                ? "Sending ₦\(ngnGrouped(order.amountNgn)) to \(payee)…"
                : "Sending the money to \(payee)…"
            withAnimation { step = .sending }
            await pollStatus(order.orderId)
        } catch APIError.status(let code, let msg) {
            error = friendlyOfframpError(code: code, message: msg)
        } catch APIError.unauthorized {
            error = "Please sign in again."
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            error = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = APIError.honestMoneyError(
                error, fallback: "Couldn't complete the withdrawal right now.")
        }
    }

    /// Poll the Linq order until it completes or fails. We wait a GENEROUS
    /// window (~3 min): bank payouts can lag a couple of minutes, so we hold to
    /// CONFIRM success (green "Paid out") rather than giving up early. The
    /// server maps a transient "timeout" to still-processing, so only a real
    /// failed/reject ends this red; otherwise we finish on the reassuring
    /// "On its way" (the payout completes server-side and shows in activity).
    private func pollStatus(_ id: String) async {
        for i in 0..<45 {
            do {
                let s: LinqStatusResp = try await APIClient.shared.get("/api/offramp/linq/status/\(id)")
                switch s.phase {
                case "completed":
                    finalStatus = "completed"
                    paidOut = true
                    statusText = "₦\(ngnGrouped(s.amountNgn)) has landed in the bank account."
                    withAnimation { step = .done }
                    return
                case "failed":
                    finalStatus = "failed"
                    statusText = "The payout couldn't be completed — your USDsui has been returned."
                    withAnimation { step = .done }
                    return
                default:
                    break   // initiated / processing — keep polling
                }
            } catch {
                if APIError.isCancellation(error) { return }
            }
            // Poll a little quicker early (catch fast completions), then ease
            // off to stay well under the status route's 60/min rate limit.
            try? await Task.sleep(nanoseconds: UInt64(i < 10 ? 3 : 5) * 1_000_000_000)
        }
        // Still in flight after the window — NOT a failure. Reassuring
        // "On its way" (green clock); paidOut stays false.
        finalStatus = "completed"
        paidOut = false
        statusText = "Your transfer is on its way. It can take a few minutes to land in the bank account."
        withAnimation { step = .done }
    }

    private func maskAccount(_ a: String) -> String {
        a.count <= 4 ? "****" : "****\(a.suffix(4))"
    }

    /// Grouped NGN figure (no currency symbol — we prefix ₦ at the call site).
    private func ngnGrouped(_ v: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = Locale(identifier: "en_US")
        fmt.minimumFractionDigits = 0
        fmt.maximumFractionDigits = v < 100 ? 2 : 0
        return fmt.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v)
    }

    /// Map rollout / config errors to reassuring copy; pass real ones through.
    private func friendlyOfframpError(code: Int, message: String?) -> String {
        let lower = (message ?? "").lowercased()
        if code == 503 || lower.contains("not configured") || lower.contains("fx_unavailable") {
            return "Bank withdrawals are rolling out — check back soon."
        }
        if code == 422 && lower.contains("verify") {
            return "We couldn't verify that bank account. Check the number and bank."
        }
        if lower.contains("\"error\"") {
            // Body is JSON like {"error":"…"} — pull the message out.
            if let data = message?.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = obj["error"] as? String, !e.isEmpty {
                return e
            }
        }
        if code == 404 { return "Bank withdrawals aren't available yet." }
        // Only surface a server message if it's short and not an HTML error
        // page — never dump a raw body/stack into the UI.
        if let msg = message, !msg.isEmpty, msg.count <= 120,
           !lower.contains("<html"), !lower.contains("<!doctype") {
            return msg
        }
        return "Something went wrong. Please try again."
    }
}

// MARK: - Searchable bank picker

/// Clean, searchable bank list presented as a sheet. Each row = a
/// letter-avatar (the bank's first initial in a rounded square,
/// `accentSoft` bg / `accent` text) + the bank name, with a checkmark on
/// the selected one. Tapping a row selects it and dismisses.
private struct BankPickerSheet: View {
    let banks: [OfframpBank]
    let selected: OfframpBank?
    let onSelect: (OfframpBank) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [OfframpBank] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return banks }
        return banks.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Grabber + title.
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

            // Search field.
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
            .fieldSurface()
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

/// Flat input-field surface for the bank-form fields: a solid
/// `TaliseColor.surface` plate with a 1px `TaliseColor.line` hairline and
/// continuous corners — no material, no blur, no gradient. Keeps every
/// field visually identical without repeating the recipe at each call site.
private struct FieldSurface: ViewModifier {
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
    func fieldSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(FieldSurface(cornerRadius: cornerRadius))
    }
}

/// Clean, brand-mint loading ring — a comet-tail arc that fades from
/// transparent into solid mint and spins smoothly. No grey backdrop, no
/// system `ProgressView` dashes. Reusable across money flows.
struct TaliseLoadingRing: View {
    var size: CGFloat = 64
    var lineWidth: CGFloat = 3.5
    /// Active arc colour — defaults to the mint accent that reads on dark.
    var color: Color = TaliseColor.greenMint

    @State private var spinning = false

    var body: some View {
        ZStack {
            // Faint full-circle track — adapts to the surface (light on dark,
            // dark on light) without any filled grey disc behind it.
            Circle()
                .stroke(TaliseColor.fg.opacity(0.08), lineWidth: lineWidth)

            // Comet-tail arc: angular gradient from clear → solid mint so the
            // leading edge is crisp and the tail dissolves.
            Circle()
                .trim(from: 0, to: 0.92)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [color.opacity(0), color]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

// MARK: - Private transactions (coming soon)

/// NATIVE shielded-send flow. Mirrors the normal Send flow's simple UI (amount
/// keypad → recipient → review → result) by reusing its screens, so "Send
/// private tx" feels exactly like a regular send — no web page. The only
/// difference is `confirm()`: instead of a normal transfer it runs a SHIELDED
/// send (deposit into the pool, then withdraw to the recipient — which severs
/// the on-chain sender↔recipient link). The Groth16 proof is built client-side
/// in a HIDDEN, never-shown in-app web layer (privacy holds — the relayer only
/// relays, never sees note secrets). $10/tx pilot cap is enforced on-chain.
struct PrivateSendFlowView: View {
    var onDone: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    @State private var path: [SendStep] = []
    @State private var draft = SendDraft(currency: CurrencySettings.shared.current)
    @StateObject private var prover = ShieldProverController()

    var body: some View {
        NavigationStack(path: $path) {
            PrivateAmountView(
                draft: draft,
                onNext: { path.append(.recipient) },
                onCancel: { close() },
                onRecover: { Task { await recover() } }
            )
            .navigationDestination(for: SendStep.self) { step in
                switch step {
                case .amount:
                    Color.clear.onAppear { path.removeAll() }
                case .recipient:
                    SendRecipientView(
                        draft: draft,
                        onNext: { path.append(.review) },
                        onBack: { pop() },
                        onClose: { close() },
                        allowBankPayout: false // shielded flow: never the public NGN off-ramp
                    )
                case .review:
                    PrivateReviewView(
                        draft: draft,
                        onConfirm: { await confirm() },
                        onBack: { pop() }
                    )
                case .sending:
                    // Surface the prover's live stage (Sealing your transfer…,
                    // Confirm on your device…, …). `prover` is observed, so each
                    // progress message re-renders this screen with the new stage.
                    SendInProgressView(draft: draft, progress: prover.status, onDone: { close() })
                        .navigationBarBackButtonHidden(true)
                case .complete:
                    SendCompleteView(draft: draft, onDone: { close() })
                        .navigationBarBackButtonHidden(true)
                case .failure:
                    SendFailureView(
                        draft: draft,
                        onTryAgain: { draft.errorMessage = nil; path = [] },
                        onDone: { close() }
                    )
                    .navigationBarBackButtonHidden(true)
                }
            }
        }
        .tint(TaliseColor.fg)
        // The prover web layer is mounted 0×0 and hidden — the user only ever
        // sees the native screens above. It exists solely to build the proof.
        .background(
            ShieldProverHost(controller: prover)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        // Pre-warm the two slow prerequisites WHILE the user is still typing the
        // amount / picking a recipient, so confirm() is fast:
        //  • the zkLogin proof — so the deposit-sign leg sends a `cachedProof`
        //    and the server SKIPS re-proving (a cold proof costs several seconds);
        //  • the shield note master — so confirm() reads it from the Keychain
        //    instead of blocking on the escrow round-trip on first use.
        // Both run concurrently with the prover web layer loading above.
        .task {
            async let warm: Void = ZkLoginCoordinator.shared.ensureProofWarm()
            async let seed: String = ShieldKeyStore.noteMasterHex()
            _ = await (warm, seed)
        }
    }

    /// One-tap recovery: sweep all unspent shielded notes back to the user's own
    /// wallet. Reclaims a balance stranded by earlier failed withdraws.
    private func recover() async {
        guard let addr = session.currentUser?.suiAddress, !addr.isEmpty else {
            draft.errorMessage = "Couldn’t read your wallet address."
            path = [.failure]
            return
        }
        draft.errorMessage = nil
        path.append(.sending)
        do {
            let seedHex = await ShieldKeyStore.noteMasterHex()
            let digest = try await prover.recover(seedHex: seedHex, destination: addr)
            draft.success = SendSuccess(
                digest: digest,
                displayAmount: "Recovered",
                currency: draft.currency,
                usdsui: 0,
                recipientAddress: addr,
                recipientDisplay: "your wallet"
            )
            path = [.complete]
        } catch {
            draft.errorMessage = error.localizedDescription
            path = [.failure]
        }
    }

    private func confirm() async {
        guard let resolved = draft.resolved, draft.amountUsdsui > 0 else { return }
        draft.errorMessage = nil
        path.append(.sending)
        let micros = UInt64((draft.amountUsdsui * 1_000_000).rounded())
        let recipientDisplay = resolved.displayName ?? resolved.display ?? String(resolved.address.prefix(10))
        do {
            // Load (or first-time create + escrow) the user's note master, then
            // hand it to the in-page prover for client-side key derivation.
            let seedHex = await ShieldKeyStore.noteMasterHex()
            // If the recipient published a shield identity, pass it so the send
            // can be a HIDDEN-AMOUNT shielded transfer (else falls back to public).
            var shieldJson: String?
            if let sid = resolved.shieldIdentity,
               let data = try? JSONEncoder().encode(sid) {
                shieldJson = String(data: data, encoding: .utf8)
            }
            let digest = try await prover.send(micros: micros, recipient: resolved.address, seedHex: seedHex, recipientShieldJson: shieldJson)
            draft.success = SendSuccess(
                digest: digest,
                displayAmount: draft.rawAmount,
                currency: draft.currency,
                usdsui: draft.amountUsdsui,
                recipientAddress: resolved.address,
                recipientDisplay: recipientDisplay
            )
            path = [.complete]
        } catch {
            draft.errorMessage = error.localizedDescription
            path = [.failure]
        }
    }

    private func pop() { if !path.isEmpty { path.removeLast() } }
    private func close() { onDone?(); dismiss() }
}

/// Drives the shielded send. Owns a hidden `WKWebView` that loads the
/// authenticated `/shield-prove` harness (via the bearer→web-session bridge);
/// the native flow calls `send(micros:recipient:)`, the harness runs the
/// deposit→withdraw legs (Groth16 proof built in-page, client-side), and posts
/// progress + the final digest back over a script-message handler.
@MainActor
final class ShieldProverController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    @Published var status: String = ""
    private var continuation: CheckedContinuation<String, Error>?

    // ── Timing instrumentation ────────────────────────────────────────────
    // Parity with the gasless/sponsored `[ios/send] … total=Nms` log: prints,
    // to the Xcode console, exactly how long a private tx takes and WHERE the
    // time goes — web prover ready, each in-page stage (Δ between progress
    // messages), the native deposit-sign leg, and the total. All times are
    // wall-clock ms via the monotonic CFAbsoluteTime clock.
    private let tInit = CFAbsoluteTimeGetCurrent()
    private var tStart: CFAbsoluteTime = 0   // start of the current op
    private var tPrev: CFAbsoluteTime = 0    // previous stage boundary (for Δ)
    private var signMs = 0                   // native deposit-sign leg
    private var opLabel = ""

    private func ms(_ from: CFAbsoluteTime) -> Int {
        Int(((CFAbsoluteTimeGetCurrent() - from) * 1000.0).rounded())
    }
    private func beginTiming(_ label: String) {
        opLabel = label
        tStart = CFAbsoluteTimeGetCurrent()
        tPrev = tStart
        signMs = 0
        print("[ios/private] start op=\(label)")
    }

    enum ShieldError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    override init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "shield")
        webView.navigationDelegate = self
        if let url = URL(string: AppConfig.shared.apiBaseURL + "/api/auth/web-session?next=/shield-prove") {
            var req = URLRequest(url: url)
            if let bearer = SecureSessionStore.shared.read() {
                req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
            }
            webView.load(req)
        }
    }

    /// Run a shielded send. `micros` = USDsui base units; `recipient` = 0x addr;
    /// `seedHex` = the user's note master; `recipientShieldJson` = the recipient's
    /// published shield identity as JSON `{pubkey, encPubkeyHex}` (or nil → public
    /// withdraw). When present + the sender holds a covering note, the send becomes
    /// a hidden-amount shielded transfer.
    func send(micros: UInt64, recipient: String, seedHex: String, recipientShieldJson: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            self.beginTiming("send")
            let safeRecipient = recipient.replacingOccurrences(of: "'", with: "")
            let safeSeed = seedHex.replacingOccurrences(of: "'", with: "")
            // JSON-encode the shield identity safely for JS injection (it contains
            // only [0-9a-fx] but encode defensively); empty → undefined.
            let shieldArg: String = {
                guard let j = recipientShieldJson, !j.isEmpty,
                      let data = try? JSONSerialization.data(withJSONObject: [j]),
                      let arr = String(data: data, encoding: .utf8) else { return "undefined" }
                return String(arr.dropFirst().dropLast()) // the quoted JS string literal
            }()
            // Throw (not silently no-op) if the harness hasn't installed yet, so a
            // missing function surfaces as a clean failure instead of a hang.
            let js = "if(!window.taliseShieldSend){throw new Error('Private send isn’t ready yet — try again.')}; window.taliseShieldSend('\(micros)','\(safeRecipient)','\(safeSeed)', \(shieldArg))"
            webView.evaluateJavaScript(js) { _, err in
                if let err {
                    self.finish(.failure(ShieldError.message(err.localizedDescription)))
                }
            }
            // Watchdog — never hang forever if the webview goes silent (crash,
            // navigation failure, lost message). The full flow (prove → sign →
            // index → withdraw) can take a few minutes, so allow a generous
            // ceiling. Message stays neutral: a deposit may already be shielded.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                if self.continuation != nil {
                    self.finish(.failure(ShieldError.message(
                        "Private send timed out. Check your balance — any shielded funds are safe and recoverable.")))
                }
            }
        }
    }

    /// One-tap recovery: sweep ALL unspent shielded notes back to `destination`
    /// (the user's own wallet). `seedHex` = the note master; `destination` = the
    /// user's Sui address.
    func recover(seedHex: String, destination: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            self.beginTiming("recover")
            let safeSeed = seedHex.replacingOccurrences(of: "'", with: "")
            let safeDest = destination.replacingOccurrences(of: "'", with: "")
            let js = "if(!window.taliseShieldRecover){throw new Error('Recovery isn’t ready yet — try again.')}; window.taliseShieldRecover('\(safeSeed)','\(safeDest)')"
            webView.evaluateJavaScript(js) { _, err in
                if let err {
                    self.finish(.failure(ShieldError.message(err.localizedDescription)))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                if self.continuation != nil {
                    self.finish(.failure(ShieldError.message(
                        "Recovery timed out — your shielded funds are safe; please try again.")))
                }
            }
        }
    }

    /// Read-only: the user's shielded balance in micros (sum of unspent notes).
    func shieldedBalanceMicros(seedHex: String) async throws -> UInt64 {
        let raw = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            self.beginTiming("balance")
            let safeSeed = seedHex.replacingOccurrences(of: "'", with: "")
            let js = "if(!window.taliseShieldBalance){throw new Error('not ready')}; window.taliseShieldBalance('\(safeSeed)')"
            webView.evaluateJavaScript(js) { _, err in
                if let err { self.finish(.failure(ShieldError.message(err.localizedDescription))) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if self.continuation != nil { self.finish(.failure(ShieldError.message("Balance read timed out."))) }
            }
        }
        return UInt64(raw) ?? 0
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "progress":
            status = body["message"] as? String ?? ""
            // Each in-page stage (key derivation, prove deposit, index, prove
            // withdraw, relay) posts a progress message — timestamp it so the
            // console shows the Δ between stages and where the time actually goes.
            if tStart > 0 {
                print("[ios/private] +\(ms(tStart))ms (Δ\(ms(tPrev))ms) — \(status)")
                tPrev = CFAbsoluteTimeGetCurrent()
            }
        case "result":
            finish(.success(body["digest"] as? String ?? ""))
        case "error":
            finish(.failure(ShieldError.message(body["message"] as? String ?? "Private send failed")))
        case "signDeposit":
            // The DEPOSIT-SIGNING BRIDGE. The webview proved the deposit + built
            // the sponsor-ready PTB (POST /api/shield/deposit/prepare); only the
            // device can zkLogin-sign it (the ephemeral key is native). Sign +
            // submit via the same Onara-sponsored rail as cheques/streams, then
            // hand the digest back so the webview can finish the withdraw leg.
            guard let bytesB64 = body["bytesB64"] as? String, !bytesB64.isEmpty else {
                depositSigned(digest: "", error: "Couldn’t prepare the private deposit.")
                return
            }
            Task { @MainActor in
                let tSign = CFAbsoluteTimeGetCurrent()
                do {
                    let sub = try await ZkLoginCoordinator.shared.executeSponsorReady(
                        bytesB64: bytesB64, intent: "Private send")
                    self.signMs = self.ms(tSign)
                    print("[ios/private] native-sign(deposit)=\(self.signMs)ms digest=\(sub.digest.prefix(10))…")
                    depositSigned(digest: sub.digest, error: "")
                } catch {
                    print("[ios/private] native-sign(deposit) FAILED after \(self.ms(tSign))ms — \(error.localizedDescription)")
                    depositSigned(digest: "", error: error.localizedDescription)
                }
            }
        default:
            break
        }
    }

    /// Resolve the webview's `window.__taliseDepositSigned(digest, error)` promise
    /// with the native signing result (one is non-empty). Strings are JSON-escaped
    /// so a recipient/error containing quotes can't break the injected call.
    private func depositSigned(digest: String, error: String) {
        let js = "window.__taliseDepositSigned && window.__taliseDepositSigned(\(Self.jsString(digest)), \(Self.jsString(error)))"
        webView.evaluateJavaScript(js) { _, _ in }
    }

    private static func jsString(_ s: String) -> String {
        // Encode as a one-element JSON array (top-level arrays are valid) then
        // strip the brackets → a safely-escaped JS string literal.
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast())
    }

    private func finish(_ result: Result<String, Error>) {
        if tStart > 0 {
            switch result {
            case .success(let digest):
                print("[ios/private] DONE op=\(opLabel) total=\(ms(tStart))ms native-sign=\(signMs)ms digest=\(digest.prefix(10))…")
            case .failure(let err):
                print("[ios/private] FAILED op=\(opLabel) after=\(ms(tStart))ms — \(err.localizedDescription)")
            }
            tStart = 0
        }
        continuation?.resume(with: result)
        continuation = nil
    }

    // Navigation logging — surfaces the otherwise-silent web-prover load time
    // and any load failure (the usual cause of a private send that "hangs" to
    // the 300s watchdog because the harness never installed).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[ios/private] prover-web-ready=\(ms(tInit))ms")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[ios/private] prover-web LOAD FAILED after \(ms(tInit))ms — \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[ios/private] prover-web PROVISIONAL LOAD FAILED after \(ms(tInit))ms — \(error.localizedDescription)")
    }
}

/// Hosts the prover's hidden web view (never visibly rendered).
struct ShieldProverHost: UIViewRepresentable {
    let controller: ShieldProverController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// The user's shielded NOTE MASTER — root of their private notes. Two recovery
/// rails: the PRIMARY copy is in the iCloud-synchronizable Keychain (follows the
/// user across their devices); the RECOVERY copy is the server escrow (restored
/// on a fresh device after re-sign-in). Recovery = re-sign-in → restore → re-
/// scan. The master is generated with the secure RNG on first use and never
/// shown; the shield keypair is derived from it client-side in the prover.
enum ShieldKeyStore {
    private static let service = "io.talise.shield"
    private static let account = "note-master.v1"

    /// Hex of the note master, creating + persisting one on first use.
    static func noteMasterHex() async -> String {
        let data = await loadOrCreate()
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadOrCreate() async -> Data {
        if let d = readKeychain() { return d }
        // Fresh device / first use → try the recovery escrow before minting.
        if let restored = await restoreFromEscrow() {
            writeKeychain(restored)
            return restored
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let data = Data(bytes)
        writeKeychain(data)
        // Escrow is authoritative if one already existed (two-device race): the
        // server echoes the stored master, and we adopt + re-pin it locally.
        if let adopted = await backupToEscrow(data), adopted != data {
            writeKeychain(adopted)
            return adopted
        }
        return data
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,  // iCloud rail
        ]
    }

    private static func readKeychain() -> Data? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, d.count >= 16 else { return nil }
        return d
    }

    private static func writeKeychain(_ d: Data) {
        let q = baseQuery()
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private struct EscrowResp: Decodable { let noteMaster: String? }
    private struct EscrowBody: Encodable { let noteMaster: String }

    private static func restoreFromEscrow() async -> Data? {
        guard let r: EscrowResp = try? await APIClient.shared.get("/api/shield/key-escrow"),
              let hex = r.noteMaster else { return nil }
        return dataFromHex(hex)
    }

    private static func backupToEscrow(_ d: Data) async -> Data? {
        let hex = d.map { String(format: "%02x", $0) }.joined()
        guard let r: EscrowResp = try? await APIClient.shared.post(
            "/api/shield/key-escrow", body: EscrowBody(noteMaster: hex)
        ), let stored = r.noteMaster else { return nil }
        return dataFromHex(stored)
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        return data.count >= 16 ? data : nil
    }
}

// MARK: - Private-send branded screens

/// Amount entry for a SHIELDED send. Same muscle-memory as the normal Send
/// keypad, but visibly its own thing: a lock-marked "Private send" header, a
/// shielded accent, and the $10 pilot cap baked into the input.
struct PrivateAmountView: View {
    @Bindable var draft: SendDraft
    var onNext: () -> Void
    var onCancel: () -> Void
    var onRecover: () -> Void = {}

    private var amount: Double { Double(draft.rawAmount) ?? 0 }
    private var overCap: Bool { amount > 10 }
    private var canContinue: Bool { amount > 0 && !overCap }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            amountBlock
            Spacer(minLength: 12)
            shieldedPill.padding(.bottom, 18)
            SendNumpad(input: $draft.rawAmount)
                .padding(.horizontal, 24).padding(.bottom, 12)
            reviewButton.padding(.horizontal, 24).padding(.bottom, 8)
            recoverButton.padding(.bottom, 16)
        }
        .taliseScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Reclaims any shielded balance stranded by an earlier failed transfer —
    /// sweeps every unspent note back to the user's own wallet.
    private var recoverButton: some View {
        Button(action: onRecover) {
            Text("Recover shielded balance")
                .font(TaliseFont.body(13, weight: .medium))
                .foregroundStyle(TaliseColor.fgMuted)
                .underline()
        }
        .buttonStyle(.plain)
    }

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
            HStack(spacing: 6) {
                HugeIcon(name: "hi.lock", size: 13, tint: TaliseColor.greenMint)
                MicroLabel(text: "Private send", color: TaliseColor.fgMuted).kerning(2.0)
            }
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 20).padding(.top, 12)
    }

    private var amountBlock: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("$").font(TaliseFont.display(40, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                Text(draft.rawAmount.isEmpty ? "0" : draft.rawAmount)
                    .font(TaliseFont.display(72, weight: .medium)).kerning(-1)
                    .foregroundStyle(TaliseColor.fg)
            }
            Text(overCap ? "Pilot limit is $10 per private send" : "USDsui · shielded")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(overCap ? TaliseColor.danger : TaliseColor.fgMuted)
        }
    }

    private var shieldedPill: some View {
        HStack(spacing: 8) {
            Circle().fill(TaliseColor.greenMint).frame(width: 7, height: 7)
            Text("SHIELDED · UP TO $10")
                .font(TaliseFont.mono(11, weight: .regular)).tracking(1.5)
                .foregroundStyle(TaliseColor.fgMuted)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(TaliseColor.surface2))
    }

    private var reviewButton: some View {
        Button(action: { if canContinue { onNext() } }) {
            Text("Review")
                .font(TaliseFont.body(16, weight: .semibold))
                .foregroundStyle(canContinue ? TaliseColor.bg : TaliseColor.fgDim)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 16)
                    .fill(canContinue ? TaliseColor.greenMint : TaliseColor.surface2))
        }
        .buttonStyle(TilePress())
        .disabled(!canContinue)
    }
}

/// Review + confirm for a shielded send. Explains the privacy guarantee plainly
/// and runs the proof. Sets `draft.amountUsdsui` from the typed amount (private
/// sends are USDsui 1:1, no cross-border quote).
struct PrivateReviewView: View {
    @Bindable var draft: SendDraft
    var onConfirm: () async -> Void
    var onBack: () -> Void

    @State private var sending = false

    private var recipientName: String {
        draft.resolved?.displayName ?? draft.resolved?.display ?? draft.recipientInput
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    lockHero
                    rowsCard
                    privacyNote
                }
                .padding(.horizontal, 22).padding(.top, 6)
            }
            Spacer(minLength: 0)
            confirmButton.padding(.horizontal, 24).padding(.bottom, 18)
        }
        .taliseScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { draft.amountUsdsui = Double(draft.rawAmount) ?? 0 }
    }

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .frame(width: 38, height: 38)
                    .glassCircle()
            }
            Spacer()
            MicroLabel(text: "Review", color: TaliseColor.fgMuted).kerning(2.0)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 20).padding(.top, 12)
    }

    private var lockHero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(TaliseColor.greenMint.opacity(0.12)).frame(width: 64, height: 64)
                HugeIcon(name: "hi.lock", size: 26, tint: TaliseColor.greenMint)
            }
            Text("$\(draft.rawAmount)")
                .font(TaliseFont.display(34, weight: .medium)).kerning(-0.5)
                .foregroundStyle(TaliseColor.fg)
            Text("shielded · USDsui")
                .font(TaliseFont.mono(11, weight: .regular)).tracking(1.5)
                .foregroundStyle(TaliseColor.fgMuted)
        }
        .padding(.top, 8)
    }

    private var rowsCard: some View {
        VStack(spacing: 0) {
            reviewRow("To", recipientName)
            Divider().overlay(TaliseColor.line)
            reviewRow("Amount", "$\(draft.rawAmount)")
            Divider().overlay(TaliseColor.line)
            reviewRow("Network fee", "None")
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 18).fill(TaliseColor.surface))
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(TaliseFont.body(14, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
            Spacer()
            Text(value).font(TaliseFont.body(14, weight: .regular)).foregroundStyle(TaliseColor.fg)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 15)
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            HugeIcon(name: "hi.lock", size: 15, tint: TaliseColor.greenMint).padding(.top, 1)
            Text("Sent shielded — the link between you and the recipient stays private on-chain, and your money never leaves your control. Early pilot, capped at $10.")
                .font(TaliseFont.body(12.5, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(TaliseColor.surface2.opacity(0.5)))
    }

    private var confirmButton: some View {
        Button {
            guard !sending else { return }
            sending = true
            Task { await onConfirm(); sending = false }
        } label: {
            HStack(spacing: 10) {
                if sending { ProgressView().tint(TaliseColor.bg) }
                Text(sending ? "Sending privately…" : "Send privately")
                    .font(TaliseFont.body(16, weight: .semibold))
                    .foregroundStyle(TaliseColor.bg)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 16).fill(TaliseColor.greenMint))
        }
        .buttonStyle(TilePress())
        .disabled(sending)
    }
}

/// SHIELDED BALANCE hub — your private pocket (sum of unspent notes, amount
/// hidden on-chain) + the actions. "Send private" routes the hidden-amount
/// transfer; "Unshield" sweeps the shielded balance back to your public wallet.
struct ShieldedBalanceView: View {
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    @StateObject private var prover = ShieldProverController()
    @State private var shieldedMicros: UInt64 = 0
    @State private var busy = false
    @State private var status: String?
    @State private var showSend = false

    private var shieldedDisplay: String { String(format: "$%.2f", Double(shieldedMicros) / 1_000_000) }

    var body: some View {
        VStack(spacing: 24) {
            header
            Spacer(minLength: 8)
            explainer
            Spacer(minLength: 4)
            actions
            if let s = status {
                Text(s).font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Spacer()
        }
        .taliseScreenBackground()
        .task { await load() }
        .fullScreenCover(isPresented: $showSend) {
            PrivateSendFlowView(onDone: { showSend = false; Task { await load() } })
        }
        .background(
            ShieldProverHost(controller: prover)
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        )
    }

    private var header: some View {
        HStack {
            Button { if let onDone { onDone() } else { dismiss() } } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TaliseColor.fgMuted).frame(width: 38, height: 38).glassCircle()
            }
            Spacer()
            HStack(spacing: 6) {
                HugeIcon(name: "hi.lock", size: 13, tint: TaliseColor.greenMint)
                MicroLabel(text: "Private", color: TaliseColor.fgMuted).kerning(2.0)
            }
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 20).padding(.top, 12)
    }

    // A plain-language explainer of what a private send is — the screen leads
    // with this, not a $0.00 balance (which read as "you have nothing"). The
    // shielded balance only surfaces, quietly, when there is one to recover.
    private var explainer: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle().fill(TaliseColor.greenMint.opacity(0.14)).frame(width: 86, height: 86)
                HugeIcon(name: "hi.lock", size: 34, tint: TaliseColor.greenMint)
            }
            VStack(spacing: 8) {
                Text("Private sends")
                    .font(TaliseFont.heading(26, weight: .medium)).kerning(-0.4)
                    .foregroundStyle(TaliseColor.fg)
                Text("Send dollars so only you and the person you pay ever know the amount.")
                    .font(TaliseFont.body(14, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                    .multilineTextAlignment(.center).padding(.horizontal, 34)
            }
            VStack(alignment: .leading, spacing: 15) {
                point("The amount is hidden on-chain.")
                point("Sender and recipient stay unlinked.")
                point("Real zero-knowledge, live on Sui.")
            }
            .padding(.horizontal, 34)
            if shieldedMicros > 0 {
                Text("You have \(shieldedDisplay) shielded.")
                    .font(TaliseFont.body(12, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
            }
        }
        .padding(.vertical, 8)
    }

    private func point(_ text: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(TaliseColor.greenMint.opacity(0.16)).frame(width: 26, height: 26)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(TaliseColor.greenMint)
            }
            Text(text).font(TaliseFont.body(15)).foregroundStyle(TaliseColor.fg)
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button { showSend = true } label: { actionLabel("Send privately", filled: true) }
                .buttonStyle(TilePress())
            // Only offer "move to wallet" when there's actually a balance to move —
            // a dead/disabled button at $0.00 is what made this screen confusing.
            if shieldedMicros > 0 {
                Button { Task { await unshield() } } label: {
                    actionLabel(busy ? "Moving…" : "Move to my wallet", filled: false)
                }
                .buttonStyle(TilePress())
                .disabled(busy)
            }
            Text("Up to $10 per send during the pilot.")
                .font(TaliseFont.mono(10, weight: .regular)).tracking(1.2)
                .foregroundStyle(TaliseColor.fgDim)
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
    }

    private func actionLabel(_ t: String, filled: Bool) -> some View {
        Text(t)
            .font(TaliseFont.body(16, weight: .semibold))
            .foregroundStyle(filled ? TaliseColor.bg : TaliseColor.fg)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 16).fill(filled ? TaliseColor.greenMint : TaliseColor.fg.opacity(0.08)))
    }

    private func load() async {
        let seed = await ShieldKeyStore.noteMasterHex()
        shieldedMicros = (try? await prover.shieldedBalanceMicros(seedHex: seed)) ?? 0
    }

    private func unshield() async {
        guard let addr = session.currentUser?.suiAddress, !addr.isEmpty else {
            status = "Couldn’t read your wallet address."
            return
        }
        busy = true
        status = "Moving your private balance to your wallet…"
        do {
            let seed = await ShieldKeyStore.noteMasterHex()
            _ = try await prover.recover(seedHex: seed, destination: addr)
            status = "Moved to your wallet."
            await load()
        } catch {
            status = error.localizedDescription
        }
        busy = false
    }
}
