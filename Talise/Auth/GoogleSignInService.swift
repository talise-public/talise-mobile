import Foundation
import AuthenticationServices
import UIKit

/// Google OAuth via the Talise backend's web OAuth client.
///
/// Why this is server-mediated instead of direct PKCE: zkLogin derives
/// the Sui address from the JWT's (iss, aud, sub) tuple via Shinami's
/// salt service. If the iOS app uses its own OAuth client (with its
/// own client_id, ie its own `aud` claim), Shinami returns a different
/// wallet than the web product does for the same Google account. The
/// user signs in on web and iOS with the same email and gets two
/// different Sui addresses — confusing and breaks send-to-self flows.
///
/// To unify: open `${apiBase}/api/auth/mobile/start` in an
/// ASWebAuthenticationSession. The backend runs OAuth against the
/// existing WEB client_id + secret, /auth/callback recognizes the
/// `m1.*` state prefix, mints a mobile bearer, and redirects to
/// `talise://auth/callback?token=…&userId=…`. The JWT's `aud` is
/// GOOGLE_CLIENT_ID (web), so Shinami returns the canonical web
/// wallet — same address as web sign-ins.
@MainActor
final class GoogleSignInService: NSObject, ASWebAuthenticationPresentationContextProviding {

    struct Result {
        let bearer: String
        let userId: String
        /// Server-asserted "this Google account already had a Talise user
        /// row before this exchange" flag, carried on the talise://
        /// callback as `existing=1`. Defaults to false when the server
        /// doesn't send the param (older deploys) — routing must never
        /// REQUIRE it, only enhance (e.g. the welcome-back moment).
        let existingAccount: Bool
    }

    enum SignInError: LocalizedError {
        case cancelled
        case configMissing
        case malformedRedirect
        case oauth(String)
        /// Apple-flow failure (shared error enum so both providers'
        /// UIs catch the SAME `.cancelled` case for quiet dismissal).
        case apple(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in was cancelled."
            case .configMissing: return "Backend URL is not configured."
            case .malformedRedirect: return "Sign-in redirect was malformed."
            case .oauth(let s): return "Google: \(s)"
            case .apple(let s): return "Apple: \(s)"
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    /// `ephemeralPubKeyB64` is the device's Curve25519 ephemeral public
    /// key. The backend binds it to the OAuth state so a hostile
    /// redirect can't swap in a different key.
    ///
    /// Sent as base64URL (RFC 4648 §5) rather than standard base64.
    /// Standard base64 contains `+`, which travels through a URL
    /// query string just fine but gets decoded back to a SPACE by
    /// Next.js's URLSearchParams — corrupting the bytes server-side.
    /// base64URL uses `-` and `_` instead, which survive any URL
    /// parser cleanly.
    func signIn(ephemeralPubKeyB64: String) async throws -> Result {
        let base = AppConfig.shared.apiBaseURL
        guard !base.isEmpty else { throw SignInError.configMissing }

        let urlSafe = ephemeralPubKeyB64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var components = URLComponents(string: base + "/api/auth/mobile/start")!
        components.queryItems = [
            URLQueryItem(name: "ephemeralPubKey", value: urlSafe),
        ]
        guard let startURL = components.url else {
            throw SignInError.configMissing
        }

        return try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: startURL,
                callbackURLScheme: "talise"
            ) { callbackURL, error in
                if let error {
                    let ns = error as NSError
                    if ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        cont.resume(throwing: SignInError.cancelled)
                    } else {
                        cont.resume(throwing: SignInError.oauth(error.localizedDescription))
                    }
                    return
                }
                guard let callbackURL else {
                    cont.resume(throwing: SignInError.malformedRedirect)
                    return
                }
                let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems ?? []
                let pairs = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                if let err = pairs["err"] ?? pairs["error"], !err.isEmpty {
                    cont.resume(throwing: SignInError.oauth(err))
                    return
                }
                guard let bearer = pairs["token"], !bearer.isEmpty,
                      let userId = pairs["userId"], !userId.isEmpty else {
                    cont.resume(throwing: SignInError.malformedRedirect)
                    return
                }
                cont.resume(returning: Result(
                    bearer: bearer,
                    userId: userId,
                    existingAccount: pairs["existing"] == "1"
                ))
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

/// Native Sign in with Apple.
///
/// Unlike the Google flow above, there is NO web session: Apple sign-in
/// runs the system `ASAuthorizationController` sheet and hands back the
/// identity token (a JWT signed by Apple) directly on-device. The
/// zkLogin nonce is set on the request — Apple embeds it VERBATIM into
/// the JWT's `nonce` claim, which is what lets the prover later verify
///
///     jwt.nonce == poseidonHash(extendedEphemeralPublicKey,
///                               maxEpoch, jwtRandomness)
///
/// exactly like the Google path (where /api/auth/mobile/start sets the
/// same nonce on the Google OAuth request).
///
/// Lives in this file rather than its own — the old-style Xcode project
/// requires pbxproj surgery for new Swift files.
@MainActor
final class AppleSignInService: NSObject {

    private var continuation: CheckedContinuation<String, Error>?
    /// Keeps the in-flight controller alive until a delegate callback
    /// fires — ASAuthorizationController is not retained by the system.
    private var controller: ASAuthorizationController?

    /// Presents the system Sign in with Apple sheet and returns the raw
    /// identity-token JWT string.
    ///
    /// `nonce` MUST be the zkLogin nonce — the Poseidon hash binding
    /// (ephemeralPubKey, maxEpoch, randomness) — passed as-is. Apple
    /// copies it verbatim into the id token's `nonce` claim (no
    /// hashing on our side; SHA-256-the-nonce is a Firebase-ism that
    /// would break the prover's equality check).
    func identityToken(nonce: String) async throws -> String {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }
}

extension AppleSignInService: ASAuthorizationControllerDelegate,
                              ASAuthorizationControllerPresentationContextProviding {

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        defer {
            continuation = nil
            self.controller = nil
        }
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty else {
            continuation?.resume(
                throwing: GoogleSignInService.SignInError.apple(
                    "no identity token in Apple credential"
                )
            )
            return
        }
        continuation?.resume(returning: token)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        defer {
            continuation = nil
            self.controller = nil
        }
        let ns = error as NSError
        if ns.domain == ASAuthorizationError.errorDomain,
           ns.code == ASAuthorizationError.canceled.rawValue {
            // Same quiet-cancel contract as the Google flow — the
            // sign-in screens catch GoogleSignInService.SignInError
            // .cancelled specifically and show no error toast.
            continuation?.resume(throwing: GoogleSignInService.SignInError.cancelled)
        } else {
            continuation?.resume(
                throwing: GoogleSignInService.SignInError.apple(error.localizedDescription)
            )
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
