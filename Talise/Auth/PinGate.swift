import Foundation
import SwiftUI

/// Drop-in replacement for `BiometricGate.shared.requireUserPresence` that
/// asks for the user's 4-digit PIN instead of Face ID / Touch ID. The flow:
///
///   - If the signed-in user has no PIN yet, the sheet runs in **create**
///     mode: pick 4 digits, confirm, then continue.
///   - If they do have one, the sheet runs in **verify** mode: 4 digits
///     match → continue; mismatch → shake + clear.
///   - Tapping **Forgot PIN** clears the stored PIN and signs the user
///     out so they re-auth and set a fresh one on the next attempt.
///
/// The gate exposes an async API that pretends to be modal, but the actual
/// UI is mounted once at the app root via `PinGateHost`. Any call site
/// can `try await PinGate.shared.requireUserPresence(reason:userId:)` and
/// the framework wires the sheet presentation + dismissal through the
/// observable `activeRequest` state.
@MainActor
@Observable
final class PinGate {
    static let shared = PinGate()
    private init() {}

    enum Mode: Equatable {
        /// First-time set: ask twice, the second must match the first.
        case create
        /// Existing PIN: single 4-digit verify.
        case verify
    }

    struct ActiveRequest: Identifiable {
        let id = UUID()
        let userId: String
        let reason: String
        let mode: Mode
        let onSuccess: () -> Void
        let onCancel: () -> Void
        let onForgot: () -> Void
    }

    /// Observed by `PinGateHost`. When non-nil, the sheet is shown.
    var activeRequest: ActiveRequest?

    /// Wired once at AppRoot — resolves the currently signed-in user id
    /// for keying per-user PIN storage. Set to a closure returning
    /// `AppSession.currentUser?.id`.
    var userIdProvider: (() -> String?)?

    /// Prompts the user for their PIN (or sets one on first run). Returns
    /// normally on success. Throws:
    ///   - `PinError.cancelled` if the user swipes the sheet away.
    ///   - `PinError.forgotSignOut` if they tap "Forgot PIN". The caller
    ///     should treat this as a hard sign-out signal.
    func requireUserPresence(reason: String) async throws {
        let userId = userIdProvider?() ?? ""
        guard !userId.isEmpty else { throw PinError.missingUser }
        let mode: Mode = PinService.shared.hasPin(userId: userId) ? .verify : .create
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.activeRequest = ActiveRequest(
                userId: userId,
                reason: reason,
                mode: mode,
                onSuccess: { [weak self] in
                    self?.activeRequest = nil
                    cont.resume()
                },
                onCancel: { [weak self] in
                    self?.activeRequest = nil
                    cont.resume(throwing: PinError.cancelled)
                },
                onForgot: { [weak self] in
                    PinService.shared.clearPin(userId: userId)
                    self?.activeRequest = nil
                    cont.resume(throwing: PinError.forgotSignOut)
                }
            )
        }
    }
}

/// View modifier that mounts the PIN sheet once at the app root. Any
/// `PinGate.shared.requireUserPresence(...)` call surfaces here.
struct PinGateHost: ViewModifier {
    @Bindable var gate = PinGate.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $gate.activeRequest) { req in
                PinEntrySheet(request: req)
                    .presentationDetents([.fraction(0.62)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(TaliseColor.bg)
                    .interactiveDismissDisabled(false)
            }
    }
}

extension View {
    /// Wrap once at the app root. Lets any deep view call
    /// `PinGate.shared.requireUserPresence(...)` and have the sheet
    /// surface here.
    func pinGateHost() -> some View { modifier(PinGateHost()) }
}
