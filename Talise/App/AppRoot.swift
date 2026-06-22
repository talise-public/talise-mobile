import SwiftUI

/// Top-level coordinator. Switches between sign-in, KYC, and the
/// authenticated tab bar depending on `AppSession.phase`.
struct AppRoot: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Group {
            switch session.phase {
            case .launching:
                LaunchView()
            case .signedOut:
                // Plan 10 onboarding: splash → welcome → 3-slide brand
                // intro → Continue with Google → KYC tier picker → ready.
                // `SignInView` is reached internally by `SignInScreen`.
                OnboardingRoot()
            case .onboarding(let user):
                KYCView(user: user)
            case .ready:
                MainTabView()
            case .locked:
                LaunchView()
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
        .onAppear {
            // Wire the PinGate's user-id resolver to the current session.
            // PinGateHost itself is mounted per-flow (SendFlowView /
            // EarnView / VaultWithdrawSheet) so its `.sheet` runs in the
            // same presentation context as the flow that triggered it
            // — AppRoot can't present a sheet behind an active
            // fullScreenCover (e.g. Send), which is what was queueing
            // the PIN sheet.
            PinGate.shared.userIdProvider = { [weak session] in
                session?.currentUser?.id
            }
        }
        .task(id: phaseKey) {
            // Prewarm the broadcast-endpoint cache so the first
            // direct-broadcast send doesn't pay the ~100ms config-fetch
            // latency on the critical path. Only burn the request once
            // the session is .ready — earlier phases don't have a
            // bearer + App Attest token, so the prewarm would 401 and
            // we'd cache nothing anyway. Detached + unawaited: we
            // genuinely don't care when it finishes, only that the
            // round-trip starts before the user taps Send.
            guard case .ready = session.phase else { return }
            Task.detached {
                _ = await BroadcastConfigCache.current()
            }
        }
    }

    private var phaseKey: String {
        switch session.phase {
        case .launching: return "launching"
        case .signedOut: return "signedOut"
        case .onboarding(let user): return "onboarding-\(user.id)"
        case .ready: return "ready"
        case .locked: return "locked"
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            TaliseColor.bg.ignoresSafeArea()
            Text("Talise")
                .font(TaliseFont.heading(28))
                .foregroundStyle(TaliseColor.fg)
        }
    }
}

/// Five-tab pill nav. Home, Invest, **Chat**, Rewards, Profile — Send and
/// Receive live as actions on Home, not as nav destinations. The Chat tab
/// hosts the AI finance assistant (Plan 12, `/api/chat/stream` backend).
struct MainTabView: View {
    // Chat tab removed from the user-facing nav. The ChatTabView is
    // kept in the codebase so we can re-add the slot once the agent
    // UX (Payment-Intent confirm cards, voice input, deeper grounding)
    // is ready — but it shouldn't ship to users half-baked.
    enum Tab: Hashable { case home, invest, rewards, profile }
    @Environment(AppSession.self) private var session
    @State private var tab: Tab = .home
    @State private var depositCoverVisible = false
    @State private var withdrawCoverVisible = false
    @State private var sendCoverVisible = false
    @State private var crossBorderCoverVisible = false
    @State private var claimSheetVisible = false
    @State private var chequeWriteCoverVisible = false
    @State private var chequeClaimCoverVisible = false
    /// Cheque link from a deep link (talise://c/… or universal link), passed
    /// into ChequeClaimView so it auto-opens the cheque.
    @State private var pendingChequeClaimLink: String?
    @State private var myChequesCoverVisible = false
    @State private var streamCoverVisible = false
    @State private var myStreamsCoverVisible = false
    @State private var invoicesCoverVisible = false
    @State private var contractsCoverVisible = false

    /// True whenever ANY sheet/cover is being presented over the tab
    /// content. Drives the blur applied to the underlying tab.
    private var anySheetUp: Bool {
        depositCoverVisible || withdrawCoverVisible || sendCoverVisible
            || crossBorderCoverVisible || claimSheetVisible
            || chequeWriteCoverVisible || chequeClaimCoverVisible
            || myChequesCoverVisible || streamCoverVisible || myStreamsCoverVisible
            || invoicesCoverVisible || contractsCoverVisible
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TaliseColor.bg.ignoresSafeArea()

            Group {
                switch tab {
                case .home: HomeView()
                case .invest: EarnView()
                case .rewards: RewardsView()
                case .profile: ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .blur(radius: anySheetUp ? 14 : 0)
            .animation(.easeInOut(duration: 0.22), value: anySheetUp)
            .allowsHitTesting(!anySheetUp)

            BottomNavPill(active: $tab)
                .padding(.horizontal, 24)
                .padding(.bottom, 6)
                .blur(radius: anySheetUp ? 14 : 0)
                .animation(.easeInOut(duration: 0.22), value: anySheetUp)
        }
        // Deposit and Withdraw are full-page flows with their own
        // internal NavigationStack so sub-pages PUSH from the trailing
        // edge instead of slide up. `.fullScreenCover` is the only
        // initial bottom-up motion; everything beyond it is a normal
        // push.
        .fullScreenCover(isPresented: $depositCoverVisible) {
            DepositFlowView(onClose: { depositCoverVisible = false })
        }
        .fullScreenCover(isPresented: $withdrawCoverVisible) {
            WithdrawFlowView(onClose: { withdrawCoverVisible = false })
        }
        // "Onchain Send" inside the Withdraw flow dismisses the
        // Withdraw cover and posts `.taliseRequestSendCover`, which we
        // catch here. Hosting Send as its OWN cover (not embedded
        // inside the Withdraw NavigationStack) preserves the working
        // multi-step amount → recipient → review → sending → complete
        // path — embedding it caused nav-stack nesting issues.
        .fullScreenCover(isPresented: $sendCoverVisible) {
            SendView(onDone: { sendCoverVisible = false })
        }
        // Cross-border send — a distinct rail that lives alongside the
        // same-currency Onchain Send. Its own cover so the multi-step
        // NavigationStack inside CrossBorderFlowView doesn't nest.
        .fullScreenCover(isPresented: $crossBorderCoverVisible) {
            CrossBorderFlowView(onDone: { crossBorderCoverVisible = false })
        }
        .sheet(isPresented: $claimSheetVisible) {
            ClaimHandleSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(TaliseColor.bg)
        }
        .fullScreenCover(isPresented: $chequeWriteCoverVisible) {
            ChequeWriteView(onDone: { chequeWriteCoverVisible = false })
        }
        .fullScreenCover(isPresented: $chequeClaimCoverVisible) {
            ChequeClaimView(
                onDone: { chequeClaimCoverVisible = false },
                initialLink: pendingChequeClaimLink
            )
        }
        .fullScreenCover(isPresented: $myChequesCoverVisible) {
            MyChequesView(onDone: { myChequesCoverVisible = false })
        }
        .fullScreenCover(isPresented: $streamCoverVisible) {
            StreamSetupView(onDone: { streamCoverVisible = false })
        }
        .fullScreenCover(isPresented: $myStreamsCoverVisible) {
            StreamsListView(onDone: { myStreamsCoverVisible = false })
        }
        .fullScreenCover(isPresented: $invoicesCoverVisible) {
            InvoicesView(onDone: { invoicesCoverVisible = false })
        }
        .fullScreenCover(isPresented: $contractsCoverVisible) {
            ContractsView(onDone: { contractsCoverVisible = false })
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestDepositCover)) { _ in
            depositCoverVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestWithdrawCover)) { _ in
            withdrawCoverVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestSendCover)) { _ in
            sendCoverVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestCrossBorderCover)) { _ in
            crossBorderCoverVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestClaimSheet)) { _ in
            claimSheetVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestChequeWriteCover)) { _ in
            chequeWriteCoverVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestChequeClaimCover)) { note in
            // A deep link carries the cheque URL string in `object`; a manual
            // open (Withdraw hub) carries nil → the paste field shows instead.
            pendingChequeClaimLink = note.object as? String
            DeepLink.pendingChequeLink = nil // warm path consumed it
            chequeClaimCoverVisible = true
        }
        .task {
            // Cold launch via a cheque deep link: the notification fired
            // before this view existed, so replay the stashed link now.
            if let link = DeepLink.pendingChequeLink {
                DeepLink.pendingChequeLink = nil
                pendingChequeClaimLink = link
                chequeClaimCoverVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestMyChequesCover)) { _ in
            myChequesCoverVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestStreamCover)) { _ in
            streamCoverVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestMyStreamsCover)) { _ in
            myStreamsCoverVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestInvoicesCover)) { _ in
            invoicesCoverVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .taliseRequestContractsCover)) { _ in
            contractsCoverVisible = true
        }
        // When every cover/sheet has closed (the user is back on a bare tab,
        // typically Home after a send/deposit/withdraw), nudge Home to re-pull
        // balance + activity so the figure is fresh the moment it's visible.
        .onChange(of: anySheetUp) { _, up in
            if !up {
                NotificationCenter.default.post(name: .taliseHomeShouldRefresh, object: nil)
            }
        }
        // Safety net for a session that lapses mid-use: a dead bearer on a read
        // (401) or a proof failure on signing posts .taliseSessionExpired, and
        // we sign out cleanly. (The primary freshness policy lives in
        // AppSession: a fresh sign-in on every cold start + a 60s background
        // timeout, so the zkLogin proof is always recently minted.)
        .onReceive(NotificationCenter.default.publisher(for: .taliseSessionExpired)) { _ in
            if case .ready = session.phase { session.signOut() }
        }
    }
}

extension Notification.Name {
    /// Posted when the session is detected dead (401 on an authed read, or a
    /// rebind-required on signing). AppRoot observes it and signs out cleanly.
    static let taliseSessionExpired = Notification.Name("io.talise.sessionExpired")
    static let taliseRequestDepositCover = Notification.Name("io.talise.requestDepositCover")
    static let taliseRequestWithdrawCover = Notification.Name("io.talise.requestWithdrawCover")
    /// Direct-to-Send full cover. Used by the Withdraw flow's "Onchain
    /// Send" option (which dismisses itself then posts this) so the
    /// existing multi-step `SendView` runs as the root cover, not
    /// nested inside the Withdraw NavigationStack.
    static let taliseRequestSendCover = Notification.Name("io.talise.requestSendCover")
    /// Cross-border send full cover. Posted by the Withdraw flow's "Send
    /// abroad" option so the international rail (`CrossBorderFlowView`)
    /// runs as its own root cover, not nested inside another stack.
    static let taliseRequestCrossBorderCover = Notification.Name("io.talise.requestCrossBorderCover")
    static let taliseRequestClaimSheet = Notification.Name("io.talise.requestClaimSheet")
    /// Cheques + streaming entry points (posted from the Withdraw hub).
    static let taliseRequestChequeWriteCover = Notification.Name("io.talise.requestChequeWriteCover")
    static let taliseRequestChequeClaimCover = Notification.Name("io.talise.requestChequeClaimCover")
    /// "My cheques" list cover — the user's written cheques + reclaim.
    static let taliseRequestMyChequesCover = Notification.Name("io.talise.requestMyChequesCover")
    static let taliseRequestStreamCover = Notification.Name("io.talise.requestStreamCover")
    /// "My streams" list cover — the user's active streams + cancel.
    static let taliseRequestMyStreamsCover = Notification.Name("io.talise.requestMyStreamsCover")
    /// Work hub entry points (posted from the Withdraw hub): invoices + contracts.
    static let taliseRequestInvoicesCover = Notification.Name("io.talise.requestInvoicesCover")
    static let taliseRequestContractsCover = Notification.Name("io.talise.requestContractsCover")
}

/// Routes incoming deep links / universal links into the app.
///
/// Cheque links — `talise://c/<id>#<secret>` (custom scheme) or
/// `https://(www.)talise.io/c/<id>#<secret>` (universal link) — open the
/// in-app claim flow. We BOTH post the cover notification (warm case, the
/// tab UI is already mounted) AND stash `pendingChequeLink` so a COLD launch
/// (UI not mounted yet) can replay it once `MainTabView` appears.
enum DeepLink {
    /// Consumed by MainTabView on appear for the cold-launch case.
    static var pendingChequeLink: String?

    static func route(_ url: URL) {
        let isCheque: Bool
        if url.scheme == "talise" {
            isCheque = (url.host == "c")
        } else {
            isCheque = url.path.hasPrefix("/c/")
        }
        guard isCheque else { return }
        let link = url.absoluteString
        pendingChequeLink = link
        NotificationCenter.default.post(
            name: .taliseRequestChequeClaimCover, object: link
        )
    }
}

/// Floating pill nav with the Figma's "Glass" treatment.
///
/// Layering, outer → inner:
///  1. `.ultraThinMaterial` capsule — system glass blur backdrop.
///  2. A subtle dark tint on top of the material so it reads dark mode
///     (the system material alone is too neutral against a black bg).
///  3. Top + bottom hairlines for the refraction/edge feel from Figma:
///     top stroke is white-translucent (specular highlight); bottom is
///     a darker stroke to give the pill thickness.
///  4. Drop shadow under the whole pill for depth against the page bg.
///
/// The active tab gets its own smaller capsule with a stronger material
/// fill + white top hairline so it pops out of the pill — matches the
/// "Home" inset in the Figma reference.
private struct BottomNavPill: View {
    @Binding var active: MainTabView.Tab

    var body: some View {
        HStack(spacing: 4) {
            tabButton(.home, icon: "house.fill", label: "Home")
            tabButton(.invest, icon: "leaf.fill", label: "Invest")
            tabButton(.rewards, icon: "gift.fill", label: "Rewards")
            tabButton(.profile, icon: "person.crop.circle.fill", label: "Profile")
        }
        .padding(.horizontal, 6)
        .frame(height: 64)
        .background(
            // Flat solid pill — no blur. A clean raised bar on the page.
            Capsule().fill(TaliseColor.surfaceGlass)
        )
        .overlay(
            // One faint hairline to define the pill edge.
            Capsule().strokeBorder(TaliseColor.line, lineWidth: 1)
        )
        // A single soft shadow keeps the floating bar legible over content
        // without the old layered glass depth.
        .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 8)
    }

    private func tabButton(_ which: MainTabView.Tab, icon: String, label: String) -> some View {
        let isActive = active == which
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                active = which
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(TaliseColor.fg)
                Text(label)
                    .font(TaliseFont.body(10, weight: .regular))
                    .kerning(-0.36)
                    .foregroundStyle(TaliseColor.fg)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(activeBackdrop(isActive))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func activeBackdrop(_ isActive: Bool) -> some View {
        if isActive {
            ZStack {
                // Flat raised capsule for the active tab — a solid lighter
                // surface so it reads as "selected" without glass.
                Capsule().fill(TaliseColor.surfaceGlassStrong)
                Capsule().strokeBorder(TaliseColor.line, lineWidth: 1)
            }
            // Tiny inset so the active capsule clearly nests inside the
            // outer pill (the Figma effect). Horizontal inset matters
            // for the leading/trailing tabs — without it the active
            // capsule is flush with the outer pill's edge and reads
            // as misaligned against the centered icon + label.
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
        } else {
            Color.clear
        }
    }
}
