import SwiftUI

/// Figma node 42-1819 — Home, dark mode. Real data: balance from
/// /api/balances, activity from /api/activity. Empty state matches the
/// Figma "no rows" look (a single muted card).
struct HomeView: View {
    @Environment(AppSession.self) private var session
    @State private var balance: BalancesDTO?
    @State private var activity: [ActivityEntryDTO] = []
    /// False only when there is a cached snapshot to show immediately —
    /// in that case we skip the placeholder/skeleton on first render so
    /// the user sees real numbers instead of grey blobs.
    @State private var loadingBalance = true
    @State private var loadingActivity = true
    /// True once `/api/activity` has returned at least one successful
    /// response in the current view lifetime. Used to suppress the
    /// loading skeleton on transient retries — we keep the prior rows
    /// on screen instead of flashing back to a skeleton.
    @State private var activityHasLoadedOnce = false
    /// Optimistic-stub registry. Keyed on digest, value is the stub
    /// entry we prepended. Survives across `loadActivity*` calls so a
    /// late-arriving canonical row (or any background reload that
    /// wholesale-replaces `activity = r.entries`) can't wipe the
    /// user's freshly-tapped Send/Invest/Withdraw row from view. Each
    /// stub is auto-evicted from the registry the first time its
    /// digest shows up in the server response (server has caught up)
    /// OR after a 90s safety TTL (server never caught up → assume tx
    /// failed silently, stop showing the stub).
    @State private var pendingOptimisticStubs: [String: ActivityEntryDTO] = [:]
    @State private var pendingOptimisticAt: [String: Date] = [:]
    /// Toast banner shown above the History card when an activity
    /// refresh fails (timeout, transport error). Auto-dismisses after
    /// 4s. Drives the small "Couldn't refresh activity" pill — we
    /// preserve the last successful entries underneath rather than
    /// blanking the card.
    @State private var activityRefreshFailed = false
    @State private var scanToPaySheetVisible = false
    @State private var sweepPreview: SweepPreviewDTO?
    @State private var sweepAlertVisible = false
    @State private var sweepAlertMessage = ""
    @State private var sweeping = false
    @State private var receiptEntry: ActivityEntryDTO?
    @State private var historySheetVisible = false
    /// True when the user's `TaliseVault` is holding non-zero balances —
    /// drives the "Move to wallet" pill next to the +/paperplane row.
    /// Read on appear via `/api/vault/state` so we don't paint the CTA
    /// when there's nothing to withdraw.
    @State private var vaultHasFunds: Bool = false
    @State private var vaultWithdrawSheetVisible = false
    /// Plain-wallet (non-vault) balances broken out per coin type.
    /// Drives the "Convert all to USDsui" action button — we only paint
    /// the CTA when there is at least one non-USDsui leg above the dust
    /// threshold to convert.
    @State private var walletCoinBalances: [WalletCoinBalance] = []
    @State private var walletSweepAlertVisible = false
    @State private var walletSweepAlertMessage = ""
    @State private var walletSweeping = false
    /// Transient bottom toast for swap results — replaces re-presenting the
    /// confirm sheet after a swap completes (which read as a wrong "convert
    /// again" prompt). nil = hidden.
    @State private var swapToast: String?
    @State private var swapToastIsError = false
    // Home card carousel: page 0 = account card, page 1 = token bucket.
    @State private var homeCardPage = 0
    @State private var tokenBucketVisible = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 30)
                    .padding(.top, 4)
                balanceBlock
                    .padding(.horizontal, 30)
                    .padding(.top, 32)
                if let preview = sweepPreview, preview.eligible {
                    sweepBanner(preview)
                        .padding(.horizontal, 32)
                        .padding(.top, 18)
                }
                // Autoswap archived 2026-05-29 — AutoSwapMigrationBanner moved to
                // web/_archive/autoswap-2026-05-29/ios/. The Home surface that
                // replaces it is the per-row "Swap to USDsui" CTA driven from
                // the activity feed (see HistoryRow). When the user receives a
                // non-USDsui coin (USDC, DEEP, etc.), the activity row now
                // shows the explicit swap affordance instead of relying on the
                // dormant auto-swap cron.
                homeCardCarousel
                    .padding(.top, 24)
                // Recent activity, back on the home surface (2026-06-04) per
                // the design refs. Top 4 rows; "View all" opens the full
                // HistoryView sheet. `activity` is warmed in the background so
                // this paints instantly.
                recentActivitySection
                    .padding(.horizontal, 22)
                    .padding(.top, 28)
                Color.clear.frame(height: 120)
            }
        }
        .refreshable { await loadAll(force: true) }
        .taliseScreenBackground()
        .task { await loadAll(force: false) }
        .onReceive(NotificationCenter.default.publisher(for: .taliseTxCompleted)) { note in
            guard let ev = note.object as? TaliseTxEvent else { return }
            applyOptimisticTx(ev)
        }
        // Re-pull balance + activity whenever the user lands back on Home
        // after a money flow (send / deposit / withdraw / cross-border). The
        // post-tx optimistic reconcile already runs, but this guarantees a
        // fresh live read the moment Home is visible again — the "balance
        // should auto-refresh when I'm back on the home page" ask.
        .onReceive(NotificationCenter.default.publisher(for: .taliseHomeShouldRefresh)) { _ in
            Task { await loadAll(force: true) }
        }
        // Clean custom "Swap to USDsui" sheets (replace the bare system
        // alerts) — shown when a received non-USDsui coin can be converted.
        .sheet(isPresented: $sweepAlertVisible) {
            SwapToUsdsuiSheet(
                title: "Convert to USDsui",
                message: sweepAlertMessage,
                onConfirm: { Task { await executeSweep() } }
            )
            .presentationDetents([.height(440)])
            .presentationDragIndicator(.visible)
            .presentationBackground(TaliseColor.bg)
        }
        .sheet(isPresented: $walletSweepAlertVisible) {
            SwapToUsdsuiSheet(
                title: "Convert all to USDsui",
                message: walletSweepAlertMessage,
                onConfirm: { Task { await executeWalletSweep() } }
            )
            .presentationDetents([.height(440)])
            .presentationDragIndicator(.visible)
            .presentationBackground(TaliseColor.bg)
        }
        .overlay(alignment: .bottom) {
            if let swapToast {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: swapToastIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(swapToastIsError ? TaliseColor.danger : TaliseColor.accent)
                    Text(swapToast)
                        .font(TaliseFont.body(13.5, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(TaliseColor.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
                .padding(.horizontal, 20)
                // Clear the floating nav pill (≈64pt + bottom inset) so the
                // toast — especially an error — is never hidden behind it.
                .padding(.bottom, 124)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: swapToast)
        .sheet(item: $receiptEntry) { entry in
            TxReceiptView(entry: entry)
                .presentationDetents([.medium, .large])
                .presentationBackground(TaliseColor.bg)
        }
        .sheet(isPresented: $historySheetVisible) {
            HistoryView(initialEntries: activity)
                .presentationDetents([.large])
                .presentationBackground(TaliseColor.bg)
        }
        // Autoswap archived 2026-05-29 — VaultWithdrawSheet moved to
        // web/_archive/autoswap-2026-05-29/ios/. `vaultWithdrawSheetVisible`
        // is preserved as a no-op so any latent setter doesn't break the
        // compile; the trigger sites have been removed.
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            // Brand mark — the source PNG already ships at the right
            // tint, so we render as-is (rendering intent on the asset
            // catalog is "original"). 24×22 keeps the bounding box
            // identical to the prior Canvas-drawn `TaliseLogoMark`
            // so the rest of the navbar layout doesn't shift.
            Image("TaliseLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 22)
            Spacer()
            // Scan-to-Pay is the single top affordance now — History moved off
            // the top into the on-page "Recent activity → View all". Glass chip
            // (the one place we use glass): an ultra-thin material disc with a
            // hairline white edge so it blends into the green header gradient
            // instead of clashing as a solid surface2 puck.
            // Scan-to-pay is server-gated (FEATURE_SCAN_TO_PAY). Hidden until
            // the flag opens it — fail-closed when `me` hasn't loaded.
            if session.currentUser?.scanToPayEnabled == true {
                Button {
                    scanToPaySheetVisible = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan to pay")
            }
        }
        .frame(height: 38)
        .fullScreenCover(isPresented: $scanToPaySheetVisible) {
            ScanToPayView()
        }
        .fullScreenCover(isPresented: $tokenBucketVisible) {
            TokenBucketView(
                coins: walletSweepLegs,
                symbolFor: { walletSweepLegSymbol($0) },
                onSwap: { coin in await swapSingleCoin(coin) },
                onSend: {
                    tokenBucketVisible = false
                    NotificationCenter.default.post(name: .taliseRequestSendCover, object: nil)
                },
                onDone: { tokenBucketVisible = false }
            )
        }
    }

    // MARK: - Recent activity

    /// On-page recent activity — the top 4 rows, with "View all" opening the
    /// full HistoryView sheet. Reuses the warmed `activity` + the shared
    /// `HistoryRow`; tapping a row opens its receipt (`receiptEntry`).
    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT ACTIVITY")
                    .font(TaliseFont.mono(10, weight: .regular))
                    .tracking(2.0)
                    .foregroundStyle(TaliseColor.fgMuted)
                Spacer()
                Button {
                    historySheetVisible = true
                } label: {
                    HStack(spacing: 3) {
                        Text("View all")
                            .font(TaliseFont.body(12, weight: .light))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(TaliseColor.fgMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            if activity.isEmpty {
                Text("No activity yet")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 22)
                    .flatCard(cornerRadius: 20)
            } else {
                // One flat solid card holding the rows, separated by hairline
                // dividers indented past the badge — the clean Apple-system
                // list look on a single flat surface plate.
                let rows = Array(activity.prefix(4))
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { i in
                        HistoryRow(entry: rows[i]) { receiptEntry = rows[i] }
                        if i < rows.count - 1 {
                            Rectangle()
                                .fill(TaliseColor.line)
                                .frame(height: 0.75)
                                .padding(.leading, 64)
                        }
                    }
                }
                .flatCard(cornerRadius: 20)
            }
        }
    }

    // MARK: - Balance + actions

    /// Privacy eye — hides the balance figure + every transaction amount
    /// (HistoryRow reads the same key). UserDefaults-backed so it sticks
    /// across launches and applies app-wide.
    @AppStorage("talise.amountsHidden") private var amountsHidden = false

    private var balanceBlock: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                // Quiet mono eyebrow — moves the "Balance" label into the
                // same micro-label register as the rest of the app so the
                // big figure underneath carries the weight on its own.
                HStack(spacing: 8) {
                    Text("BALANCE")
                        .font(TaliseFont.mono(10, weight: .regular))
                        .tracking(2.0)
                        .foregroundStyle(TaliseColor.fgMuted)
                    // Privacy eye — masks the figure + all tx amounts.
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { amountsHidden.toggle() }
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    } label: {
                        Image(systemName: amountsHidden ? "eye.slash" : "eye")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(TaliseColor.fgDim)
                    }
                    .buttonStyle(.plain)
                }

                // USDsui is the primary unit. We render it as `$X.XX`
                // since it's pegged 1:1 to USD on chain. SUI balance
                // gets its own sub-line so the user still sees gas
                // headroom without a "total USD" rollup that can drift
                // with SUI price. Big, bold, FLAT hero figure — solid white
                // dollars with the cents dimmed for the Cash App look.
                balanceHero
                    .font(TaliseFont.display(40, weight: .semibold))
                    .kerning(-1.6)
                    // Keep the whole figure on ONE line — symbol + digits +
                    // cents live in a single composed Text, so a width-driven
                    // scale-down shrinks them in lockstep (no "…679.8 / 0"
                    // wrap, and the currency glyph always tracks the number).
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .redacted(reason: loadingBalance ? .placeholder : [])

                // Two-part sub-line: the underlying USDsui amount so the
                // user can sanity-check the FX conversion, then the
                // green "earn" nudge.
                HStack(spacing: 8) {
                    Text(suiusdFormatted)
                        .font(TaliseFont.mono(10, weight: .light))
                        .kerning(-0.4)
                        .foregroundStyle(TaliseColor.fgMuted)
                    Text("·")
                        .font(TaliseFont.mono(10, weight: .light))
                        .foregroundStyle(TaliseColor.fgDim)
                    Text("Earn on your idle balance")
                        .font(TaliseFont.mono(10, weight: .light))
                        .kerning(-0.4)
                        .foregroundStyle(TaliseColor.accent)
                }
                .padding(.top, 2)
            }
            Spacer()
            HStack(spacing: 8) {
                // "Convert all to USDsui" — one-tap sweep of every non-
                // USDsui coin in the plain wallet through Cetus. Only
                // painted when we have at least one swappable leg above
                // dust; otherwise it's hidden so the row doesn't show a
                // button that would no-op on tap.
                if walletSweepEligible {
                    actionButton(systemName: "arrow.left.arrow.right") {
                        walletSweepAlertMessage = walletSweepConfirmationMessage()
                        walletSweepAlertVisible = true
                    }
                }
                // Deposit (+) — the primary "add money" affordance. Given
                // a subtle mint tint so the entry point into the redesigned
                // Deposit flow reads as the hero action in the row without
                // shouting over the balance figure.
                actionButton(systemName: "plus", accented: true) {
                    NotificationCenter.default.post(
                        name: .taliseRequestDepositCover, object: nil
                    )
                }
                // "Move to wallet" — only painted when the user has
                // something to pull out of the vault. Auto-swap drops
                // USDsui into the vault; this pill is the way to spend
                // that money. Tray-arrow-up reads as "lift out of
                // container" in the SF Symbol library.
                if vaultHasFunds {
                    actionButton(systemName: "tray.and.arrow.up.fill") {
                        vaultWithdrawSheetVisible = true
                    }
                }
                // SF Symbol `paperplane` (outlined, not `.fill`) ships at
                // the canonical ~45° upper-right angle that reads as
                // "send" in every messaging app since Telegram. The old
                // `.fill` + `rotated: -30` combo pushed the body nearly
                // vertical and lost the directional cue.
                actionButton(systemName: "paperplane", accented: true) {
                    NotificationCenter.default.post(
                        name: .taliseRequestWithdrawCover, object: nil
                    )
                }
            }
            .padding(.bottom, 6)
        }
    }

    /// Primary balance figure — rendered in the user's chosen display
    /// currency (defaults to USD, configurable from Profile). On-chain
    /// the wallet still holds USDsui (1:1 USD); this just maps it
    /// through the FX rate.
    private var usdsuiFormatted: String {
        TaliseFormat.local2(balance?.usdsui ?? 0)
    }

    /// Big bold hero balance with the cents dimmed (Cash App / Robinhood
    /// look). Splits the formatted figure on the LAST "." so the whole
    /// fraction reads in `fgMuted` while the integer + currency symbol stay
    /// in solid `fg`. Falls back to the plain string if there's no decimal.
    private var balanceHero: Text {
        if amountsHidden {
            return Text("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}").foregroundColor(TaliseColor.fgMuted)
        }
        let s = usdsuiFormatted
        guard let dot = s.lastIndex(of: ".") else {
            return Text(s).foregroundColor(TaliseColor.fg)
        }
        let dollars = String(s[..<dot])
        let cents = String(s[dot...])
        return Text(dollars).foregroundColor(TaliseColor.fg)
            + Text(cents).foregroundColor(TaliseColor.fgMuted)
    }
    
    /// Secondary "0.05 USDsui" line beneath the localized balance.
    /// Always shows the on-chain unit so the user can sanity-check
    /// the FX conversion against the asset that's actually moving.
    private var suiusdFormatted: String {
        if amountsHidden { return "\u{2022}\u{2022}\u{2022}\u{2022} USDsui" }
        let v = balance?.usdsui ?? 0
        if v < 0.01 {
            return String(format: "%.4f USDsui", v)
        }
        return String(format: "%.2f USDsui", v)
    }
    
    private func actionButton(
        systemName: String,
        rotated degrees: Double = 0,
        accented: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accented ? TaliseColor.bg : TaliseColor.fg)
                .rotationEffect(.degrees(degrees))
                .frame(width: 44, height: 44)
                // FLAT solid action pill — primary = solid accent green with
                // near-black ink; secondary = flat surface2 with fg ink. No
                // material, blur, gradient, stroke, or shadow.
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(accented ? TaliseColor.accent : TaliseColor.surface2)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Username card

    private var usernameCard: some View {
        ZStack(alignment: .topLeading) {
            // Empty container the flat surface attaches to. The 212pt
            // height matches the Figma spec. FLAT solid card — surface fill,
            // no material/wash/highlight/gradient edge.
            Color.clear
                .frame(height: 212)
                .flatCard(cornerRadius: 25)
            // Branded Sui coin mark in the card's top-right corner.
            // Source PNG is the full-color Sui mark, so we render as
            // original (no template tint). Box bumped 18×24 → 26×26
            // to give the round mark a proportional footprint vs the
            // narrower drop the old `sui-drop` SVG used.
            Image("SuiCoinMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
                .padding(.top, 22)
                .padding(.trailing, 24)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            VStack(alignment: .leading, spacing: 0) {
                if let handle = currentHandle {
                    Text(handle)
                        .font(TaliseFont.heading(20, weight: .medium))
                        .kerning(-0.8)
                        .foregroundStyle(TaliseColor.fgSubtle)
                        .padding(.top, 27)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    claimCTA
                        .padding(.top, 24)
                }
                Spacer(minLength: 0)
                HStack {
                    MicroLabel(text: "$0.00 FEE")
                        .kerning(-0.32)
                    Spacer()
                    MicroLabel(text: "YOUR MONEY LANDS HERE")
                        .kerning(-0.32)
                }
                .padding(.bottom, 22)
            }
            .padding(.horizontal, 32)
            .frame(height: 212)
        }
    }

    /// Swipeable home cards: the account card (page 0) and the token
    /// bucket (page 1). Slide horizontally; tap the bucket to view tokens
    /// besides USDsui, with per-coin Send and Swap-to-USDsui.
    private var homeCardCarousel: some View {
        VStack(spacing: 12) {
            TabView(selection: $homeCardPage) {
                usernameCard
                    .padding(.horizontal, 32)
                    .tag(0)
                tokenBucketCard
                    .padding(.horizontal, 32)
                    .tag(1)
            }
            .frame(height: 212)
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack(spacing: 7) {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .fill(i == homeCardPage ? TaliseColor.fg : TaliseColor.fgDim.opacity(0.45))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }

    /// Number of non-USDsui tokens the user holds (above dust).
    private var tokenBucketSubtitle: String {
        let n = walletSweepLegs.count
        if n == 0 { return "No other tokens yet" }
        return "\(n) token\(n == 1 ? "" : "s") besides USDsui"
    }

    /// The second home card. Same flat surface as the account card; tap to
    /// open the token bucket.
    private var tokenBucketCard: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(height: 212)
                .flatCard(cornerRadius: 25)
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 22))
                .foregroundStyle(TaliseColor.greenMint.opacity(0.9))
                .padding(.top, 22)
                .padding(.trailing, 24)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            VStack(alignment: .leading, spacing: 0) {
                Text("Token bucket")
                    .font(TaliseFont.heading(20, weight: .medium))
                    .kerning(-0.8)
                    .foregroundStyle(TaliseColor.fgSubtle)
                    .padding(.top, 27)
                Text(tokenBucketSubtitle)
                    .font(TaliseFont.body(13))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .padding(.top, 7)
                Spacer(minLength: 0)
                HStack {
                    MicroLabel(text: "OTHER TOKENS")
                        .kerning(-0.32)
                    Spacer()
                    HStack(spacing: 5) {
                        MicroLabel(text: "TAP TO VIEW")
                            .kerning(-0.32)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(TaliseColor.fgDim)
                    }
                }
                .padding(.bottom, 22)
            }
            .padding(.horizontal, 32)
            .frame(height: 212)
        }
        .contentShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        .onTapGesture { tokenBucketVisible = true }
    }

    /// CTA shown on the username card when the user hasn't minted a
    /// `*.talise.sui` subname yet. Tap → MainTabView opens the
    /// ClaimHandleSheet (so the underlying tab blurs uniformly).
    private var claimCTA: some View {
        Button {
            NotificationCenter.default.post(
                name: .taliseRequestClaimSheet, object: nil
            )
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claim your name")
                    .font(TaliseFont.heading(20, weight: .medium))
                    .kerning(-0.8)
                    .foregroundStyle(TaliseColor.fgSubtle)
                HStack(spacing: 6) {
                    Text("So friends can send you USDsui by name.")
                        .font(TaliseFont.body(12, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .lineLimit(2)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TaliseColor.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Real on-chain handle if minted, the short address as a fallback
    /// when on Home we still want to identify the wallet. Returning nil
    /// triggers the Claim CTA.
    private var currentHandle: String? {
        guard case .ready(let user) = session.phase else { return nil }
        return user.displayHandle()
    }

    // MARK: - Activity card

    /// History section — TODAY's activity only, no surrounding container.
    /// Each row is its own glassmorphic pill with a directional tint
    /// (red/green/none). Capped at 4 rows; "See all" opens HistoryView
    /// with the full feed + filters. Older entries stay reachable via
    /// "See all" even when today's section is empty.
    private var activityCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                    .font(TaliseFont.heading(17, weight: .medium))
                    .kerning(-0.4)
                    .foregroundStyle(TaliseColor.fg)
                Spacer()
                if !activity.isEmpty {
                    Button {
                        historySheetVisible = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("See all")
                                .font(TaliseFont.body(12, weight: .light))
                                .foregroundStyle(TaliseColor.fgMuted)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(TaliseColor.fgMuted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Soft inline notice when /api/activity refresh fails. We
            // keep the prior rows visible underneath; this pill is the
            // only hint the user gets that the most recent refresh
            // didn't make it. Auto-dismisses after 4s via the timer
            // started in `loadActivity(isRetry:)`.
            if activityRefreshFailed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(TaliseColor.fgMuted)
                    Text("Couldn't refresh activity")
                        .font(TaliseFont.body(11, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(TaliseColor.surfaceGlass)
                )
                .transition(.opacity)
            }

            if loadingActivity {
                VStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { _ in activityRowSkeleton }
                }
            } else if activity.isEmpty {
                activityEmptyState
                    .padding(.vertical, 24)
            } else {
                // Top 4 most-recent activity rows (any date). "See all"
                // opens the full filterable history.
                VStack(spacing: 10) {
                    ForEach(activity.prefix(4)) { row in
                        HistoryRow(entry: row) { receiptEntry = row }
                    }
                }
            }
        }
    }

    /// Single-row placeholder matching the glassy HistoryRow look.
    private var activityRowSkeleton: some View {
        HStack(spacing: 14) {
            Circle().fill(TaliseColor.badgeNeutral).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(TaliseColor.line).frame(width: 80, height: 10)
                Capsule().fill(TaliseColor.line).frame(width: 50, height: 8)
            }
            Spacer()
            Capsule().fill(TaliseColor.line).frame(width: 60, height: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .redacted(reason: .placeholder)
        .opacity(0.6)
    }

    /// Empty state for the History section. Rendered inline (no
    /// surrounding container) since the section itself no longer
    /// uses a card frame.
    private var activityEmptyState: some View {
        VStack(spacing: 6) {
            Text("Nothing yet")
                .font(TaliseFont.body(14, weight: .light))
                .foregroundStyle(TaliseColor.fg)
            Text("Your sends and receives will land here.")
                .font(TaliseFont.mono(10, weight: .light))
                .kerning(-0.32)
                .foregroundStyle(TaliseColor.fgDim)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private func loadAll(force: Bool) async {
        // Stale-while-revalidate: seed the UI from the on-disk snapshot
        // before the network round-trips complete so the user sees real
        // numbers on the very first frame. Only applied on the initial
        // load (not on force-refreshes) so a pull-to-refresh doesn't
        // temporarily flash old data over a live result.
        if !force, let uid = session.currentUser?.id {
            // Balance: a single number the live read corrects within ~1s, so
            // ANY last-known value is safe to flash. Prefer a fresh snapshot,
            // but fall back to the newest one on disk regardless of age — a
            // slightly stale figure always beats the grey skeleton the user
            // was seeing on every cold open ("balance takes long to load").
            if balance == nil,
               let cached = LocalSnapshotStore.loadBalancesIfFresh(userId: uid, maxAgeSec: 60 * 60)
                            ?? LocalSnapshotStore.loadBalances(userId: uid) {
                balance = cached
                loadingBalance = false   // real number visible; no placeholder
            }
            // Activity: "Recent" must be genuinely recent. Only instant-paint
            // the cached feed if it's <2min old (a close-and-reopen); anything
            // older loads fresh from the snapshot-backed /api/activity so we
            // never show a days-old feed as Recent. (Bug: stale cache was
            // shown and the cold-launch revalidate didn't replace it.)
            // History must never be blank on open. Prefer a <2min cache for a
            // genuinely "recent" feel; otherwise fall back to the newest cache
            // on disk regardless of age — a slightly stale feed beats an empty
            // "Recent" card. The live /api/activity load right after this
            // revalidates and replaces it (immutable history never downgrades).
            if activity.isEmpty,
               let cached = LocalSnapshotStore.loadActivityIfFresh(userId: uid, maxAgeSec: 2 * 60)
                            ?? LocalSnapshotStore.loadActivity(userId: uid),
               !cached.isEmpty {
                activity = cached
                activityHasLoadedOnce = true  // suppress skeleton; show cached rows
                loadingActivity = false
            }
        }

        await withTaskGroup(of: Void.self) { group in
            // Always an authoritative fresh read so a cold/stale display
            // snapshot can't flash ₦0.00. On pull-to-refresh the native spinner
            // covers it (silent); on cold open the skeleton shows only if we
            // had nothing cached to seed above.
            group.addTask { await loadBalance(fresh: true, silent: force) }
            group.addTask { await loadActivity() }
            // loadSweepPreview() removed: /api/sweep/prepare no longer
            // exists on the backend (404s on every open). The banner +
            // execute path are left intact for the SUI→USDsui sweep flow
            // triggered from walletCoinBalances (a different endpoint).
            group.addTask { await loadWalletCoinBalances() }
            _ = force
        }
    }

    /// Vault presence check archived 2026-05-29. Stays as a no-op so the
    /// `vaultHasFunds` state cell (still read in a few UI gates lower in
    /// this file) stays trivially `false`.
    private func loadVaultPresence() async {
        vaultHasFunds = false
    }

    /// Load the headline balance.
    ///
    /// - `fresh`: append `?fresh=1` so the server does an authoritative live
    ///   gRPC read instead of possibly serving a cold/stale display-only
    ///   snapshot — that snapshot is exactly what flashed ₦0.00 on a cold open
    ///   before the real number landed. Cold open, pull-to-refresh, and every
    ///   post-tx reconcile use this.
    /// - `silent`: never flip the loading skeleton. We only ever show the
    ///   skeleton for the FIRST-ever load (nothing on screen yet); whenever we
    ///   already have a value — a cached seed, an optimistic figure, a prior
    ///   read — the refresh runs silently underneath the visible number.
    private func loadBalance(fresh: Bool = false, silent: Bool = false) async {
        // Loader only when there's genuinely nothing to show yet.
        let showLoader = !silent && balance == nil
        if showLoader { loadingBalance = true }
        defer { if showLoader { loadingBalance = false } }
        do {
            let path = fresh ? "/api/balances?fresh=1" : "/api/balances"
            let fetched: BalancesDTO = try await APIClient.shared.get(path)
            // Never let an all-zero read clobber a non-zero value already on
            // screen UNLESS this was an authoritative `fresh` read. The
            // display-only snapshot can momentarily report 0 before the chain
            // read lands; a genuine zero arrives via the optimistic spend path
            // or a confirmed fresh read. This kills the "₦0.00 on open" flash.
            if fetched.totalUsd == 0, !fresh, let cur = balance, cur.totalUsd > 0 {
                // Keep the current value; the next fresh read corrects it.
            } else {
                balance = fetched
                // Persist for the next cold launch so the stale-while-
                // revalidate path can paint real numbers immediately.
                if let uid = session.currentUser?.id {
                    LocalSnapshotStore.saveBalances(fetched, userId: uid)
                }
            }
        } catch {
            // Keep the last-known number on screen no matter what — a slightly
            // stale balance always beats a blank / ₦0.00 card. (Previously a
            // non-cancellation error nil'd the balance, which IS the
            // "no balance available on open" downtime we're eliminating.) On a
            // true first-ever load with no cache, `balance` is already nil, so
            // the skeleton stays until a read succeeds.
        }
    }

    private func loadActivity() async {
        await loadActivity(isRetry: false, freshBypass: false)
    }

    /// Cache-bypassing variant used by `applyOptimisticTx`. Appends
    /// `?fresh=1` so the server skips its 5s memoTtl on this one call
    /// — without it, the post-send reconcile can hit a cache slice
    /// computed pre-tx, wiping the optimistic row off screen until the
    /// next pull-to-refresh. See /api/activity/route.ts.
    private func loadActivityFresh() async {
        await loadActivity(isRetry: false, freshBypass: true)
    }

    /// Activity load with tolerance for transient failures.
    ///
    /// Behavior on error (non-cancellation):
    ///   • Preserve the prior `activity` rows — do NOT zero them out.
    ///     A stale row beats an empty card every time, and prevents
    ///     the "20 entries → 0 entries" flicker we saw in the iOS log
    ///     forwarded 2026-05-29.
    ///   • If this is the FIRST attempt, surface a 4s auto-dismissing
    ///     toast ("Couldn't refresh activity") and schedule one
    ///     background retry 5s later. If the retry succeeds, it
    ///     silently replaces the rows; if it fails too, we give up
    ///     until the next foreground / pull-to-refresh.
    ///   • If this is already the retry attempt, do not schedule
    ///     another one — avoid a recursive retry loop on a wedged
    ///     route.
    ///
    /// We skip the skeleton on retry (`activityHasLoadedOnce`) so the
    /// user doesn't see a placeholder flash over their last-good rows.
    private func loadActivity(isRetry: Bool, freshBypass: Bool = false) async {
        if !activityHasLoadedOnce {
            loadingActivity = true
        }
        defer { loadingActivity = false }
        do {
            // `fresh=1` skips the server's 5s memoTtl — used by the
            // post-tx reconcile so a freshly-landed digest isn't masked
            // by a cached pre-tx slice.
            let path = freshBypass
                ? "/api/activity?limit=20&fresh=1"
                : "/api/activity?limit=20"
            let r: ActivityResponse = try await APIClient.shared.get(path)
            #if DEBUG
            if AppConfig.shared.verboseConsoleLogging {
                print("[activity] decoded \(r.entries.count) entries")
            }
            #endif
            // On-chain history is immutable — never let a transient empty or
            // short response downgrade what's already on screen. Accept the
            // new feed only when it has rows (or when we have nothing yet);
            // otherwise keep the prior rows.
            let merged = mergePendingStubs(into: r.entries)
            if !merged.isEmpty || activity.isEmpty {
                activity = merged
            }
            activityHasLoadedOnce = true
            // Persist for the next cold launch (stale-while-revalidate). Only
            // cache the raw server entries (not the merged stubs) so we don't
            // persist optimistic rows that may never confirm — AND only when
            // non-empty, so an empty response never poisons the good cache.
            if let uid = session.currentUser?.id, !r.entries.isEmpty {
                LocalSnapshotStore.saveActivity(r.entries, userId: uid)
            }
            // Silently dismiss the toast if the retry succeeded.
            activityRefreshFailed = false
        } catch {
            // Don't log cancellations — they're the dominant signal in
            // dev because SwiftUI's `.task` cancels its prior body
            // every time the view re-evaluates. Logging them used to
            // turn the dev console into unreadable `[activity] load
            // failed: …NSURLErrorDomain Code=-999 "cancelled"…` spam.
            if APIError.isCancellation(error) { return }
            #if DEBUG
            if AppConfig.shared.verboseConsoleLogging {
                print("[activity] load failed: \(error)")
            }
            #endif
            // Last resort: if we have NOTHING on screen and the live read
            // failed, fall back to the un-gated local snapshot. Immutable
            // history (even slightly stale) beats a blank "Recent" card.
            if activity.isEmpty, let uid = session.currentUser?.id,
               let cached = LocalSnapshotStore.loadActivity(userId: uid),
               !cached.isEmpty {
                activity = mergePendingStubs(into: cached)
                activityHasLoadedOnce = true
            }
            // Keep the last-known rows on screen. Only mark refresh
            // failure if we have nothing to show — otherwise the user
            // sees their prior history and a small "couldn't refresh"
            // hint above it.
            activityRefreshFailed = true
            // Auto-dismiss the toast after 4s.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4 * NSEC_PER_SEC)
                activityRefreshFailed = false
            }
            // Single background retry on first failure. Don't recurse
            // further — a second failure means the route is wedged
            // and we should wait for an explicit user refresh.
            if !isRetry {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5 * NSEC_PER_SEC)
                    await loadActivity(isRetry: true)
                }
            }
        }
    }

    /// Sui fullnode `suix_queryTransactionBlocks` and `suix_getBalance`
    /// can lag the actual chain state by 1-3 seconds after a tx lands,
    /// even though Onara's gRPC `executeTransaction` already confirmed
    /// the digest. Refreshing immediately therefore returns pre-send
    /// state and the user sees their balance unchanged + their tx
    /// missing from History.
    ///
    /// To avoid that flash of stale data, we apply an optimistic patch
    /// the moment the sender hands us the digest:
    ///   • prepend a synthetic ActivityEntryDTO so the row appears
    ///     immediately (with the same shape /api/activity will emit
    ///     a second later)
    ///   • adjust the on-screen USDsui balance by the moved amount
    /// Then we schedule a real reload 1.5s out to reconcile against
    /// the canonical chain query — whichever side of the optimistic
    /// patch ends up wrong is fixed silently on that pass.
    /// Merge any still-pending optimistic stubs into a server response
    /// before assigning to `activity`. A stub is re-prepended if its
    /// digest ISN'T in the server response (server hasn't indexed it
    /// yet). When the server response DOES contain the digest, the
    /// stub is evicted from the pending registry (server caught up;
    /// canonical row is authoritative going forward). 90s TTL on
    /// pending entries so a tx that genuinely failed silently doesn't
    /// haunt the History list forever.
    private func mergePendingStubs(into serverEntries: [ActivityEntryDTO]) -> [ActivityEntryDTO] {
        let serverDigests = Set(serverEntries.map(\.digest))
        let now = Date()
        let ttl: TimeInterval = 90
        // Evict: server-acked (canonical row landed) OR past TTL.
        let serverDigestsCopy = serverDigests
        let pendingAtCopy = pendingOptimisticAt
        pendingOptimisticStubs = pendingOptimisticStubs.filter { (digest, _) in
            if serverDigestsCopy.contains(digest) { return false }
            if let at = pendingAtCopy[digest], now.timeIntervalSince(at) > ttl { return false }
            return true
        }
        pendingOptimisticAt = pendingOptimisticAt.filter { (digest, _) in
            pendingOptimisticStubs[digest] != nil
        }
        // Prepend surviving stubs (most-recent-first) over the server list.
        let stubs = pendingOptimisticStubs.values.sorted { $0.timestampMs > $1.timestampMs }
        return stubs + serverEntries.filter { !pendingOptimisticStubs.keys.contains($0.digest) }
    }

    private func applyOptimisticTx(_ ev: TaliseTxEvent) {
        // Drop any prior optimistic entry for the same digest (e.g.
        // the user sent twice quickly and we already showed the first).
        let synthetic = ActivityEntryDTO(
            digest: ev.digest,
            timestampMs: Date().timeIntervalSince1970 * 1000,
            direction: ev.direction,
            amountUsdsui: ev.amountUsdsui,
            amountSui: nil,
            counterparty: ev.counterparty,
            counterpartyName: ev.counterpartyName,
            venue: ev.venue,
            // Optimistic stub for sent / invest / withdraw / send-leg
            // of a compound tx — none of those move non-USDsui coins,
            // so `otherCoin` is always nil here. The real entry from
            // /api/activity will replace this stub on next refresh.
            otherCoin: nil
        )
        // Register the stub in the pending dict so subsequent
        // loadActivity calls (which all set `activity = r.entries`)
        // can't wipe it. mergePendingStubs() in those load paths
        // re-prepends until either the canonical row lands or the
        // 90s TTL evicts the stub.
        pendingOptimisticStubs[ev.digest] = synthetic
        pendingOptimisticAt[ev.digest] = Date()
        activity = [synthetic] + activity.filter { $0.digest != ev.digest }

        // Tell the server to emit a `digest` SSE event when this
        // specific tx lands on chain. Fire-and-forget — if the
        // /watch call fails, the 90s stub TTL still evicts the row,
        // and the post-tx reconcile schedule (1.5s + 2.5s) below
        // still pulls /api/activity. Belt-and-suspenders by design.
        Task {
            struct WatchBody: Encodable { let digest: String }
            struct WatchResponse: Decodable { let ok: Bool? }
            do {
                let _: WatchResponse = try await APIClient.shared.post(
                    "/api/stream/watch",
                    body: WatchBody(digest: ev.digest)
                )
            } catch {
                // Silent — see comment above.
            }
        }

        // Balance: sent + invest leave the wallet (decrement);
        // withdraw returns to the wallet (increment).
        if let b = balance {
            let delta: Double
            switch ev.direction {
            case "sent", "invest":   delta = -ev.amountUsdsui
            case "withdraw":         delta =  ev.amountUsdsui
            default:                 delta = 0
            }
            let nextUsdsui = max(0, b.usdsui + delta)
            // totalUsd: USDsui counts 1:1; SUI side stays as-is. We
            // keep this consistent with the server's calc so the
            // reconciled refresh doesn't visibly jump.
            let nextTotal = max(0, b.totalUsd + delta)
            balance = BalancesDTO(
                address: b.address,
                usdsui: nextUsdsui,
                sui: b.sui,
                suiPriceUsd: b.suiPriceUsd,
                totalUsd: nextTotal
            )
        }

        // Reconcile against canonical chain state. We use the
        // cache-bypass `fresh=1` path so the server's 5s memoTtl can't
        // serve a stale pre-tx slice that would wipe the synthetic row
        // we just prepended. Then we re-attempt at 4s for a second
        // chance — the fullnode's queryTransactionBlocks index
        // sometimes needs the extra beat. If both passes miss the
        // digest, the optimistic row simply stays on screen (the
        // dedupe filter prevents duplicates).
        // The optimistic balance adjust above is the "immediate" update the
        // user sees. We then reconcile against canonical chain state twice —
        // right now, and again 5s after the tx — both SILENT (no loaders), per
        // the "auto-refresh balance + history immediately, then again 5s
        // later, with no spinner" ask.
        let pendingDigest = ev.digest
        let stub = ActivityEntryDTO(
            digest: ev.digest,
            timestampMs: Date().timeIntervalSince1970 * 1000,
            direction: ev.direction,
            amountUsdsui: ev.amountUsdsui,
            amountSui: nil,
            counterparty: ev.counterparty,
            counterpartyName: ev.counterpartyName,
            venue: ev.venue,
            otherCoin: nil
        )
        // Keep the user's just-made action pinned to the top of History until
        // the fullnode's tx index surfaces the real digest.
        func pinStubIfMissing() {
            if !activity.contains(where: { $0.digest == pendingDigest }) {
                activity = [stub] + activity.filter { $0.digest != ev.digest }
            }
        }
        Task {
            // 1) Immediate. Balance is current chain state, so a fresh read
            //    reflects the new figure right away; history may lag the
            //    fullnode index, so the stub holds the top meanwhile.
            await loadBalance(fresh: true, silent: true)
            await loadActivityFresh()
            pinStubIfMissing()
            // 2) Again 5s after the tx — the tx index has caught up by now.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await loadBalance(fresh: true, silent: true)
            await loadActivityFresh()
            pinStubIfMissing()
        }
    }

    private func currency(_ v: Double) -> String {
        TaliseFormat.usd(v)
    }

// MARK: - Sweep to USDsui (Onara-sponsored, Cetus route)

    /// Renders when the wallet holds non-USDsui coins worth more than
    /// dust. Tap → confirmation alert → POST /api/sweep/prepare with
    /// action=execute → sponsored swap via Onara.
    private func sweepBanner(_ p: SweepPreviewDTO) -> some View {
        Button {
            sweepAlertMessage = sweepConfirmationMessage(p)
            sweepAlertVisible = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(TaliseColor.accent.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TaliseColor.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(sweepHeadline(p))
                        .font(TaliseFont.body(13, weight: .light))
                        .foregroundStyle(TaliseColor.fg)
                    MicroLabel(
                        text: "Onara-sponsored · Network fee $0.00",
                        color: TaliseColor.fgDim
                    ).kerning(0.8)
                }
                Spacer()
                if sweeping {
                    ProgressView().controlSize(.small).tint(TaliseColor.fg)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TaliseColor.fgDim)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // FLAT solid surface plate — no material, wash, or shadow.
            .flatCard(cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .disabled(sweeping)
    }

    private func sweepHeadline(_ p: SweepPreviewDTO) -> String {
        let fromAmt = p.from.amount ?? 0
        let toUsd = p.to.estimateUsd ?? 0
        let fromStr = fromAmt < 1
            ? String(format: "%.4f", fromAmt)
            : String(format: "%.2f", fromAmt)
        return "Convert \(fromStr) \(p.from.coin) → \(TaliseFormat.usd2(toUsd)) USDsui"
    }

    private func sweepConfirmationMessage(_ p: SweepPreviewDTO) -> String {
        let toUsd = p.to.estimateUsd ?? 0
        return "Swap your SUI to USDsui via Cetus. Onara pays the gas — you pay $0 in fees. Estimated: \(TaliseFormat.usd2(toUsd))."
    }

    private func loadSweepPreview() async {
        struct Body: Encodable { let action: String }
        do {
            sweepPreview = try await APIClient.shared.post(
                "/api/sweep/prepare",
                body: Body(action: "preview")
            )
        } catch {
            // Same cancellation-vs-failure split as loadBalance — don't
            // clobber the banner state on a refresh-triggered cancel.
            if !APIError.isCancellation(error) {
                sweepPreview = nil
            }
        }
    }

    /// Show a transient bottom toast (auto-dismisses) for a swap result.
    /// Errors linger longer than successes so they're actually readable.
    private func flashToast(_ message: String, isError: Bool = false) {
        swapToastIsError = isError
        swapToast = message
        let ns: UInt64 = isError ? 6_000_000_000 : 2_800_000_000
        Task {
            try? await Task.sleep(nanoseconds: ns)
            await MainActor.run { if swapToast == message { swapToast = nil } }
        }
    }

    private func executeSweep() async {
        sweeping = true
        defer { sweeping = false }
        struct Body: Encodable { let action: String }
        do {
            // 1. Backend builds the Cetus router-swap PTB (transactionKindB64).
            let built: SweepExecuteDTO = try await APIClient.shared.post(
                "/api/sweep/prepare",
                body: Body(action: "execute")
            )
            // 2. Hand to the same Onara-sponsored sign+submit pipeline
            //    Send/Earn use. The user signs the intent once with the
            //    ephemeral Curve25519 key; Onara pays gas.
            let amt = built.from.amount ?? 0
            let intent = String(format: "Convert %.4f SUI to USDsui", amt)
            let result = try await ZkLoginCoordinator.shared.signAndSubmit(
                transactionKindB64: built.transactionKindB64,
                intent: intent
            )
            _ = result
            // Success → a transient toast, NOT a re-presented confirm sheet.
            flashToast("Converted to USDsui")
            await loadAll(force: true)
        } catch APIError.status(_, let msg) {
            flashToast(msg ?? "Couldn't convert right now.", isError: true)
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            // Unrecoverable session — route to the clean re-auth path
            // instead of an opaque retry-forever alert (mirrors Send).
            session.signOut()
        } catch {
            flashToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Wallet sweep (multi-coin "Convert all to USDsui")

    /// Dust threshold per leg, in raw u64 native units. Coins with less
    /// than this in their native decimals get filtered out so the sweep
    /// doesn't try to swap 0.0001 USDC ($0.0001) and bloat the PTB. The
    /// figure here approximates "$0.01-ish in any common decimals layout
    /// (6 / 9 / 9)" — server-side validation is the final arbiter; this
    /// is just a UX gate.
    private static let walletSweepDust: Double = 10_000

    /// Legs that will actually go into the sweep — everything non-USDsui
    /// with above-dust raw balance. Stable order so the confirmation
    /// message reads the same on repeat opens.
    private var walletSweepLegs: [WalletCoinBalance] {
        walletCoinBalances
            .filter { !$0.isUsdsui && $0.amountDouble > Self.walletSweepDust }
            .sorted(by: { $0.coinType < $1.coinType })
    }

    private var walletSweepEligible: Bool {
        !walletSweepLegs.isEmpty && !walletSweeping
    }

    /// Short symbol shown in the confirmation alert — we don't have a
    /// metadata service wired into Home yet, so we derive a best-effort
    /// label from the type tag's final `::Name` segment (e.g. `SUI`,
    /// `WAL`, `USDC`). Falls back to a truncated package id otherwise.
    private func walletSweepLegSymbol(_ b: WalletCoinBalance) -> String {
        let parts = b.coinType.split(separator: ":").map(String.init)
        // "0x...::module::Name" → "Name"
        if let last = parts.last, !last.isEmpty {
            return last.uppercased()
        }
        return String(b.coinType.suffix(6))
    }

    private func walletSweepConfirmationMessage() -> String {
        let legs = walletSweepLegs
        if legs.isEmpty {
            return "Nothing eligible to convert right now."
        }
        let pretty = legs.prefix(4).map(walletSweepLegSymbol).joined(separator: " + ")
        let more = legs.count > 4 ? " (+\(legs.count - 4) more)" : ""
        return "Will convert: \(pretty)\(more) → USDsui via Cetus. Onara pays the gas."
    }

    private func loadWalletCoinBalances() async {
        do {
            let resp = try await WalletAPI.balances()
            walletCoinBalances = resp.balances
        } catch {
            // Silent fallback — losing the enumeration only hides the
            // sweep CTA, doesn't break the home screen.
            if !APIError.isCancellation(error) {
                walletCoinBalances = []
            }
        }
    }

    private func executeWalletSweep() async {
        let legs = walletSweepLegs
        guard !legs.isEmpty else { return }
        walletSweeping = true
        defer { walletSweeping = false }

        do {
            // 1. Build the sweep payload from the legs we already
            //    enumerated — server is the final arbiter on validity
            //    (Cetus route existence, etc.), but pre-filtering here
            //    keeps the request small.
            let coins = legs.map {
                WalletSweepCoin(coinType: $0.coinType, amount: $0.amount)
            }
            let built = try await WalletAPI.sweep(coins: coins)

            // 2. Same sign+sponsor pipeline as every other PTB. Onara
            //    wraps these transaction-kind bytes into sponsored
            //    TransactionData, the ephemeral key signs the intent,
            //    /api/zk/sponsor-execute broadcasts.
            let intent = "Convert wallet to USDsui (\(legs.count) coin\(legs.count == 1 ? "" : "s"))"
            // Credit the 1 pt/$1 swap reward on the USDsui actually produced
            // (server-quoted, net of the 1% fee). 0 estimate → no points,
            // but the conversion still settles.
            let rewards = ZkLoginCoordinator.RewardsMeta(
                kind: "swap",
                amountUsd: built.estUsdOut
            )
            let result = try await ZkLoginCoordinator.shared.signAndSubmit(
                transactionKindB64: built.bytesB64,
                intent: intent,
                rewards: rewards
            )
            _ = result
            // Success → a transient toast, NOT a re-presented confirm sheet.
            flashToast("Converted to USDsui")
            await loadAll(force: true)
        } catch APIError.status(_, let msg) {
            flashToast(msg ?? "Couldn't convert right now.", isError: true)
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            // Unrecoverable session — clean re-auth (mirrors Send).
            session.signOut()
        } catch {
            flashToast(error.localizedDescription, isError: true)
        }
    }

    /// Convert a SINGLE coin to USDsui (the token-bucket per-coin swap, the
    /// successor to the archived auto-swap). Same sweep + sign+sponsor pipeline
    /// as `executeWalletSweep`, scoped to one coin. Returns true on success so
    /// the bucket can drop the row.
    private func swapSingleCoin(_ coin: WalletCoinBalance) async -> Bool {
        do {
            let built = try await WalletAPI.sweep(
                coins: [WalletSweepCoin(coinType: coin.coinType, amount: coin.amount)]
            )
            let intent = "Convert \(walletSweepLegSymbol(coin)) to USDsui"
            let rewards = ZkLoginCoordinator.RewardsMeta(kind: "swap", amountUsd: built.estUsdOut)
            _ = try await ZkLoginCoordinator.shared.signAndSubmit(
                transactionKindB64: built.bytesB64,
                intent: intent,
                rewards: rewards
            )
            flashToast("Converted to USDsui")
            await loadAll(force: true)
            return true
        } catch APIError.status(_, let msg) {
            flashToast(msg ?? "Couldn't convert right now.", isError: true)
            return false
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            session.signOut()
            return false
        } catch {
            flashToast(error.localizedDescription, isError: true)
            return false
        }
    }
}

/// Contacts sheet — pulls /api/contacts (counterparties from recent
/// on-chain activity). Tap a row to open Send with the recipient prefilled.
struct ContactsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [ContactDTO] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                MicroLabel(text: "Contacts", color: TaliseColor.fgDim).kerning(1.5)
                Text("People you've paid")
                    .font(TaliseFont.heading(22, weight: .medium))
                    .kerning(-0.8)
                    .foregroundStyle(TaliseColor.fg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if loading {
                        ForEach(0..<4, id: \.self) { _ in placeholderRow }
                    } else if contacts.isEmpty {
                        emptyState
                    } else {
                        ForEach(contacts) { contact in
                            contactRow(contact)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private var placeholderRow: some View {
        HStack(spacing: 12) {
            Circle().fill(TaliseColor.badgeNeutral).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(TaliseColor.line).frame(width: 120, height: 10)
                Capsule().fill(TaliseColor.line).frame(width: 80, height: 8)
            }
            Spacer()
        }
        .padding(14)
        .taliseGlass(cornerRadius: 16)
        .redacted(reason: .placeholder)
        .opacity(0.5)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            // Same brand contacts glyph as the navbar — at 36pt so it
            // reads as the empty-state hero. Faded via opacity since
            // the source PNG isn't a template asset (rendering intent
            // "original" preserves the design's tint).
            Image("ContactsGlyph")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .opacity(0.5)
                .padding(.top, 28)
            Text("No contacts yet")
                .font(TaliseFont.body(14, weight: .light))
                .foregroundStyle(TaliseColor.fg)
            Text("Anyone you send money to will appear here.")
                .font(TaliseFont.mono(10, weight: .light))
                .multilineTextAlignment(.center)
                .foregroundStyle(TaliseColor.fgDim)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }

    private func contactRow(_ c: ContactDTO) -> some View {
        Button {
            // Hand the address off to Send via UserDefaults bridge.
            UserDefaults.standard.set(c.address, forKey: "io.talise.send.prefillRecipient")
            dismiss()
            // Tiny delay so the sheet dismiss completes before the next
            // sheet presentation request fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                // Surface the Withdraw flow; the user can then tap
                // "Onchain Send" which inherits the prefilled
                // recipient via the UserDefaults bridge set above.
                NotificationCenter.default.post(
                    name: .taliseRequestWithdrawCover, object: nil
                )
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(TaliseColor.badgeNeutral).frame(width: 36, height: 36)
                    Text(initials(c))
                        .font(TaliseFont.heading(13, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.display)
                        .font(TaliseFont.body(14, weight: .light))
                        .foregroundStyle(TaliseColor.fg)
                        .lineLimit(1)
                    MicroLabel(text: "\(c.sentCount) sent · \(c.receivedCount) received", color: TaliseColor.fgDim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TaliseColor.fgDim)
            }
            .padding(14)
            .taliseGlass(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private func initials(_ c: ContactDTO) -> String {
        if let name = c.name, !name.isEmpty {
            return String(name.first!).uppercased()
        }
        // 0x address — show the first hex char after 0x.
        let idx = c.address.index(c.address.startIndex, offsetBy: min(2, c.address.count))
        return String(c.address[idx...].first.map(String.init) ?? "·").uppercased()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let r: ContactsResponse = try await APIClient.shared.get("/api/contacts")
            contacts = r.contacts
        } catch {
            contacts = []
        }
    }
}

extension Notification.Name {
    // Note: taliseRequestDepositCover + taliseRequestWithdrawCover are
    // declared in AppRoot.swift (mounted from MainTabView). The +/
    // paperplane buttons post those — no name lives here anymore.

    /// Posted by SendView / EarnView once a sponsored tx returns a
    /// digest. HomeView listens, prepends an optimistic row, and
    /// kicks off a delayed real refresh so the UI stays accurate even
    /// while the Sui fullnode propagation lags by a second or two.
    static let taliseTxCompleted = Notification.Name("io.talise.txCompleted")

    /// Posted by MainTabView when a money cover (send / deposit / withdraw /
    /// cross-border) dismisses, so Home re-pulls balance + activity the moment
    /// it's visible again — not just on the post-tx optimistic reconcile.
    static let taliseHomeShouldRefresh = Notification.Name("io.talise.homeShouldRefresh")
}

/// Payload for `.taliseTxCompleted`. Built from the data the sender
/// already has on hand — no extra chain round-trip needed to populate
/// the optimistic row.
struct TaliseTxEvent {
    let digest: String
    /// "sent" | "invest" | "withdraw" — matches ActivityEntryDTO.direction.
    let direction: String
    /// Positive USDsui units the user moved. Always positive — the
    /// direction field determines the sign in the UI.
    let amountUsdsui: Double
    /// For sends: recipient address. For invest/withdraw: nil (the
    /// counterparty is a pool, no address to show).
    let counterparty: String?
    let counterpartyName: String?
    /// "deepbook" | "navi" — only set for invest/withdraw.
    let venue: String?
}

/// FLAT card treatment, local to the Home surface. A single solid
/// `TaliseColor.surface` fill on a continuous rounded rectangle — NO
/// material, blur, gradient wash, specular highlight, gradient stroke, or
/// drop shadow. Apple-system clean on the black canvas.
private struct HomeFlatCard: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(TaliseColor.surface))
            .clipShape(shape)
    }
}

private extension View {
    func flatCard(cornerRadius: CGFloat = 25) -> some View {
        modifier(HomeFlatCard(cornerRadius: cornerRadius))
    }
}

private struct TaliseLogoMark: View {
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let r: CGFloat = size.width * 0.22
            for i in 0..<4 {
                let angle = CGFloat(i) * .pi / 2
                var transform = CGAffineTransform(translationX: cx, y: cy)
                transform = transform.rotated(by: angle)
                transform = transform.translatedBy(x: 0, y: -size.height * 0.28)
                let rect = CGRect(
                    x: -r * 0.45, y: -r * 0.55,
                    width: r * 0.9, height: r * 1.15
                ).applying(transform)
                let path = Path(ellipseIn: rect)
                ctx.fill(path, with: .color(.white))
            }
        }
    }
}

/// Clean, on-brand "Swap to USDsui" confirmation — replaces the bare system
/// alert shown when a received non-USDsui coin can be converted. Mint accent,
/// gas-sponsored reassurance, the estimate copy passed in from Home.
private struct SwapToUsdsuiSheet: View {
    let title: String
    let message: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(TaliseColor.accent.opacity(0.14))
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(TaliseColor.accent)
            }
            .frame(width: 64, height: 64)
            .padding(.top, 28)

            Text(title)
                .font(TaliseFont.heading(22, weight: .medium))
                .kerning(-0.4)
                .foregroundStyle(TaliseColor.fg)
                .padding(.top, 16)

            Text(message)
                .font(TaliseFont.body(14, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 26)
                .padding(.top, 10)

            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold))
                Text("Sponsored — gas is on us").font(TaliseFont.mono(11, weight: .regular)).tracking(0.5)
            }
            .foregroundStyle(TaliseColor.accent)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(TaliseColor.accent.opacity(0.12)))
            .padding(.top, 18)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button {
                    dismiss()
                    onConfirm()
                } label: {
                    Text("Convert")
                        .font(TaliseFont.body(16, weight: .semibold))
                        .foregroundStyle(TaliseColor.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(TaliseColor.accent))
                }
                .buttonStyle(.plain)

                Button { dismiss() } label: {
                    Text("Not now")
                        .font(TaliseFont.body(15, weight: .medium))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background(TaliseColor.bg.ignoresSafeArea())
    }
}
