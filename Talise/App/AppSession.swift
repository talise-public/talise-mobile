import Foundation
import SwiftUI

/// Single observable describing app-wide state. Read from views via
/// `@Environment(AppSession.self)`. Mutations happen through methods on
/// this type so we keep state transitions explicit.
@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        case launching
        case signedOut
        case onboarding(user: UserDTO)
        case ready(user: UserDTO)
        case locked
    }

    var phase: Phase = .launching
    var lastError: String?

    /// Convenience — current signed-in user, if any. Used by call sites
    /// that need the user id to key per-user state (e.g. PIN storage).
    var currentUser: UserDTO? {
        switch phase {
        case .onboarding(let u), .ready(let u): return u
        default: return nil
        }
    }

    /// Seconds the app may sit in the background before the session is dropped.
    /// Deliberately short: a new sign-in re-mints the zkLogin proof with a fresh
    /// `maxEpoch`, so the proof can never be used past its window ("ZKLogin
    /// expired at epoch …"). 60s, matching the product requirement.
    private let backgroundGraceSeconds: TimeInterval = 60
    private var backgroundedAt: Date?

    func bootstrap() async {
        // SESSION-FRESHNESS POLICY (2026-06-22): every COLD START requires a
        // fresh sign-in. We deliberately do NOT restore a persisted session.
        // A new sign-in re-mints the zkLogin proof (new JWT nonce → new
        // maxEpoch), so a send can never fail with "ZKLogin expired at epoch …"
        // from a proof left over across an app quit. Clear anything a previous
        // run persisted and land on the sign-in screen.
        clearSession()
        phase = .signedOut
    }

    /// Called when the app is fully backgrounded (the user left it). Arms the
    /// inactivity timer only when there's a live session to drop.
    func appDidEnterBackground() {
        backgroundedAt = (currentUser == nil) ? nil : Date()
    }

    /// Called when the app returns to the foreground. If it sat in the
    /// background past the grace window, drop the session so the user signs in
    /// again (and gets a fresh proof). Quick app-switches stay signed in.
    func appWillEnterForeground() {
        guard let since = backgroundedAt else { return }
        backgroundedAt = nil
        if currentUser != nil,
           Date().timeIntervalSince(since) >= backgroundGraceSeconds {
            signOut()
        }
    }

    func signOut() {
        clearSession()
        phase = .signedOut
    }

    /// Wipe every persisted credential: cached user snapshot, bearer, ephemeral
    /// key, and zkLogin proof. The shield note master is intentionally left
    /// alone — it lives in the iCloud Keychain + server escrow and is restored
    /// on the next sign-in, so a signed-out user never loses private funds.
    private func clearSession() {
        if let uid = currentUser?.id {
            LocalSnapshotStore.clear(userId: uid)
        }
        UserDefaults.standard.removeObject(forKey: "io.talise.snapshot.lastUserId")
        SecureSessionStore.shared.clear()
        EphemeralKeyStore.shared.wipe()
        ProofCache.shared.clear()
        backgroundedAt = nil
    }

    /// Called by SignInView after ZkLoginCoordinator.signIn() returns.
    func handleSignedIn(user: UserDTO) {
        LocalSnapshotStore.saveUser(user)
        UserDefaults.standard.set(user.id, forKey: "io.talise.snapshot.lastUserId")
        if user.accountType == nil {
            phase = .onboarding(user: user)
        } else {
            phase = .ready(user: user)
        }
    }
}
