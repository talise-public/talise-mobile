import SwiftUI
import AuthenticationServices

struct SignInView: View {
    @Environment(AppSession.self) private var session
    @State private var signingIn = false
    @State private var signingInApple = false
    @State private var error: String?
    @State private var appeared = false

    private var anySignInBusy: Bool { signingIn || signingInApple }

    var body: some View {
        ZStack {
            // Flat near-black canvas. No bloom, no wash — the headline owns
            // the screen.
            TaliseColor.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: TaliseSpacing.xl) {
                Spacer()

                // Brand mark — small mono-cap eyebrow, sits quietly above
                // the hero so the headline owns the screen.
                HStack(spacing: 8) {
                    Circle()
                        .fill(TaliseColor.greenMint)
                        .frame(width: 8, height: 8)
                    Text("TALISE")
                        .font(TaliseFont.mono(11, weight: .regular))
                        .tracking(3.0)
                        .foregroundStyle(TaliseColor.fgMuted)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)

                // Big confident hero headline.
                Text("Send money\nacross the globe.\nIn seconds.")
                    .font(TaliseFont.display(40, weight: .medium))
                    .kerning(-1.2)
                    .foregroundStyle(TaliseColor.fg)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)

                Text("One Google account. One Sui address. No seed phrase, no setup. You sign with Face ID; we never see your keys.")
                    .font(TaliseFont.body(15))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, TaliseSpacing.xs)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)

                Spacer()

                VStack(spacing: TaliseSpacing.md) {
                    if let error {
                        Text(error)
                            .font(TaliseFont.body(12))
                            .foregroundStyle(TaliseColor.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }

                    // Sign in with Apple — CUSTOM button pixel-matched to
                    // the Google CTA below (same height/radius/type scale;
                    // the system SignInWithAppleButton scales its label to
                    // the button height and dwarfed the Google text). HIG
                    // permits custom buttons with the Apple logo + standard
                    // title; the real auth runs through
                    // ASAuthorizationController in the coordinator.
                    Button {
                        Task { await beginAppleSignIn() }
                    } label: {
                        HStack(spacing: 8) {
                            if signingInApple {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                                    .tint(.black)
                            } else {
                                Image(systemName: "apple.logo")
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(width: 18, height: 18)
                                Text("Sign in with Apple")
                                    .font(TaliseFont.heading(16, weight: .medium))
                            }
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white)
                        )
                        .opacity(signingInApple ? 0.85 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sign in with Apple")
                    .disabled(anySignInBusy)

                    // Flat solid primary CTA — green fill, dark ink, no glass.
                    Button {
                        Task { await beginSignIn() }
                    } label: {
                        HStack(spacing: 8) {
                            if signingIn {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                                    .tint(Color(hex: 0x0A140C))
                            } else {
                                Image("GoogleG")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                                Text("Continue with Google")
                                    .font(TaliseFont.heading(16, weight: .medium))
                            }
                        }
                        .foregroundStyle(Color(hex: 0x0A140C))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(TaliseColor.greenMint)
                        )
                        .opacity(signingIn ? 0.85 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .disabled(anySignInBusy)

                    // Beta honesty — non-allowlisted testers hit an access
                    // gate after sign-in; flag it up front so the gate
                    // reads as expected, not broken.
                    Text("Talise is in private beta — access is invite-only.")
                        .font(TaliseFont.body(11))
                        .foregroundStyle(TaliseColor.fgDim)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text("By continuing you agree to our Terms and Privacy.")
                        .font(TaliseFont.body(11))
                        .foregroundStyle(TaliseColor.fgDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 22)
                .padding(.bottom, TaliseSpacing.md)
            }
            .padding(.horizontal, TaliseSpacing.xl)
        }
        .animation(.easeOut(duration: 0.55), value: appeared)
        .animation(.easeOut(duration: 0.2), value: error)
        .onAppear { appeared = true }
    }

    private func beginSignIn() async {
        signingIn = true
        error = nil
        defer { signingIn = false }
        do {
            let result = try await ZkLoginCoordinator.shared.signIn()
            session.handleSignedIn(user: result.user)
        } catch GoogleSignInService.SignInError.cancelled {
            // user backed out — no error toast
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
            session.handleSignedIn(user: result.user)
        } catch GoogleSignInService.SignInError.cancelled {
            // user dismissed the Apple sheet — no error toast
        } catch {
            self.error = error.localizedDescription
        }
    }
}
