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

    func bootstrap() async {
        guard SecureSessionStore.shared.hasToken() else {
            phase = .signedOut
            return
        }

        // --- Provisional ready (perceived-performance fast path) ---
        // If we have a cached UserDTO from a prior session, flip the
        // phase to .ready IMMEDIATELY so HomeView mounts with no network
        // wait. We then revalidate /api/me in the background and update
        // currentUser + the cache on success.
        //
        // We don't know the userId before we have the user object, so we
        // fall back to scanning UserDefaults by trying the stored bearer
        // identity. In practice we seed the userId from the last
        // successful /api/me response, stored keyed by "last_user_id".
        if let lastId = UserDefaults.standard.string(forKey: "io.talise.snapshot.lastUserId"),
           let cached = LocalSnapshotStore.loadUser(userId: lastId) {
            if cached.accountType == nil {
                phase = .onboarding(user: cached)
            } else {
                phase = .ready(user: cached)
                Task { await ZkLoginCoordinator.shared.ensureProofWarm() }
                Task { await CurrencySettings.shared.refresh() }
            }
            // Background revalidation — update the user object without
            // blocking the UI. Only sign out on a definitive 401; any
            // transport or timeout error keeps the cached session alive.
            let cachedUserId = lastId
            Task {
                do {
                    let me: UserDTO = try await APIClient.shared.get("/api/me")
                    LocalSnapshotStore.saveUser(me)
                    UserDefaults.standard.set(
                        me.id,
                        forKey: "io.talise.snapshot.lastUserId"
                    )
                    // Update the phase only if the account state changed
                    // (e.g. onboarding completed on another device).
                    if me.accountType == nil {
                        phase = .onboarding(user: me)
                    } else {
                        phase = .ready(user: me)
                    }
                } catch APIError.unauthorized {
                    // Definitive auth failure — clear everything and
                    // send the user to the sign-in screen.
                    LocalSnapshotStore.clear(userId: cachedUserId)
                    UserDefaults.standard.removeObject(
                        forKey: "io.talise.snapshot.lastUserId"
                    )
                    SecureSessionStore.shared.clear()
                    EphemeralKeyStore.shared.wipe()
                    ProofCache.shared.clear()
                    phase = .signedOut
                } catch {
                    // Transport / timeout — keep the cached session;
                    // the user stays on the home screen with stale data.
                    // The next pull-to-refresh will revalidate naturally.
                }
            }
            return
        }

        // --- First sign-in path (no cached user) — current behavior ---
        do {
            let me: UserDTO = try await APIClient.shared.get("/api/me")
            LocalSnapshotStore.saveUser(me)
            UserDefaults.standard.set(
                me.id,
                forKey: "io.talise.snapshot.lastUserId"
            )
            if me.accountType == nil {
                phase = .onboarding(user: me)
            } else {
                phase = .ready(user: me)
                // Returning users — their bearer survived but the
                // ProofCache might be cold (esp. if it predates the
                // Keychain persistence). Warm it in the background so
                // the first Send doesn't fail with "no proof cache".
                Task { await ZkLoginCoordinator.shared.ensureProofWarm() }
                // FX rates for the display-currency picker. Soft-fails
                // to USD-only if /api/fx is unreachable.
                Task { await CurrencySettings.shared.refresh() }
            }
        } catch APIError.unauthorized {
            SecureSessionStore.shared.clear()
            phase = .signedOut
        } catch {
            // No /me yet (404) or transient network issue — fall back to
            // signed-out rather than wedging launch. User can re-auth.
            SecureSessionStore.shared.clear()
            phase = .signedOut
        }
    }

    func signOut() {
        // Clear the snapshot cache for the departing user before wiping
        // the session so we still know who we're clearing.
        if let uid = currentUser?.id {
            LocalSnapshotStore.clear(userId: uid)
            UserDefaults.standard.removeObject(
                forKey: "io.talise.snapshot.lastUserId"
            )
        }
        SecureSessionStore.shared.clear()
        EphemeralKeyStore.shared.wipe()
        ProofCache.shared.clear()
        phase = .signedOut
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
