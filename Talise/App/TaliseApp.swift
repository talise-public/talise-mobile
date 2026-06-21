import SwiftUI
import CoreText
import UIKit
import UserNotifications
#if DEBUG
import ObjectiveC.runtime
#endif

@main
struct TaliseApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var session = AppSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = false

    init() {
        #if DEBUG
        // KeyboardInputWarningMitigation.install() — REMOVED (2026-05-29).
        // The swizzle tried to silence the benign
        // "assistantHeight == 72" UIKit constraint warning, but
        // method_exchangeImplementations on UITextField/UITextView's
        // inherited didMoveToWindow swapped the IMP on the UIView
        // Method object, which is shared with EVERY UIView subclass —
        // including UIKit's private UITransitionView. At app launch
        // when UIKit created a UITransitionView and called
        // didMoveToWindow, dispatch went into our taliseDidMoveToWindow
        // selector, which UITransitionView does not implement →
        // NSInvalidArgumentException → crash. The warning is benign and
        // documented in docs/ios-known-warnings.md; we'd rather see it
        // in the console than crash the app.
        // Silence URLSession's chatty CFNetwork / Network.framework
        // logs in dev builds — specifically the
        //   `nw_connection_copy_connected_local_endpoint_block_invoke
        //    [C2] Connection has no local endpoint`
        // and friends that fire on every cancelled task. They're
        // harmless but they drown out our own `print` statements in
        // the Xcode console. `OS_ACTIVITY_MODE=disable` mutes the
        // os_log stream that those frames are emitted into.
        //
        // setenv must run BEFORE URLSession is instantiated (i.e.
        // before APIClient.shared is touched) for the system loggers
        // to pick it up. App `init()` is the earliest hook we have.
        setenv("OS_ACTIVITY_MODE", "disable", 1)
        #endif

        Self.registerFonts()
        #if DEBUG
        // Cross-check our pure-Swift BLAKE2b-256 against @noble/hashes
        // vectors at launch. A mismatch on any vector means the iOS
        // digest is wrong → sponsor-execute will reject the signature
        // with "Invalid signature was given to the function". Logged
        // (not asserted) so the app still launches and a developer
        // can see exactly which vector diverged.
        let failures = Blake2b.runSelfTest()
        if failures.isEmpty {
            if AppConfig.shared.verboseConsoleLogging {
                print("[zk] Blake2b self-test: OK")
            }
        } else {
            print("[zk] Blake2b self-test FAILED — signing will reject on chain:")
            for f in failures { print("    \(f)") }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(session)
                .task { await session.bootstrap() }
                .overlay {
                    if locked {
                        AppLockOverlay()
                            .transition(.opacity)
                    }
                }
                .onOpenURL { url in
                    // talise://auth/callback is handled inside the
                    // ASWebAuthenticationSession completion. Here we route
                    // cheque deep links: talise://c/<id>#<secret>.
                    DeepLink.route(url)
                }
                // Universal links: https://(www.)talise.io/c/<id>#<secret>.
                // Same routing as the custom scheme.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { DeepLink.route(url) }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background, .inactive:
                        locked = true
                    case .active:
                        locked = false
                    @unknown default:
                        break
                    }
                }
                .onChange(of: session.phase) { _, newPhase in
                    // Register for push + sync the device token once the user
                    // is signed in, so /api/devices/register carries a bearer.
                    // Idempotent — safe to fire on every transition to ready.
                    if case .ready = newPhase {
                        PushRegistrar.shared.register()
                        PushRegistrar.shared.syncIfNeeded()
                    }
                }
        }
    }

    /// Registers DM Sans Variable (bundled at Resources/DMSans/) so
    /// `TaliseFont.displayFamily = "DM Sans"` resolves. If the .ttf is
    /// missing the call quietly no-ops and fonts fall back to SF Pro —
    /// useful in dev when the asset hasn't been pulled.
    private static func registerFonts() {
        let names = ["DMSans-Variable.ttf"]
        for name in names {
            let parts = name.split(separator: ".")
            guard parts.count == 2,
                  let url = Bundle.main.url(forResource: String(parts[0]), withExtension: String(parts[1])) else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// KeyboardInputWarningMitigation removed (2026-05-29). See the
// comment at the install() call site for the full rationale. The
// "assistantHeight == 72" warning is benign per
// docs/ios-known-warnings.md; the swizzle was crashing the app
// at launch because method_exchangeImplementations on an
// inherited Method swaps the IMP class-wide on UIView.

private struct AppLockOverlay: View {
    var body: some View {
        ZStack {
            TaliseColor.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(TaliseColor.fgDim)
                Text("Talise")
                    .font(TaliseFont.heading(20))
                    .foregroundStyle(TaliseColor.fg)
            }
        }
    }
}

// MARK: - Push notifications

/// Requests APNs authorization, registers for remote notifications, and syncs
/// the device token to the backend (`POST /api/devices/register`). Push
/// DELIVERY is server-gated on the Talise APNs credentials — this side just
/// gets permission, the token, and hands it to the server.
final class PushRegistrar {
    static let shared = PushRegistrar()
    private init() {}

    /// Latest APNs device token (hex), set by the app delegate callback.
    private(set) var lastToken: String?

    /// Request notification authorization (the system prompts only once) and
    /// register for remote notifications. Idempotent — safe to call on every
    /// transition to `.ready`.
    func register() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
    }

    /// Called from the app delegate when APNs hands us a token. Stores it and
    /// POSTs it (best-effort; APIClient attaches the bearer when signed in).
    func didReceive(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        lastToken = hex
        Task { await sync(token: hex) }
    }

    /// Re-POST the last-known token (e.g. right after sign-in completes, when
    /// a token captured pre-auth can finally be associated with the account).
    func syncIfNeeded() {
        guard let t = lastToken else { return }
        Task { await sync(token: t) }
    }

    private func sync(token: String) async {
        struct Body: Encodable { let token: String; let platform: String }
        struct Ack: Decodable { let ok: Bool? }
        do {
            let _: Ack = try await APIClient.shared.post(
                "/api/devices/register",
                body: Body(token: token, platform: "ios")
            )
        } catch {
            // Best-effort: a 401 before sign-in is expected; we re-sync on ready.
        }
    }
}

/// Minimal app delegate purely to receive the APNs device-token callbacks
/// (SwiftUI's App lifecycle doesn't surface them).
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistrar.shared.didReceive(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("[push] APNs registration failed: \(error.localizedDescription)")
        #endif
    }
}
