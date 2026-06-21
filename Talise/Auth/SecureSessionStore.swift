import Foundation
import Security

/// Stores the mobile bearer token issued by /api/auth/mobile/exchange.
///
/// Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
/// Readable by our app once the phone is unlocked, never syncs to iCloud,
/// never leaves the device. We don't gate reads on biometry — that would
/// pop Face ID on every API call. Biometric confirmation lives at the
/// signing layer (the user re-authenticates before a send).
@MainActor
final class SecureSessionStore {
    static let shared = SecureSessionStore()
    private init() {}

    private let service = "io.talise.app.session"
    private let account = "bearer"

    enum StoreError: Error {
        case write(OSStatus)
        case notFound
    }

    func save(token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw StoreError.write(errSecParam)
        }
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
        guard status == errSecSuccess else { throw StoreError.write(status) }
    }

    /// Read the bearer. Returns nil rather than throwing if absent so
    /// callers can branch on signed-in / signed-out without a try/catch.
    func read() -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    func hasToken() -> Bool { read() != nil }

    func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
