import SwiftUI

/// Pre-auth coordinator. State machine drives the post-launch flow:
///
///     splash → welcome → signIn → handlePicker → pinSetup → permissions → done
///
/// (The legacy `intro1/2/3` and `kycTier` cases are kept as source files
/// on disk in case we revive them, but they are no longer routed here.)
///
/// Persistence: every transition writes the current step to UserDefaults
/// under `talise.onboarding.currentStep`. On launch, if `session.phase`
/// is `.onboarding(...)` AND a saved step exists, we jump straight to
/// it so the user resumes where they left off. The key is cleared on
/// `done`.
///
/// Progress bar mount: each new screen (`HandlePickerScreen`,
/// `PinSetupScreen`, `PermissionsScreen`) renders its own
/// `OnboardingProgressBar` so it can sit naturally above the title.
/// Sign-in is conceptually step 1 — `SignInScreen` does not currently
/// show the bar; we surface its "step 1" affordance here via an overlay
/// when `step == .signIn`. Two-pattern hybrid (per-screen for new
/// screens, overlay for the existing SignInScreen) was the lowest-risk
/// option since we deliberately left SignInScreen untouched.
enum OnboardingStep: String, Hashable {
    case splash
    case welcome
    case intro1
    case intro2
    case intro3
    case signIn
    /// Brief "Welcome back, <name>" interstitial shown when a sign-in
    /// resolves to an account that ALREADY completed onboarding
    /// (server returned accountType != nil). Auto-advances into the
    /// authenticated app — never persisted, never resumable.
    case welcomeBack
    case kycTier      // legacy — not in active flow
    case handlePicker
    case country
    case pinSetup
    case permissions
    case done
}

struct OnboardingRoot: View {
    @Environment(AppSession.self) private var session
    @State private var step: OnboardingStep
    @State private var signedInUser: UserDTO?

    private static let stepKey = "talise.onboarding.currentStep"

    init() {
        // Debug-only preview launch arg: -taliseOnboardingPreview <step>
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-taliseOnboardingPreview"),
           i + 1 < args.count,
           let preview = OnboardingStep(rawValue: args[i + 1]) {
            _step = State(initialValue: preview)
            return
        }
        #endif
        // Onboarding removed: the app opens STRAIGHT on "Sign in to Talise".
        // No splash/welcome carousel, no handle/PIN/permissions steps —
        // new users sign in and land in the app, then claim their @talise
        // name in-app from Home. [[sign-in-only-entry]]
        _step = State(initialValue: .signIn)
    }

    var body: some View {
        ZStack {
            TaliseColor.bg.ignoresSafeArea()

            Group {
                switch step {
                case .splash:
                    SplashView(onAdvance: { advance(to: .welcome) })
                        .transition(.opacity)
                case .welcome:
                    WelcomeView(
                        onContinue: { advance(to: .signIn) },
                        onSignIn: { advance(to: .signIn) }
                    )
                    .transition(.opacity)
                case .intro1, .intro2, .intro3:
                    // Legacy carousel — not routed in the new flow but
                    // left in place so we can re-enable it without a
                    // refactor. Treat any landing here as a jump to
                    // signIn (defensive in case a stale persisted step
                    // arrives from an old build).
                    BrandIntroCarousel(
                        selection: Binding(
                            get: { step },
                            set: { newStep in advance(to: newStep) }
                        ),
                        onContinue: { advance(to: .signIn) }
                    )
                    .transition(.slide)
                case .signIn:
                    // The Welcome / sign-in step deliberately shows NO
                    // progress bar — the segmented dashes belong only to the
                    // real new-user onboarding (handle picker / PIN /
                    // permissions), each of which renders its own bar. A
                    // returning user signs straight in and never sees them.
                    SignInScreen(onSignedIn: { user, existing in
                        signedInUser = user
                        // Returning users: the backend already knows
                        // the account is set up (accountType != nil →
                        // same signal AppSession uses everywhere). Sign
                        // them STRAIGHT into the app instead of walking
                        // the create-handle / PIN / permissions steps —
                        // this also covers a returning user who tapped
                        // "Get Started" instead of "I have an account".
                        // A genuinely new Google account has
                        // accountType == nil, so it still falls into
                        // the full onboarding flow below. (A returning-
                        // but-never-onboarded row — `existing == true`,
                        // accountType nil — also re-enters onboarding:
                        // it never picked a handle or PIN.)
                        // Onboarding removed — EVERY successful sign-in goes
                        // straight into the app. Returning users get the brief
                        // "Welcome back" beat; everyone else (incl. brand-new
                        // accounts) hands off immediately. New users claim their
                        // @talise name in-app from Home, not in a flow here.
                        UserDefaults.standard.removeObject(forKey: Self.stepKey)
                        if existing && user.accountType != nil {
                            advance(to: .welcomeBack)
                        } else {
                            session.handleSignedIn(user: user)
                        }
                    })
                    .transition(.slide)
                case .welcomeBack:
                    WelcomeBackInterstitial(
                        name: signedInUser?.name,
                        onFinished: { finish() }
                    )
                    .transition(.opacity)
                case .kycTier:
                    // Legacy — defensive jump to the new flow if hit.
                    KycTierPicker(onFreeChosen: { advance(to: .handlePicker) })
                        .transition(.slide)
                case .handlePicker:
                    HandlePickerScreen(onContinue: { _ in
                        advance(to: .pinSetup)
                    })
                    .transition(.slide)
                case .country:
                    // Retired: country is collected (with account type) by
                    // KYCView in the .onboarding phase — a separate step here
                    // double-prompted. Kept in the enum for back-compat with a
                    // persisted step; route any stragglers forward.
                    PinSetupScreen(userId: pinUserId, onContinue: { advance(to: .permissions) })
                        .transition(.slide)
                case .pinSetup:
                    PinSetupScreen(
                        userId: pinUserId,
                        onContinue: { advance(to: .permissions) }
                    )
                    .transition(.slide)
                case .permissions:
                    PermissionsScreen(onContinue: { handleFlowComplete() })
                        .transition(.slide)
                case .done:
                    OnboardingCompletedView(onDismiss: { finish() })
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.32), value: step)
        }
        .onAppear { resumeIfNeeded() }
    }

    // MARK: - Transitions

    private func advance(to next: OnboardingStep) {
        withAnimation(.easeInOut(duration: 0.32)) {
            step = next
        }
        persist(step: next)
    }

    private func persist(step: OnboardingStep) {
        switch step {
        case .done, .splash, .welcomeBack:
            // welcomeBack is a transient beat for an ALREADY-onboarded
            // account — resuming into it after a relaunch would strand
            // the user, so it's never written.
            UserDefaults.standard.removeObject(forKey: Self.stepKey)
        default:
            UserDefaults.standard.set(step.rawValue, forKey: Self.stepKey)
        }
    }

    /// On first appear, resume mid-flow if the user backgrounded the
    /// app during onboarding. We only resume when AppSession says
    /// we're still in the onboarding phase — otherwise we run the
    /// normal splash → welcome opening.
    private func resumeIfNeeded() {
        guard case .onboarding = session.phase else { return }
        guard let raw = UserDefaults.standard.string(forKey: Self.stepKey),
              let saved = OnboardingStep(rawValue: raw) else { return }
        // Never resume into splash/welcome (start clean).
        switch saved {
        case .handlePicker, .pinSetup, .permissions, .done:
            step = saved
        default:
            break
        }
    }

    // MARK: - Completion

    private func handleFlowComplete() {
        // Mirror the legacy kyc-tier behaviour: stamp a free tier
        // locally and post the completion notification so the rest of
        // the app can react.
        UserDefaults.standard.set("free", forKey: "talise.kyc_tier")
        NotificationCenter.default.post(
            name: Notification.Name("io.talise.onboardingCompleted"),
            object: nil
        )
        advance(to: .done)
    }

    private func finish() {
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        if let user = signedInUser {
            session.handleSignedIn(user: user)
        } else {
            Task { await session.bootstrap() }
        }
    }

    // MARK: - Helpers

    /// The id PinService keys against. Prefer the signed-in user; fall
    /// back to whatever AppSession holds (rare — defensive).
    private var pinUserId: String {
        signedInUser?.id ?? session.currentUser?.id ?? ""
    }
}

/// Brief "Welcome back, <name>" beat shown between a returning user's
/// sign-in and Home. Auto-advances after ~1.4s (or on tap, for the
/// impatient). Lives in this file rather than its own — the old-style
/// Xcode project requires pbxproj surgery for new Swift files.
private struct WelcomeBackInterstitial: View {
    /// Full display name from the server user record; we greet with the
    /// first word ("Eromonsele Odigie" → "Eromonsele").
    let name: String?
    let onFinished: () -> Void

    @State private var appeared = false
    @State private var finished = false

    private func kern(_ size: CGFloat) -> CGFloat { -size * 0.03 }

    private var firstName: String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              let first = name.split(separator: " ").first,
              !first.isEmpty else { return nil }
        return String(first)
    }

    var body: some View {
        ZStack {
            OnboardingBackground()

            VStack(spacing: 0) {
                Spacer()

                logoMark
                    .frame(width: 96, height: 96)
                    .scaleEffect(appeared ? 1 : 0.85)

                Text(firstName.map { "Welcome back, \($0)" } ?? "Welcome back")
                    .font(TaliseFont.heading(26, weight: .semibold))
                    .kerning(kern(26))
                    .foregroundStyle(TaliseColor.fg)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)
                    .padding(.horizontal, 32)

                Text("Taking you to your money.")
                    .font(TaliseFont.body(14, weight: .light))
                    .kerning(kern(14))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .padding(.top, 10)

                Spacer()
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
        }
        .contentShape(Rectangle())
        .onTapGesture { complete() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            complete()
        }
    }

    /// Idempotent — the tap-to-skip and the timed auto-advance can race.
    private func complete() {
        guard !finished else { return }
        finished = true
        onFinished()
    }

    @ViewBuilder
    private var logoMark: some View {
        if UIImage(named: "TaliseLogo") != nil {
            Image("TaliseLogo")
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(TaliseColor.fg)
        }
    }
}
