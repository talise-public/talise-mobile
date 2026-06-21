import Foundation
import LocalAuthentication

/// Single entry point for "the user must consent right now, on-device,
/// before we sign a fund-moving transaction." Wraps `LAContext` so the
/// call sites (`SendFlowView`, `EarnView` supply / withdraw,
/// `VaultWithdrawSheet`) all converge on the same policy and the same
/// error type.
///
/// We use `.deviceOwnerAuthentication` (not `.biometryAny`) so the
/// system gracefully falls back to passcode when Face ID / Touch ID
/// is unavailable or repeatedly fails. The goal is fresh user
/// presence, not biometric specifically.
///
/// No debug bypass: the audit (P0-3) explicitly forbids it.
@MainActor
final class BiometricGate {
    static let shared = BiometricGate()

    /// Public error type referenced by call sites. The legacy name
    /// `GateError` is preserved as a nested alias so existing pattern
    /// matches keep working.
    enum BiometricGateError: LocalizedError, Equatable {
        case cancelled
        case notAvailable(reason: String)
        case failed(underlying: String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Confirmation cancelled."
            case .notAvailable(let reason):
                return "Biometric confirmation unavailable: \(reason)"
            case .failed(let underlying):
                return "Couldn't confirm it's you: \(underlying)"
            }
        }

        static func == (lhs: BiometricGateError, rhs: BiometricGateError) -> Bool {
            switch (lhs, rhs) {
            case (.cancelled, .cancelled): return true
            case (.notAvailable(let a), .notAvailable(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    /// Legacy alias. Keeps `catch BiometricGate.GateError.userCancelled`
    /// style sites compiling if anyone wrote them; the new error type
    /// is `BiometricGateError`.
    typealias GateError = BiometricGateError

    /// Settings flag: user can opt out via Profile → Security. Default
    /// true. We store this in `UserDefaults` (Keychain isn't needed —
    /// a determined attacker who can rewrite this key has already won
    /// at the device level, and Settings → reinstall will reset it).
    static let requireKey = "biometric.required.for.transactions"
    /// One-time hint flag shown below the first confirmation CTA after
    /// sign-in, so the first system prompt isn't a surprise.
    static let hintShownKey = "biometric.hint.shown"

    static var isRequired: Bool {
        // Default true when the key has never been written. We compare
        // against the bool's presence by checking `object(forKey:)`.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: requireKey) == nil { return true }
        return defaults.bool(forKey: requireKey)
    }

    static func setRequired(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: requireKey)
    }

    static var hintShown: Bool {
        UserDefaults.standard.bool(forKey: hintShownKey)
    }

    static func markHintShown() {
        UserDefaults.standard.set(true, forKey: hintShownKey)
    }

    private init() {}

    /// Returns a human-readable name for the strongest auth method
    /// currently available. Used by CTAs that want to read "Confirm
    /// with Face ID" / "Confirm with Touch ID" / "Confirm with
    /// Passcode" instead of a generic label.
    static func biometryDisplayName() -> String {
        let ctx = LAContext()
        var err: NSError?
        // Probe biometric-only first so we can distinguish Face vs Touch.
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) {
            switch ctx.biometryType {
            case .faceID:   return "Face ID"
            case .touchID:  return "Touch ID"
            case .opticID:  return "Optic ID"
            default:        break
            }
        }
        // Passcode-only fallback. If even passcode isn't set up we still
        // return "Passcode" rather than empty — the caller (the gate
        // itself) will block the action with `.notAvailable`.
        return "Passcode"
    }

    /// Prompts the user for biometric / passcode confirmation. Returns
    /// normally on success; throws `BiometricGateError.cancelled` if
    /// the user dismisses the sheet. The `reason` string is what iOS
    /// renders inside the system prompt. It MUST include the
    /// transaction amount and counterparty so the user sees what they
    /// are authorizing.
    func requireUserPresence(reason: String) async throws {
        // Settings toggle off → gate is a no-op. Default is ON; user
        // must explicitly opt out via Profile → Security.
        if !BiometricGate.isRequired { return }

        let context = LAContext()
        // We don't reuse touch ID auth from elsewhere. Every
        // fund-moving signature is its own consent moment.
        context.touchIDAuthenticationAllowableReuseDuration = 0
        // Hide the fallback button only after the system thinks
        // biometrics are usable; if not, iOS still surfaces passcode.
        context.localizedFallbackTitle = "Use passcode"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            // `canEvaluatePolicy` returning false with policy
            // `.deviceOwnerAuthentication` means no biometrics AND
            // no device passcode set. That's a misconfigured device,
            // not a UX problem; surface it instead of silently
            // letting the signature proceed.
            let msg = policyError?.localizedDescription
                ?? "no biometrics or passcode set on this device"
            throw BiometricGateError.notAvailable(reason: msg)
        }

        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if !ok {
                throw BiometricGateError.failed(underlying: "authentication did not succeed")
            }
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                throw BiometricGateError.cancelled
            case .userFallback:
                // User tapped fallback. `.deviceOwnerAuthentication`
                // already includes the passcode path internally, so a
                // userFallback here means they explicitly bailed.
                throw BiometricGateError.cancelled
            case .biometryLockout:
                // Biometrics are locked out (too many failed attempts)
                // but the system still allows passcode. Re-run with a
                // fresh context that explicitly skips biometry: iOS
                // will show passcode directly.
                let pcContext = LAContext()
                pcContext.localizedFallbackTitle = ""
                var pcErr: NSError?
                guard pcContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &pcErr) else {
                    throw BiometricGateError.notAvailable(
                        reason: pcErr?.localizedDescription ?? "passcode unavailable"
                    )
                }
                do {
                    let ok = try await pcContext.evaluatePolicy(
                        .deviceOwnerAuthentication,
                        localizedReason: reason
                    )
                    if !ok {
                        throw BiometricGateError.failed(underlying: "passcode did not succeed")
                    }
                } catch let pcLAErr as LAError {
                    switch pcLAErr.code {
                    case .userCancel, .appCancel, .systemCancel, .userFallback:
                        throw BiometricGateError.cancelled
                    case .passcodeNotSet:
                        throw BiometricGateError.notAvailable(reason: "passcode not set")
                    default:
                        throw BiometricGateError.failed(underlying: pcLAErr.localizedDescription)
                    }
                }
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                // Treat as not-available so the caller can route to the
                // "set up Face ID or passcode" alert instead of the
                // generic error path.
                throw BiometricGateError.notAvailable(reason: laError.localizedDescription)
            default:
                throw BiometricGateError.failed(underlying: laError.localizedDescription)
            }
        } catch let gateError as BiometricGateError {
            // Re-throw our own errors untouched (e.g. the `if !ok` path).
            throw gateError
        } catch {
            throw BiometricGateError.failed(underlying: error.localizedDescription)
        }
    }
}
