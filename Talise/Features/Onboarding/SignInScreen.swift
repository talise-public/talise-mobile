import SwiftUI
import AuthenticationServices

/// Continue-with-Google screen used as step 1 of the onboarding flow.
/// Sits over the shared `OnboardingBackground` so the green wash and
/// frosted bloom continue from the Welcome hero into auth and on to
/// the handle / PIN / permissions steps.
///
/// Reuses `ZkLoginCoordinator.shared.signIn()` — does NOT reimplement
/// auth. On success the resulting `UserDTO` is passed up to
/// `OnboardingRoot` so the rest of the onboarding flow can run.
struct SignInScreen: View {
    /// `(user, existing)` — `existing` is the server-asserted "this
    /// Google account already had a Talise row before this exchange"
    /// flag from the auth callback (false on older server deploys).
    let onSignedIn: (UserDTO, _ existing: Bool) -> Void
    @State private var signingIn = false
    @State private var signingInApple = false
    @State private var error: String?

    /// Either provider's flow is in flight — both CTAs disable together
    /// so the user can't run two OAuth dances at once.
    private var anySignInBusy: Bool { signingIn || signingInApple }

    /// True once the user has completed at least one successful sign-in on
    /// this device. Drives the "Welcome back" copy for returning users; a
    /// fresh install keeps the first-run "Welcome to Talise".
    private static let hasSignedInBeforeKey = "talise.hasSignedInBefore"
    private let returningUser = UserDefaults.standard.bool(forKey: hasSignedInBeforeKey)

    /// Letter-spacing helper — same `-size × 0.03` ratio used across
    /// the onboarding flow (matches the Figma "-0.705 ls @ 23.5pt"
    /// headline spec).
    private func kern(_ size: CGFloat) -> CGFloat { -size * 0.03 }

    var body: some View {
        ZStack {
            OnboardingBackground()

            VStack(spacing: 0) {
                // Top spacer — leaves room for the OnboardingRoot
                // progress-bar overlay (mounted by the coordinator
                // for this step).
                Spacer().frame(height: 70)

                Spacer()

                hero
                    .frame(width: 96, height: 96)

                Text(returningUser ? "Welcome back" : "Welcome to Talise")
                    .font(TaliseFont.heading(26, weight: .semibold))
                    .kerning(kern(26))
                    .foregroundStyle(TaliseColor.fg)
                    .padding(.top, 28)

                Text(returningUser
                     ? "Sign in to your Talise account."
                     : "One tap with Apple or Google.\nNo seed phrase, no setup.")
                    .font(TaliseFont.body(14, weight: .light))
                    .kerning(kern(14))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 32)

                Spacer()

                if let error {
                    Text(error)
                        .font(TaliseFont.body(12))
                        .kerning(kern(12))
                        .foregroundStyle(TaliseColor.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }

                // Provider CTAs — Apple first (HIG asks Sign in with
                // Apple to be at least as prominent as the others),
                // identical 54pt capsule footprint as Google below.
                VStack(spacing: 12) {
                    continueWithAppleButton
                    continueWithGoogleButton
                }
                .padding(.horizontal, 24)

                // Beta honesty — non-allowlisted testers hit an access
                // gate after sign-in, so say up front that the gate is
                // expected rather than letting it read as a broken app.
                Text("Talise is in private beta — access is invite-only.")
                    .font(TaliseFont.body(11, weight: .light))
                    .kerning(kern(11))
                    .foregroundStyle(TaliseColor.fgDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)

                Text("By continuing you agree to our Terms and Privacy.")
                    .font(TaliseFont.body(11, weight: .light))
                    .kerning(kern(11))
                    .foregroundStyle(TaliseColor.fgDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
            }
        }
    }

    // ── CTA ────────────────────────────────────────────────────────

    /// White capsule CTA matching the Welcome hero "Get Started"
    /// shape (54pt tall, capsule clip, white fill, bg text). The
    /// Google G mark sits inline-left of the title, ~20pt wide.
    private var continueWithGoogleButton: some View {
        Button {
            Task { await beginSignIn() }
        } label: {
            HStack(spacing: 10) {
                if signingIn {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(TaliseColor.bg)
                        .frame(width: 20, height: 20)
                } else {
                    Image("GoogleG")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                Text("Continue with Google")
                    .font(TaliseFont.body(15, weight: .medium))
                    .kerning(kern(15))
                    .foregroundStyle(TaliseColor.bg)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(TaliseColor.fg)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(anySignInBusy)
    }

    /// Sign in with Apple — a CUSTOM capsule, pixel-matched to the
    /// Google CTA (same 54pt height, white fill, 15pt medium label,
    /// 20pt leading mark). The system `SignInWithAppleButton` scales
    /// its label to the button height, which rendered comically large
    /// next to the Google button. Apple's HIG explicitly permits
    /// custom buttons that show the Apple logo with the standard
    /// title and adequate contrast — which this does — and the real
    /// auth runs through `ASAuthorizationController` in the
    /// coordinator either way.
    private var continueWithAppleButton: some View {
        Button {
            Task { await beginAppleSignIn() }
        } label: {
            HStack(spacing: 10) {
                if signingInApple {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(TaliseColor.bg)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(TaliseColor.bg)
                        .frame(width: 20, height: 20)
                }
                Text("Sign in with Apple")
                    .font(TaliseFont.body(15, weight: .medium))
                    .kerning(kern(15))
                    .foregroundStyle(TaliseColor.bg)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(TaliseColor.fg)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with Apple")
        .disabled(anySignInBusy)
    }

    // ── Hero (Talise pinwheel) ─────────────────────────────────────

    @ViewBuilder
    private var hero: some View {
        if UIImage(named: "TaliseLogo") != nil {
            Image("TaliseLogo")
                .resizable()
                .scaledToFit()
        } else {
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height / 2
                let r: CGFloat = size.width * 0.22
                for i in 0..<4 {
                    let angle = CGFloat(i) * .pi / 2
                    var t = CGAffineTransform(translationX: cx, y: cy)
                    t = t.rotated(by: angle)
                    t = t.translatedBy(x: 0, y: -size.height * 0.28)
                    let rect = CGRect(
                        x: -r * 0.45, y: -r * 0.55,
                        width: r * 0.9, height: r * 1.15
                    ).applying(t)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white))
                }
            }
        }
    }

    private func beginSignIn() async {
        signingIn = true
        error = nil
        defer { signingIn = false }
        do {
            let result = try await ZkLoginCoordinator.shared.signIn()
            // Remember this device has signed in at least once so the next
            // visit greets returning users with "Welcome back".
            UserDefaults.standard.set(true, forKey: Self.hasSignedInBeforeKey)
            onSignedIn(result.user, result.existing)
        } catch GoogleSignInService.SignInError.cancelled {
            // Quiet — the user explicitly backed out of the OAuth sheet.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func beginAppleSignIn() async {
        signingInApple = true
        error = nil
        defer { signingInApple = false }
        do {
            let result = try await ZkLoginCoordinator.shared.signInWithApple()
            UserDefaults.standard.set(true, forKey: Self.hasSignedInBeforeKey)
            onSignedIn(result.user, result.existing)
        } catch GoogleSignInService.SignInError.cancelled {
            // Quiet — the user dismissed the Apple sheet.
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// The leading icon on the "Continue with Google" CTA uses the real
// Google "G" mark from the asset catalog (`Image("GoogleG")`), per
// Google's sign-in branding guidelines.
