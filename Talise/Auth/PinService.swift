import Foundation
import Security
import CryptoKit

/// Per-user PIN storage backed by the Keychain.
///
/// We hash the PIN with a per-install random salt and SHA-256 — what hits
/// disk is `salt || sha256(salt || pin)`. PINs are weak entropy (4 digits =
/// 10⁴ combinations), so the on-device hash is just defense-in-depth in
/// case the Keychain item is ever leaked. The real protection is the
/// Keychain's hardware-backed encryption + the device unlock requirement.
///
/// Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
/// Never syncs to iCloud, never leaves the device.
///
/// Keying: every record is scoped by the signed-in `userId`, so two users
/// sharing a device get independent PINs. Wiping one user's PIN does not
/// touch the other's.
@MainActor
final class PinService {
    static let shared = PinService()
    private init() {}

    private let service = "io.talise.app.pin"

    private func account(for userId: String) -> String { "pin." + userId }

    /// Stores `salt(16) || sha256(salt || pin)` for `userId`. Overwrites
    /// any existing PIN for the same user.
    func setPin(_ pin: String, userId: String) throws {
        guard !userId.isEmpty else { throw PinError.missingUser }
        let salt = Self.randomBytes(16)
        let digest = Self.hash(pin: pin, salt: salt)
        var blob = Data()
        blob.append(salt)
        blob.append(digest)
        try writeKeychain(account: account(for: userId), data: blob)
    }

    func hasPin(userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        return readKeychain(account: account(for: userId)) != nil
    }

    /// Returns true if `pin` matches the stored hash for `userId`.
    /// Constant-time compared to mitigate trivial timing differences.
    func verifyPin(_ pin: String, userId: String) -> Bool {
        guard !userId.isEmpty,
              let blob = readKeychain(account: account(for: userId)),
              blob.count == 16 + 32 else { return false }
        let salt = blob.prefix(16)
        let stored = blob.suffix(32)
        let candidate = Self.hash(pin: pin, salt: Data(salt))
        return Self.constantTimeEquals(Data(stored), candidate)
    }

    /// Clears one user's PIN. Used by the "Forgot PIN" path so the next
    /// sign-in lands the user back at the set-PIN flow.
    func clearPin(userId: String) {
        guard !userId.isEmpty else { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: userId),
        ]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - Internals

    private static func hash(pin: String, salt: Data) -> Data {
        var data = Data()
        data.append(salt)
        if let pinData = pin.data(using: .utf8) { data.append(pinData) }
        return Data(SHA256.hash(data: data))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private func writeKeychain(account: String, data: Data) throws {
        let delete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(delete as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PinError.keychain(status) }
    }

    private func readKeychain(account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }
}

enum PinError: Error, LocalizedError {
    case missingUser
    case keychain(OSStatus)
    case cancelled
    case forgotSignOut

    var errorDescription: String? {
        switch self {
        case .missingUser:    return "Not signed in."
        case .keychain(let s): return "Couldn't save PIN (keychain status \(s))."
        case .cancelled:      return "PIN entry cancelled."
        case .forgotSignOut:  return "Sign in again to set a new PIN."
        }
    }
}
