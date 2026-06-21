import Foundation

/// Typed shapes for the Talise backend endpoints we consume from iOS.
/// Keep in sync with /web/app/api/* response shapes.

enum AccountType: String, Codable {
    case personal
    case business
}

/// Server feature gates (from `/api/me`). Default false = closed, so a
/// missing flag keeps the feature hidden until Vercel env opens it.
struct UserFeatures: Codable, Hashable {
    var cashout: Bool = false
    var scanToPay: Bool = false
}

struct UserDTO: Codable, Hashable {
    let id: String
    let email: String
    let name: String?
    let picture: String?
    /// Avatar OVERRIDE the user picked (e.g. an NFT image). Optional so older
    /// `/api/me` payloads decode; prefer this over `picture` when present.
    var pfpUrl: String? = nil
    let country: String?
    let suiAddress: String
    let accountType: AccountType?
    let businessName: String?
    let businessHandle: String?
    /// Bare on-chain SuiNS subname, e.g. "alice" (no parent suffix).
    /// Nil until the user mints one via /api/username/claim.
    let taliseHandle: String?
    /// SuiNS canonical, e.g. "alice.talise.sui". Convenience companion
    /// to taliseHandle so views don't need to recompose the string.
    let taliseSubname: String?

    /// Server-driven feature gates from `/api/me` (flipped via Vercel env,
    /// no app build needed). Optional + fail-CLOSED so an older payload or a
    /// missing field hides the gated entry point rather than exposing it.
    var features: UserFeatures? = nil
    /// Cash-out to bank entry point visible?
    var cashoutEnabled: Bool { features?.cashout ?? false }
    /// Scan-to-pay entry point visible?
    var scanToPayEnabled: Bool { features?.scanToPay ?? false }

    /// Canonical display ONLY when the user actually owns a resolvable
    /// SuiNS handle. Returns nil otherwise so callers can show a
    /// "Claim your name" CTA instead of fabricating one.
    ///
    /// `businessHandle` is honored only for `accountType == .business`
    /// accounts. The DB keeps the business_handle column on personal
    /// users when they once tried business onboarding (it's not auto
    /// cleared), so reading it unconditionally on a personal account
    /// surfaces a name that doesn't represent the wallet.
    func displayHandle() -> String? {
        if let h = taliseHandle, !h.isEmpty { return "\(h)@talise.sui" }
        if accountType == .business,
           let h = businessHandle, !h.isEmpty {
            return "\(h)@talise.sui"
        }
        return nil
    }

    /// Suggestion used to seed the claim sheet — derived from Google
    /// name (then email local-part). Never shown standalone as if it
    /// were the user's real handle.
    func suggestedHandle() -> String {
        let source: String = {
            if let name, !name.isEmpty,
               let first = name.split(separator: " ").first {
                return String(first)
            }
            if let local = email.split(separator: "@").first {
                return String(local)
            }
            return "you"
        }()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        let normalized = source.lowercased().unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init).joined()
        return String(normalized.prefix(20))
    }

    /// True once the user actually owns a `*.talise.sui` subname NFT.
    var hasTaliseSubname: Bool {
        (taliseHandle?.isEmpty == false)
    }
}

/// Response shape for /api/username/check?u=<input>.
struct UsernameCheckResponse: Codable {
    let available: Bool
    let reason: String?
}

// Note: /api/sui/epoch returns `{ epoch: String }` (Sui SDK stringifies
// epoch numbers). Callers decode inline with their own struct rather
// than going through a shared DTO, so there's intentionally no
// `EpochDTO` here.
//
// /api/zk/proof + /api/zk/sponsor + /api/zk/sponsor-execute response
// shapes are read by ZkLoginCoordinator via raw `[String: Any]`
// decoding (the proof body is a nested freeform object; round-tripping
// it through Codable produces stringified inner JSON — see warmProof's
// comment). No shared DTOs for those paths either.

/// A recipient's PUBLIC shield identity, from /api/recipient/resolve. Both are
/// public values: `pubkey` = Poseidon1(spendingKey) u256 decimal; `encPubkeyHex`
/// = the recipient's P-256 ECIES point (0x04+128hex). Used to address a
/// hidden-amount shielded transfer to them. No secrets.
struct ShieldIdentity: Codable {
    let pubkey: String
    let encPubkeyHex: String
}

struct RecipientResolution: Codable {
    let address: String
    /// Web endpoint returns `displayName`; some callers may use `display`.
    let displayName: String?
    let display: String?
    let source: String?
    /// Off-ramp Phase 3: present when the resolved recipient has a primary
    /// Nigerian bank account linked to their @handle. Nil for recipients
    /// with no primary bank (Send then works exactly as before — no toggle).
    /// Optional so older endpoints and address-only resolutions decode
    /// cleanly without this field.
    let recipientBank: RecipientBank?

    /// Present when the resolved recipient has published a shield identity
    /// (pubkey + enc pubkey). Enables a HIDDEN-AMOUNT shielded transfer to them.
    /// Nil → fall back to the public deposit→withdraw send. Optional so older
    /// endpoints + address-only resolutions decode cleanly.
    let shieldIdentity: ShieldIdentity?

    /// Explicit initializer so the call sites that build a resolution by
    /// hand (contact picks, raw-address fast-paths) don't have to pass the
    /// new `recipientBank` field — it defaults to nil there, which is
    /// correct (those paths carry no bank info). The server-decoded path
    /// still populates it via Codable.
    init(address: String, displayName: String?, display: String?, source: String?, recipientBank: RecipientBank? = nil, shieldIdentity: ShieldIdentity? = nil) {
        self.address = address
        self.displayName = displayName
        self.display = display
        self.source = source
        self.recipientBank = recipientBank
        self.shieldIdentity = shieldIdentity
    }

    var displayString: String {
        displayName ?? display ?? address
    }
}

/// Summary of the recipient's PRIMARY linked bank account. We surface only
/// the bank name + last4 — never the full account number — so the sender
/// can recognise the destination ("GTBank ••••1234") without seeing PII.
struct RecipientBank: Codable, Hashable {
    let hasPrimary: Bool
    let bankName: String?
    let last4: String?

    /// "GTBank ••••1234" / "Their bank" fallback when the label is sparse.
    var label: String {
        let name = (bankName ?? "").trimmingCharacters(in: .whitespaces)
        let tail = (last4 ?? "").trimmingCharacters(in: .whitespaces)
        switch (name.isEmpty, tail.isEmpty) {
        case (false, false): return "\(name) ••••\(tail)"
        case (false, true):  return name
        case (true, false):  return "••••\(tail)"
        case (true, true):   return "their bank"
        }
    }
}

struct BalancesDTO: Codable {
    let address: String
    let usdsui: Double
    let sui: Double
    let suiPriceUsd: Double
    let totalUsd: Double
}

struct ActivityEntryDTO: Codable, Identifiable {
    let digest: String
    let timestampMs: Double
    /// "sent" | "received" | "invest" | "withdraw"
    let direction: String
    let amountUsdsui: Double?
    let amountSui: Double?
    let counterparty: String?
    let counterpartyName: String?
    /// For invest/withdraw rows: which yield venue (e.g. "deepbook",
    /// "navi"). Nil for plain transfers. Server populates this from
    /// MoveCall package detection in lib/activity.ts.
    let venue: String?
    /// Set when the user received or sent a non-USDsui / non-SUI coin
    /// (WAL, USDC, USDT, …). `amount` is the raw u64 as a String —
    /// formatted client-side using `decimals` so we don't lose
    /// precision on the wire. Optional so older API responses that
    /// pre-date this field decode without a custom init(from:).
    let otherCoin: ActivityOtherCoin?
    /// Compound spend+save: when a Send PTB bundled a round-up NAVI supply
    /// leg, the server reports the primary transfer via `amountUsdsui` and the
    /// auto-saved portion here. iOS renders "Sent + saved $X" with both legs.
    /// Optional so older API responses (and optimistic stubs) decode without
    /// threading this field through every call site. Defaults to nil.
    var roundupUsdsui: Double? = nil
    /// Present on USDsui→fiat bank cash-out rows. When non-nil the row is
    /// a fiat off-ramp (Linq) and should render as a "Cash out" — the
    /// NGN payout, destination bank, and disbursement status — rather than
    /// an anonymous on-chain "Sent". Optional so existing rows (which omit
    /// it) keep decoding unchanged. Defaults to nil so the synthesized
    /// memberwise initializer used by optimistic stubs in HomeView compiles
    /// without threading an `offramp:` argument through every call site.
    var offramp: OfframpInfo? = nil

    var id: String { digest }
    var isReceived: Bool { direction == "received" }
    var isInvest: Bool { direction == "invest" }
    var isWithdraw: Bool { direction == "withdraw" }
    /// True when a Send carried a meaningful round-up save leg (> $0). Drives
    /// the "Sent + saved $X" title/subtitle treatment on outgoing rows.
    var hasRoundup: Bool { (roundupUsdsui ?? 0) > 0 }
}

/// Fiat off-ramp metadata for a cash-out activity row. The server attaches
/// this to USDsui→NGN bank disbursements (direction "sent", venue "linq").
struct OfframpInfo: Codable, Hashable {
    let provider: String
    let amountNgn: Double
    let bankName: String?
    let accountLast4: String?
    /// Linq order status: disbursed/settled/completed = paid out;
    /// timeout/failed = failed; anything else = still pending.
    let status: String
    let rate: Double
    let orderId: String
}

struct ActivityOtherCoin: Codable, Hashable {
    let coinType: String
    let symbol: String
    /// Raw u64 string — BigInt-safe over the wire.
    let amount: String
    let decimals: Int

    /// Format the raw amount for display, e.g. "10" for 10 WAL with
    /// 9 decimals. Trims trailing zeros after the decimal point.
    var displayAmount: String {
        guard let raw = Double(amount) else { return amount }
        let scaled = raw / pow(10.0, Double(decimals))
        if scaled.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int64(scaled))
        }
        var s = String(format: "%.4f", scaled)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Decodes `T`, swallowing a per-element failure to `nil` instead of aborting
/// the whole array. Decoding `[FailableDecodable<T>]` never throws on a bad
/// element (each `init` uses `try?`), so one malformed or new-shaped row can't
/// discard the entire — immutable — activity history.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct ActivityResponse: Codable {
    let entries: [ActivityEntryDTO]

    init(entries: [ActivityEntryDTO]) { self.entries = entries }

    private enum CodingKeys: String, CodingKey { case entries }

    // Tolerant decode — see `FailableDecodable`. A single unparseable row is
    // dropped, not allowed to throw away every other row.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let wrapped = try c.decode([FailableDecodable<ActivityEntryDTO>].self, forKey: .entries)
        entries = wrapped.compactMap { $0.value }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries)
    }
}

struct SendBuildRequest: Codable {
    let to: String
    let amount: Double
    let asset: String
}

struct BuildKindResponse: Codable {
    let transactionKindB64: String
    /// Server-blessed round-up amount in USDsui when a Send PTB
    /// includes a compound NAVI supply leg (Phase 2 v2). 0 / nil when
    /// the user has round-up disabled or the send was too small to
    /// trigger a sweep. iOS forwards this to `/api/zk/sponsor-execute`
    /// as `meta.roundupUsd` so the rewards engine credits the
    /// round-up points + bumps the savings tally.
    let roundupUsd: Double?
}

struct SupplyBuildRequest: Codable {
    let venue: String
    let amount: Double
}

struct ContactDTO: Codable, Identifiable {
    let address: String
    let name: String?
    let lastSeenMs: Double
    let sentCount: Int
    let receivedCount: Int

    var id: String { address }
    var display: String {
        name ?? Self.short(address)
    }
    private static func short(_ a: String) -> String {
        guard a.count > 14 else { return a }
        return String(a.prefix(8)) + "…" + String(a.suffix(6))
    }
}

struct ContactsResponse: Codable {
    let contacts: [ContactDTO]
}

struct UsernameClaimResponse: Codable {
    let ok: Bool?
    let username: String?
    let digest: String?
    let subnameNftId: String?
    let error: String?
}

/// Response from /api/sweep/prepare with action="preview". Describes
/// what's swappable into USDsui without building the PTB.
struct SweepPreviewDTO: Codable {
    let eligible: Bool
    let from: SweepLeg
    let to: SweepLeg
    let route: String?
    let sponsored: Bool?
}

/// Response from /api/sweep/prepare with action="execute". Carries the
/// Cetus-router PTB ready to feed into /api/zk/sponsor.
struct SweepExecuteDTO: Codable {
    let transactionKindB64: String
    let from: SweepLeg
    let to: SweepLeg
    let slippage: Double?
}

struct SweepLeg: Codable {
    let coin: String
    let amount: Double?
    let estimateUsd: Double?
}

struct YieldVenue: Codable, Identifiable {
    var id: String { venue }
    let venue: String
    let apy: Double
    let supplied: Double?
    let pendingRewards: Double?
    /// Cumulative yield earned-so-far for the user on this venue, in
    /// USD (USDsui is 1:1 USD). For Navi, computed server-side as
    /// `currentValue − principalSupplied` from on-chain activity
    /// replay. Optional so older builds and other venues decode
    /// cleanly.
    let earned: Double?
    /// Projected per-day yield (`supplied × apy / 365`) in USD.
    /// Server-computed so the iOS side doesn't have to mix APY and
    /// supplied in the view layer.
    let earningPerDay: Double?
    /// Reconstructed principal (= currentValue − earned).
    let principalSupplied: Double?
    /// Epoch-ms the current earning streak began (deposit that took the
    /// position 0 → positive; resets on full withdrawal). Lets the client
    /// tick `earned` live = supplied × apy × (now − earningSince)/year and
    /// project year-end = supplied × apy. Optional for back-compat.
    let earningSinceMs: Double?

    /// Display-cased venue name — the venue code stays lowercased over
    /// the wire (server keys + activity classifier use "navi" /
    /// "deepbook"), but the UI shows them as proper nouns.
    var displayName: String { displayVenueName(venue) }
}

/// Maps a venue code (`"navi"`, `"deepbook"`) to a generic, user-facing
/// label. The venue codes stay as internal identifiers — DB / wire /
/// activity classifier all keep `"navi"` / `"deepbook"` — but users see
/// generic earning terminology ("Earn", "Trading") instead of the
/// underlying protocol brand. Single source of truth — every History
/// label, receipt, button caption, and intent string flows through here.
func displayVenueName(_ code: String) -> String {
    let normalized = code.lowercased()
    switch normalized {
    case "navi":     return "Earn"
    case "deepbook": return "Trading"
    default:
        guard let first = normalized.first else { return code }
        return first.uppercased() + normalized.dropFirst()
    }
}

struct YieldComparison: Codable {
    let venues: [YieldVenue]
    let best: YieldVenue?
}

struct RewardsSummary: Codable {
    let code: String
    let pointsTotal: Int
    let referralCount: Int
    let recentEvents: [RewardsEvent]
    /// Tier (Bronze/Silver/Gold/Platinum). Nil for old server builds
    /// that haven't shipped the rewards refresh yet — UI falls back
    /// to a points-only display.
    let tier: RewardsTier?
    /// Lifetime tally — what the user has sent / saved through Talise,
    /// in USD. Rendered through `TaliseFormat.local2` so a Nigerian
    /// user sees ₦, a US user sees $, etc.
    let lifetimeSentUsd: Double?
    let lifetimeSavedUsd: Double?
    /// Round-up & Save toggle state. Drives the Roundup card on the
    /// Rewards tab.
    let roundup: RoundupConfig?
    /// Lifetime amount auto-swept via round-up (USD). Rendered as the
    /// "Saved via round-up" line on the RoundupCard. Separate from
    /// `lifetimeSavedUsd` because that one also includes explicit
    /// invests and goal deposits.
    let roundupSavedUsd: Double?
    /// Point-earning rates from the server so iOS can render the
    /// "earn rules" copy without hardcoding (1 pt / $1 sent, etc.)
    let pointRates: PointRates?
}

struct RewardsTier: Codable {
    let id: String         // "bronze" | "silver" | "gold" | "plat"
    let label: String
    let pointsToNext: Int? // nil at top tier
    let nextLabel: String?
}

struct RoundupConfig: Codable {
    let enabled: Bool
    let percentage: Int    // 1-10
}

struct PointRates: Codable {
    let send: Int
    /// Points per $1 supplied to a yield venue. Server's `EarnTrigger`
    /// uses `"invest"` as the trigger name (matches the activity feed's
    /// `direction: "invest"`), so the JSON key is `invest` not `save`.
    /// Earlier revision used `save` and silently fell through to the
    /// iOS hardcoded fallback (3) on decode — fixed.
    let invest: Int
    let withdraw: Int
    let roundup: Int
    let goal: Int
}

struct RewardsEvent: Codable, Identifiable {
    let id: String
    let kind: String
    let points: Int
    let createdAt: String
}

// MARK: - Phase 3: Savings Goals + Insights

/// One savings goal (named bucket on top of the user's main NAVI position).
/// `currentUsd` and `targetUsd` are USD figures the iOS formatter localizes
/// via `TaliseFormat.local2`. v1 deposits are tracking-only — no on-chain
/// per-goal segregation; bumping `currentUsd` mints a `goal_deposit`
/// rewards_event (4 pts/$1 via the canonical earn engine).
struct SavingsGoal: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let targetUsd: Double
    let currentUsd: Double
    /// Optional epoch-ms deadline. Drives the "23 days left" countdown.
    let deadlineMs: Double?
    /// Optional accent hex (e.g. "#2DC07A"). Nil → fall back to TaliseColor.accent.
    let color: String?
    let createdAtMs: Double
    let archived: Bool
    /// Server-derived "reached target" flag. Optional so older API responses
    /// (without the field) still decode; falls back to the local computation.
    let completed: Bool?
    /// On-chain GoalVault object id once the goal is vault-backed. Nil until the
    /// first real deposit creates the vault. Drives the deposit/withdraw rail:
    /// nil → first deposit `create`s the vault; set → `deposit`/`withdraw`.
    let vaultObjectId: String?
    /// True when the goal's funds are earning NAVI yield (supplied under an
    /// AccountCap parked in its vault). Optional so older API responses decode.
    let yieldOn: Bool?

    /// 0…1 fill ratio for the progress ring. Caps at 1 even when the user
    /// has overshot the target.
    var progress: Double {
        guard targetUsd > 0 else { return 0 }
        return min(1, max(0, currentUsd / targetUsd))
    }

    /// Whether this goal has hit its target — drives the Completed section.
    var isComplete: Bool {
        completed ?? (targetUsd > 0 && currentUsd >= targetUsd)
    }

    /// "23 days left" / "Past due" / nil if no deadline.
    var deadlineLabel: String? {
        guard let deadlineMs else { return nil }
        let now = Date().timeIntervalSince1970 * 1000.0
        let diffDays = Int((deadlineMs - now) / (1000.0 * 60 * 60 * 24))
        if diffDays < 0 { return "Past due" }
        if diffDays == 0 { return "Due today" }
        if diffDays == 1 { return "1 day left" }
        return "\(diffDays) days left"
    }
}

/// Wrapper for GET/POST /api/rewards/goals.
struct SavingsGoalsResponse: Codable {
    let goals: [SavingsGoal]
}

/// POST body for /api/rewards/goals (create).
struct SavingsGoalCreateRequest: Codable {
    let name: String
    let targetUsd: Double
    let deadlineMs: Double?
    let color: String?
}

/// PATCH body for /api/rewards/goals/[id] (update / archive).
struct SavingsGoalUpdateRequest: Codable {
    let name: String?
    let targetUsd: Double?
    let deadlineMs: Double?
    let color: String?
    let archive: Bool?
}

/// POST body for /api/rewards/goals/[id] (tracking deposit or withdrawal).
/// `action: "withdraw"` un-tracks funds back out of the goal; nil/"deposit"
/// is the default add-to-goal.
struct GoalDepositRequest: Codable {
    let amountUsd: Double
    var action: String? = nil
}

/// Response from a goal mutation (create / patch / deposit). `pointsAwarded`
/// is only present on the deposit call.
struct SavingsGoalMutationResponse: Codable {
    let goal: SavingsGoal
    let pointsAwarded: Int?
}

/// Body for POST /api/goals/vault/confirm — records an on-chain GoalVault op
/// (create | deposit | withdraw) AFTER its sponsored tx has landed.
struct GoalVaultConfirmBody: Encodable {
    let goalId: String
    let op: String
    let amountUsd: Double
    let digest: String
}

/// Response from /api/goals/vault/confirm. We only need the refreshed goal;
/// the list reloads via onChanged() regardless.
struct GoalVaultConfirmResponse: Decodable {
    let goal: SavingsGoal?
    let vaultObjectId: String?
}

/// One row in the "top counterparties this month" strip.
struct InsightsCounterparty: Codable, Identifiable, Hashable {
    let address: String
    let name: String?
    let count: Int
    let totalUsd: Double

    var id: String { address }
    /// "jude" / `0xab12…cdef` fallback for raw addresses.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        guard address.count > 14 else { return address }
        return String(address.prefix(8)) + "…" + String(address.suffix(6))
    }
}

/// Month-to-date insights derived from getRecentActivity on the server.
/// Mirrors `MonthInsights` in web/lib/rewards/insights.ts.
struct MonthInsights: Codable {
    let spentUsd: Double
    let receivedUsd: Double
    let savedUsd: Double
    let monthStartMs: Double
    let sampleSize: Int
    let topCounterparties: [InsightsCounterparty]
}

// MARK: - Phase 4: Redemption catalogue

/// Mirrors the catalogue entry shape from `web/lib/rewards/catalogue.ts`
/// + the `canAfford` affordability hint computed server-side from the
/// user's current `pointsTotal`. iOS doesn't decode `metadata`/lock
/// hints client-side — the server is the source of truth, so the
/// `canAfford` boolean drives the disabled state and `minTier` is a
/// presentation cue.
struct RedeemSKU: Codable, Identifiable, Hashable {
    let sku: String
    let label: String
    let description: String
    let pointsCost: Int
    /// "instant" | "flagged" | "pending"
    let kind: String
    let icon: String?
    /// nil when the SKU has no tier gate. "bronze" | "silver" | "gold" | "plat".
    let minTier: String?
    let stackable: Bool?
    /// Window the perk is active for, in ms. nil for permanent perks.
    let durationMs: Double?
    /// Server-computed: does the user's current `pointsTotal` cover this?
    let canAfford: Bool

    var id: String { sku }
}

/// Response from `GET /api/rewards/catalogue` — the list of redeemable
/// SKUs plus the user's current points total (so iOS can render
/// "Redeem"/"X pts needed" without a second round-trip).
struct RedemptionsCatalogue: Codable {
    let pointsTotal: Int
    let items: [RedeemSKU]
}

/// Response from `POST /api/rewards/redeem` — the new points total plus
/// the freshly created redemption row. iOS uses the `pointsTotal` to
/// update the parent Rewards summary inline (the section also fires
/// `onRedeemed` so the parent can refetch the whole summary).
struct RedemptionResponse: Codable {
    let ok: Bool
    let pointsTotal: Int
    let redemption: RedemptionRow
}

struct RedemptionRow: Codable, Identifiable {
    let id: String
    let sku: String
    let pointsSpent: Int
    /// "pending" | "fulfilled" | "expired" | "refunded"
    let status: String
    let createdAt: String
    let fulfilledAt: String?
}

/// Request body for `POST /api/rewards/redeem`.
struct RedeemRequest: Encodable {
    let sku: String
}

// MARK: - Phase 5: Vault + Auto-Swap

/// Response from `POST /api/vault/create` (and the other vault PTB
/// builders). The server prepares the PTB; iOS signs it with the
/// zkLogin ephemeral key and forwards to `/api/zk/sponsor-execute`
/// for Onara to broadcast.
///
/// `bytesB64` is the base64'd transaction-kind bytes — same shape the
/// existing send/earn flows consume as `transactionKindB64`. We keep
/// the new field name to match the vault API spec in
/// `move/talise/AUTOSWAP.md`; the iOS coordinator treats them
/// interchangeably.
struct VaultCreatePrepareResponse: Codable {
    let bytesB64: String
    let sender: String
}

/// Body for `POST /api/vault/record`. Called after the create PTB
/// settles on-chain — passes the freshly created vault object id +
/// the broadcast digest so the backend can persist the link to the
/// user row.
struct VaultRecordRequest: Codable {
    let vaultId: String
    let digest: String
}

/// Body for `POST /api/vault/enable-autoswap`. The user opts a single
/// source coin type into auto-conversion.
///
/// • `sourceType` is the Move type tag (e.g. `"0x2::sui::SUI"`).
/// • `maxPerSwap` is u64 — kept as a String over the wire so values
///   approaching `2^53` don't lose precision.
/// • `expiresAtMs` is the cap's expiry timestamp in epoch-ms. The
///   server clips to a sane upper bound (~1y from now) on mint.
struct VaultEnableAutoSwapRequest: Codable {
    let sourceType: String
    let maxPerSwap: String
    let expiresAtMs: UInt64
}

/// Generic body for `pause / resume / disable` endpoints — same shape
/// for all three operations, with the action implicit in the route.
struct VaultCapMutationRequest: Codable {
    let capId: String
    let sourceType: String
}

/// Body for `POST /api/vault/upgrade-cap-v2`. Burns the existing v1
/// `AutoSwapCap<T>` and mints an equivalent `AutoSwapCapV2<T>` with the
/// v7 per-day budget throttle. `maxPerDay` is the raw u64 budget in the
/// source coin's native units, sent as a String for BigInt safety.
struct VaultUpgradeCapV2Request: Codable {
    let capId: String
    let sourceType: String
    let maxPerDay: String
}

/// Body for `POST /api/vault/withdraw`. Pulls `amount` units of
/// `Balance<coinType>` out of the user's vault and transfers the
/// resulting `Coin<T>` to their wallet. `amount` is the raw u64 in
/// the coin's native decimals — kept as a String over the wire so
/// USDsui values approaching `2^53` micro-units don't lose precision.
struct VaultWithdrawRequest: Codable {
    let coinType: String
    let amount: String
}

/// Response from `GET /api/vault/state` — the user's vault contents
/// (if any) plus every active `AutoSwapCap` they own. Drives the
/// `AutoSwapSettings` row list.
struct VaultStateResponse: Codable {
    let vault: VaultDTO?
    let caps: [AutoSwapCapDTO]
}

/// On-chain vault summary. `balances` lists each `Balance<T>` sitting
/// in the bag — used by the vault-status card on `AutoSwapSettings`.
struct VaultDTO: Codable {
    let id: String
    let balances: [VaultBalance]
}

/// One coin-balance row inside a vault. `amount` is u64-as-String for
/// BigInt safety; iOS converts to Double for display via
/// `VaultBalance.amountDouble`.
struct VaultBalance: Codable, Identifiable, Hashable {
    let coinType: String
    let amount: String

    var id: String { coinType }

    /// Parse `amount` (raw on-chain units, u64-as-string) into a Double
    /// for headline display. Loses precision past ~2^53 but those
    /// values aren't meaningful at the human-facing tier.
    var amountDouble: Double {
        Double(amount) ?? 0
    }
}

/// Snapshot from `GET /api/vault/migration-status`. Drives the Home-
/// tab upgrade banner for users who pre-date the vault feature — they
/// have a `@talise` subname but no vault yet, or a vault whose subname
/// still resolves to the plain wallet.
struct VaultMigrationStatus: Codable, Hashable {
    let needsMigration: Bool
    let reason: String  // "no-subname" | "no-vault" | "subname-not-repointed" | "done"
    let subname: VaultMigrationSubname?
    let vaultId: String?
}

struct VaultMigrationSubname: Codable, Hashable {
    let id: String
    let fullName: String
    let currentTarget: String?
}

/// One `AutoSwapCap<T>` owned by the user. The presence of a cap for
/// a given `sourceType` is what "auto-swap enabled" means — the
/// `AutoSwapSettings` list reads this array and renders the matching
/// row as toggled-on.
/// Body for `POST /api/vault/migrate-bundle`. `stage` is either
/// `"create-vault"` or `"repoint"`.
struct MigrateBundleRequest: Codable {
    let stage: String
}

/// Response from `POST /api/vault/migrate-bundle`. `bytesB64` /
/// `sender` are nil when the stage is a no-op (already done, or no
/// subname to repoint). Caller short-circuits when `bytesB64 == nil`.
struct MigrateBundleResponse: Codable {
    let ok: Bool
    let stage: String
    let bytesB64: String?
    let sender: String?
    let note: String?
}

/// Body for `POST /api/vault/migrate-confirm`. `vaultId` is required
/// only for the `create-vault` stage.
struct MigrateConfirmRequest: Codable {
    let stage: String
    let vaultId: String?
    let digest: String
}

/// Response from `POST /api/vault/record`. Carries the optional
/// SuiNS repoint PTB — when set, the caller MUST sign + execute it
/// so `name@talise` actually routes to the new vault.
struct VaultRecordResponse: Codable {
    let ok: Bool
    let vaultId: String?
    let repoint: VaultRepointPayload?
}

/// One PTB-build-result describing how to repoint a `*.talise.sui`
/// subname at the user's new vault address. `bytesB64` goes to
/// `ZkLoginCoordinator.signAndSubmit`; the rest of the fields are
/// just informational so the UI can confirm what's about to change.
struct VaultRepointPayload: Codable {
    let bytesB64: String
    let sender: String
    let nftId: String
    let fullName: String
    let currentTarget: String?
    let newTarget: String
}

/// One row in `GET /api/wallet/balances` — one coin type held in the
/// user's PLAIN wallet (not the vault). `amount` is the raw u64 as a
/// string for BigInt safety. Used by the "Convert all to USDsui" sweep
/// CTA to enumerate what's eligible.
struct WalletCoinBalance: Codable, Hashable {
    let coinType: String
    let amount: String
    let isUsdsui: Bool

    /// Raw amount as a Double for ergonomic dust-filtering. Loses
    /// precision past ~2^53 native units, which doesn't matter for the
    /// dust threshold check.
    var amountDouble: Double {
        Double(amount) ?? 0
    }
}

struct WalletBalancesResponse: Codable {
    let address: String
    let balances: [WalletCoinBalance]
}

/// Body for `POST /api/wallet/sweep`. One leg per coin the user wants
/// converted to USDsui. `amount` is the raw u64 in the coin's native
/// decimals, kept as a String over the wire so values approaching `2^53`
/// don't lose precision.
struct WalletSweepRequest: Codable {
    let coins: [WalletSweepCoin]
}

struct WalletSweepCoin: Codable {
    let coinType: String
    let amount: String
}

/// Response from `POST /api/wallet/sweep`. `bytesB64` flows straight into
/// `ZkLoginCoordinator.signAndSubmit`. `estUsdsuiOut` is the quoted USDsui
/// output (raw u64, 6-dp) summed across all legs, net of the 1% fee —
/// used to credit the swap rewards points. Optional so older server
/// builds (that don't return it) still decode cleanly.
struct WalletSweepResponse: Codable {
    let bytesB64: String
    let sender: String?
    let estUsdsuiOut: String?

    /// USD value of the sweep output (USDsui is 1:1 USD, 6 decimals).
    /// 0 when the server didn't return an estimate.
    var estUsdOut: Double {
        guard let raw = estUsdsuiOut, let micros = Double(raw) else { return 0 }
        return micros / 1_000_000
    }
}

struct AutoSwapCapDTO: Codable, Identifiable, Hashable {
    let id: String
    let sourceType: String
    let maxPerSwap: String
    /// Wire format is u64-as-String for BigInt safety — matches every
    /// other u64 field on the response. Earlier this was `UInt64`
    /// which Codable failed to decode (server sent `"0"`, iOS expected
    /// `0`) → "Couldn't read response from server" on any state read
    /// where a cap existed.
    let expiresAtMs: String
    let paused: Bool
    /// True when this cap is a v2-era user-owned mint that needs to be
    /// promoted to a shared object (via `vault::share_existing_cap<T>`)
    /// before the Onara cron worker can reference it. Optional so older
    /// server builds that pre-date the v3 migration field decode without
    /// erroring — older deploys will leave this nil and the UI treats
    /// nil as "no migration needed".
    let needsMigration: Bool?
    /// True when this cap is a v1 `AutoSwapCap<T>` (no per-day throttle).
    /// After the v7 deploy the cron only sweeps `AutoSwapCapV2<T>` caps,
    /// so we surface an Upgrade CTA for any cap flagged here. The server
    /// derives this from the cap's on-chain type tag — if it matches
    /// `…::auto_swap::AutoSwapCap<…>` it's v1; `…::auto_swap::AutoSwapCapV2<…>`
    /// is v2. Optional so older server builds that pre-date the v7 field
    /// decode without erroring — nil is interpreted as "v1 unknown,
    /// don't surface the banner" by `isLegacyV1`.
    let isV1: Bool?

    /// Convenience — flatten the optional so view code can branch on a
    /// simple Bool. `nil → false` mirrors the "old server, no banner"
    /// semantics described above.
    var requiresMigration: Bool { needsMigration ?? false }

    /// True only when the server has explicitly flagged this as a v1
    /// cap. `nil → false` so old server builds that lack the field
    /// don't accidentally surface the Upgrade banner.
    var isLegacyV1: Bool { isV1 ?? false }

    /// Parse the raw expiry string for callers that want a number.
    /// Returns 0 (= no expiry) if the wire value is malformed.
    var expiresAtMsValue: UInt64 {
        UInt64(expiresAtMs) ?? 0
    }

    /// Convenience for the slider display — converts the raw u64 cap
    /// amount to a Double. See `VaultBalance.amountDouble` for the
    /// precision caveat.
    var maxPerSwapDouble: Double {
        Double(maxPerSwap) ?? 0
    }
}

// Sponsor + sponsor-execute request/response shapes are NOT modeled
// as Codable here. ZkLoginCoordinator builds the request bodies as
// `[String: Any]` directly and decodes responses via JSONSerialization
// — the proof object is a nested freeform structure that gets
// stringified if forced through AnyCodable. See ZkLoginCoordinator.swift
// for the actual wire shapes used end-to-end.

/// Minimal AnyCodable for shapes the backend returns as freeform JSON
/// (e.g. the zkLogin proof object). We don't introspect the structure.
struct AnyCodable: Codable {
    let raw: Data

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.raw = "null".data(using: .utf8)!
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self.raw = try JSONEncoder().encode(v)
        } else if let v = try? container.decode([AnyCodable].self) {
            self.raw = try JSONEncoder().encode(v)
        } else if let v = try? container.decode(String.self) {
            self.raw = try JSONEncoder().encode(v)
        } else if let v = try? container.decode(Double.self) {
            self.raw = try JSONEncoder().encode(v)
        } else if let v = try? container.decode(Bool.self) {
            self.raw = try JSONEncoder().encode(v)
        } else {
            self.raw = "null".data(using: .utf8)!
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let any = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
        let data = try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])
        try container.encode(String(data: data, encoding: .utf8) ?? "null")
    }
}
