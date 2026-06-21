import Foundation

/// Persists the last-known Home-screen data snapshots so the app can
/// render real numbers on the very first frame instead of showing
/// redacted placeholders while the network loads.
///
/// Storage: `UserDefaults.standard` (JSON-encoded Codable), mirroring
/// the CurrencySettings / AppConfig patterns elsewhere in this codebase.
/// Keys are scoped per-user (by `userId`) so switching accounts doesn't
/// cross-pollinate.
///
/// Security note: `UserDTO` carries email + name/picture but NO bearer
/// token, wallet keys, or payment credentials — safe for UserDefaults.
/// The bearer stays in Keychain (SecureSessionStore).
enum LocalSnapshotStore {

    // MARK: - Keys

    private static func key(_ base: String, userId: String) -> String {
        "io.talise.snapshot.\(base).\(userId)"
    }

    private static func tsKey(_ base: String, userId: String) -> String {
        "io.talise.snapshot.\(base).ts.\(userId)"
    }

    private static func stampNow(_ base: String, userId: String) {
        UserDefaults.standard.set(
            Date().timeIntervalSince1970, forKey: tsKey(base, userId: userId)
        )
    }

    /// Seconds since this snapshot was last saved, or nil if never saved.
    private static func ageSeconds(_ base: String, userId: String) -> TimeInterval? {
        let t = UserDefaults.standard.double(forKey: tsKey(base, userId: userId))
        guard t > 0 else { return nil }
        return Date().timeIntervalSince1970 - t
    }

    // MARK: - BalancesDTO

    static func loadBalances(userId: String) -> BalancesDTO? {
        guard let data = UserDefaults.standard.data(
            forKey: key("balances", userId: userId)
        ) else { return nil }
        return try? JSONDecoder().decode(BalancesDTO.self, from: data)
    }

    /// Last-known balance for instant paint, but ONLY if saved within
    /// `maxAgeSec`. A stale snapshot would flash a wrong number; beyond the
    /// window we'd rather show the placeholder and wait for the live read.
    static func loadBalancesIfFresh(userId: String, maxAgeSec: TimeInterval) -> BalancesDTO? {
        guard let age = ageSeconds("balances", userId: userId), age <= maxAgeSec else { return nil }
        return loadBalances(userId: userId)
    }

    static func saveBalances(_ dto: BalancesDTO, userId: String) {
        guard let data = try? JSONEncoder().encode(dto) else { return }
        UserDefaults.standard.set(data, forKey: key("balances", userId: userId))
        stampNow("balances", userId: userId)
    }

    // MARK: - Activity

    /// Maximum entries cached. Matches the /api/activity?limit= we use.
    private static let activityCap = 20

    static func loadActivity(userId: String) -> [ActivityEntryDTO]? {
        guard let data = UserDefaults.standard.data(
            forKey: key("activity", userId: userId)
        ) else { return nil }
        // Tolerant per-row decode — a single shape change (e.g. an app update
        // that added a field) must not discard the whole cached feed.
        guard let wrapped = try? JSONDecoder().decode(
            [FailableDecodable<ActivityEntryDTO>].self, from: data
        ) else { return nil }
        return wrapped.compactMap { $0.value }
    }

    /// Last-known activity for instant paint, but ONLY if saved within
    /// `maxAgeSec`. This is the guard that stops a days-old feed from being
    /// shown as "Recent" — the home glance must be genuinely recent. Older
    /// than the window → return nil so the view loads fresh from the (fast,
    /// snapshot-backed) /api/activity instead.
    static func loadActivityIfFresh(userId: String, maxAgeSec: TimeInterval) -> [ActivityEntryDTO]? {
        guard let age = ageSeconds("activity", userId: userId), age <= maxAgeSec else { return nil }
        return loadActivity(userId: userId)
    }

    static func saveActivity(_ entries: [ActivityEntryDTO], userId: String) {
        let capped = Array(entries.prefix(activityCap))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        UserDefaults.standard.set(data, forKey: key("activity", userId: userId))
        stampNow("activity", userId: userId)
    }

    // MARK: - UserDTO

    static func loadUser(userId: String) -> UserDTO? {
        guard let data = UserDefaults.standard.data(
            forKey: key("user", userId: userId)
        ) else { return nil }
        return try? JSONDecoder().decode(UserDTO.self, from: data)
    }

    static func saveUser(_ dto: UserDTO) {
        guard let data = try? JSONEncoder().encode(dto) else { return }
        UserDefaults.standard.set(data, forKey: key("user", userId: dto.id))
    }

    // MARK: - Clear

    /// Wipes all snapshot data for a given user. Call on sign-out so
    /// stale data doesn't persist after the account is removed from the
    /// device.
    static func clear(userId: String) {
        for base in ["balances", "activity", "user"] {
            UserDefaults.standard.removeObject(forKey: key(base, userId: userId))
            UserDefaults.standard.removeObject(forKey: tsKey(base, userId: userId))
        }
    }
}
