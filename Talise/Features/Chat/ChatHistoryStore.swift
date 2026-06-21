import Foundation
import Security

/// Plan 12 — Keychain-backed persistence for the AI chat transcript.
///
/// Why Keychain and not UserDefaults: the transcript can contain dollar
/// amounts, balances, and the assistant's read-only commentary on the
/// user's finances. It's not catastrophic if leaked, but the same
/// "stays on-device, doesn't sync to iCloud" guarantee we use for the
/// bearer is appropriate here — and we already speak Keychain.
///
/// Layout: a single generic-password item, value = JSON-encoded array
/// of `ChatMessage`. Cap is 20 messages — older entries drop off the
/// front so the persisted blob stays small (<8KB) and the request body
/// sent to `/api/chat/stream` stays under the route's history limit.
@MainActor
final class ChatHistoryStore {
    static let shared = ChatHistoryStore()
    private init() {}

    static let cap = 20

    private let service = "io.talise.chat.history"
    private let account = "transcript"

    func load() -> [ChatMessage] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    func save(_ messages: [ChatMessage]) {
        // Cap before serializing — never write more than `cap` rows.
        let trimmed = Array(messages.suffix(Self.cap))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }

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
        SecItemAdd(add as CFDictionary, nil)
    }

    func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
