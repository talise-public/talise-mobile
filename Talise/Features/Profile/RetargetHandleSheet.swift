import Foundation
import SwiftUI

/// Bottom sheet that lets the user re-point every `*.talise.sui` subname
/// they own at their current wallet address.
///
/// Replaces the manual `scripts/fix-suins-targets.mjs` operator runbook
/// — runs as an Onara-sponsored PTB through `/api/handle/retarget` +
/// `/api/zk/sponsor-execute`, so the user pays nothing.
///
/// Flow:
///   1. On appear: POST /api/handle/retarget?probe=1 — server returns
///      the per-name diff (current target vs the user's wallet) without
///      building a PTB.
///   2. Render each name with a red ✗ (needs update) or green ✓
///      (aligned) badge. If every name is already aligned, show a
///      green "everything aligned" state with no CTA.
///   3. Tap the CTA → POST /api/handle/retarget (no probe) → returns
///      sponsored PTB bytes → sign locally via ZkLoginCoordinator's
///      Ed25519 path → submit via /api/zk/sponsor-execute with
///      `meta.kind = "retarget"`.
///   4. On success, re-probe and auto-dismiss after 2s with every name
///      flipped to green.
///   5. On failure, surface the server error verbatim (mirrors the
///      SendFailureView approach).
struct RetargetHandleSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var diff: [NameRow] = []
    /// Server-reported alignment state from the most recent probe.
    /// Drives the "already aligned" copy + suppresses the CTA when
    /// there's nothing to do.
    @State private var alreadyAligned: Bool = false
    @State private var errorMessage: String?
    @State private var submitting = false

    enum Phase {
        case loading
        case ready
        case success
        case failed
    }

    struct NameRow: Identifiable, Equatable {
        let nft: String
        let name: String
        let fromTarget: String?
        var aligned: Bool
        var id: String { nft }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch phase {
            case .loading:
                loadingView
            case .ready, .success, .failed:
                content
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .liquidGlassSheet()
        .presentationDragIndicator(.visible)
        .task { await loadDiff(initial: true) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel(text: "Handle target", color: TaliseColor.fgDim).kerning(1.5)
            Text("Point your @handle at this wallet")
                .font(TaliseFont.heading(22, weight: .medium))
                .kerning(-0.6)
                .foregroundStyle(TaliseColor.fg)
            Text("Re-targets every *.talise.sui subname you own at your current Sui address. No network fee — Talise sponsors the gas.")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .padding(.top, 2)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(TaliseColor.fgMuted)
                Text("Checking your handles…")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
            .padding(.vertical, 24)
        }
    }

    // MARK: - Content (ready / success / failed share the same row list)

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if diff.isEmpty {
                // Zero owned .talise.sui NFTs — most signed-in users
                // who haven't claimed a handle yet.
                emptyState
            } else {
                ForEach(diff) { row in
                    nameRowView(row)
                }
                if alreadyAligned || phase == .success {
                    alignedBanner
                } else {
                    ctaButton
                }
            }
            if let msg = errorMessage {
                Text(msg)
                    .font(TaliseFont.body(12, weight: .light))
                    .foregroundStyle(TaliseColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyState: some View {
        Text("You don't own any *.talise.sui handles. Claim one from your profile first.")
            .font(TaliseFont.body(13, weight: .light))
            .foregroundStyle(TaliseColor.fgMuted)
            .padding(.vertical, 12)
    }

    /// One row per owned subname. Renders as
    /// `name.talise.sui → 0xabcd…1234  ✓ aligned`
    /// (green when aligned, red ✗ when the target points at the OLD
    /// address). Uses the same `TaliseColor` + `TaliseFont` design
    /// tokens as the rest of Profile so the sheet matches.
    private func nameRowView(_ row: NameRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(TaliseFont.mono(13, weight: .light))
                    .foregroundStyle(TaliseColor.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(TaliseColor.fgDim)
                    Text(row.fromTarget.map(Self.shortAddress) ?? "(no target)")
                        .font(TaliseFont.mono(11, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                }
            }
            Spacer()
            badge(for: row)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSection(
            cornerRadius: 16,
            tint: row.aligned ? TaliseColor.accent : TaliseColor.danger,
            tintOpacity: 0.06
        )
    }

    @ViewBuilder
    private func badge(for row: NameRow) -> some View {
        if row.aligned {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("aligned")
                    .font(TaliseFont.body(11, weight: .light))
            }
            .foregroundStyle(TaliseColor.accent)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("stale")
                    .font(TaliseFont.body(11, weight: .light))
            }
            .foregroundStyle(TaliseColor.danger)
        }
    }

    private var alignedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(TaliseColor.accent)
            Text(phase == .success
                 ? "Updated. Closing…"
                 : "Every handle already points at this wallet.")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
        }
        .padding(.vertical, 6)
    }

    private var ctaButton: some View {
        LiquidGlassButton(
            title: submitting
                ? "Updating…"
                : "Update target(s) — Talise sponsors the gas",
            icon: submitting ? nil : "arrow.uturn.right.circle.fill",
            tint: TaliseColor.greenMint,
            loading: submitting
        ) {
            Task { await submit() }
        }
        .disabled(submitting)
        .padding(.top, 4)
    }

    // MARK: - Networking

    private struct ProbeResponse: Decodable {
        let alreadyAligned: Bool?
        let names: [ProbeName]?
    }
    private struct ProbeName: Decodable {
        let nft: String
        let name: String
        let fromTarget: String?
    }

    private struct BuildResponse: Decodable {
        let alreadyAligned: Bool?
        let bytes: String?
        let mode: String?
        let names: [ProbeName]?
    }

    /// Probe the server for the per-name diff. Called on appear, and
    /// again after a successful submit so the rows flip to green.
    private func loadDiff(initial: Bool) async {
        if initial { phase = .loading }
        errorMessage = nil
        do {
            let resp: ProbeResponse = try await APIClient.shared.post(
                "/api/handle/retarget?probe=1",
                body: EmptyBody()
            )
            let myAddress: String = {
                if case .ready(let user) = session.phase {
                    return user.suiAddress.lowercased()
                }
                return ""
            }()
            let rows: [NameRow] = (resp.names ?? []).map { n in
                NameRow(
                    nft: n.nft,
                    name: n.name,
                    fromTarget: n.fromTarget,
                    aligned: (n.fromTarget?.lowercased() ?? "") == myAddress
                )
            }
            self.diff = rows
            self.alreadyAligned = resp.alreadyAligned ?? rows.allSatisfy { $0.aligned }
            self.phase = .ready
        } catch APIError.status(_, let msg) {
            self.errorMessage = msg ?? "Couldn't read your handles."
            self.phase = .failed
        } catch {
            self.errorMessage = error.localizedDescription
            self.phase = .failed
        }
    }

    /// Build path: POST without `?probe=1`, sign the returned bytes
    /// with the ephemeral key, then submit via /api/zk/sponsor-execute
    /// with `meta.kind = "retarget"`. Mirrors the
    /// `ZkLoginCoordinator.consolidateToAccumulator` sign+submit
    /// dance — only the prepare path and meta-kind differ.
    private func submit() async {
        guard !submitting else { return }
        submitting = true
        errorMessage = nil
        defer { submitting = false }

        do {
            let prep: [String: Any] = try await postRaw(
                "/api/handle/retarget",
                body: EmptyBody()
            )

            if let aligned = prep["alreadyAligned"] as? Bool, aligned {
                // Server changed its mind between probe and build —
                // race-safe no-op. Just refresh.
                await loadDiff(initial: false)
                phase = .success
                Task { await closeAfterDelay() }
                return
            }

            guard let bytesB64 = prep["bytes"] as? String else {
                throw APIError.invalidResponse
            }

            let digest = try await ZkLoginCoordinator.shared.signAndExecuteRaw(
                bytesB64: bytesB64,
                meta: ["kind": "retarget"]
            )
            // Best-effort log — surfacing the digest in the console
            // matches what consolidate / send paths do.
            print("[retarget] digest=\(digest)")

            // Refresh the diff so the rows flip to green, then
            // auto-dismiss.
            await loadDiff(initial: false)
            phase = .success
            Task { await closeAfterDelay() }
        } catch APIError.status(_, let msg) {
            errorMessage = msg ?? "Couldn't update target."
            phase = .failed
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    private func closeAfterDelay() async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await MainActor.run { dismiss() }
    }

    // MARK: - Helpers

    private struct EmptyBody: Encodable {}

    /// Issue a POST and return the decoded JSON object as a raw
    /// `[String: Any]`. `APIClient.post` requires a `Decodable` return
    /// type — but the retarget build path has a polymorphic response
    /// (either `{ alreadyAligned: true, ... }` or `{ bytes, mode, ...}`).
    /// We decode through `JSONSerialization` to keep both shapes
    /// handle-able in a single call site.
    private func postRaw(_ path: String, body: EmptyBody) async throws -> [String: Any] {
        struct AnyJSON: Decodable {}
        // The APIClient's typed `post` insists on decoding into T —
        // we hop into the same network primitive via a fake decode and
        // catch the decoding error to peek at the raw body. Simpler:
        // re-issue through the same client with a passthrough decoder.
        let raw: PassthroughJSON = try await APIClient.shared.post(path, body: body)
        return raw.value
    }

    /// 0x1234…5678 — 6 leading + 4 trailing hex chars. Mirrors the
    /// `shortAddress` helper in `SendFlowView` / `SendRecipientView`
    /// (duplicated locally so this sheet can compile without dragging
    /// a Send-Flow file in as a dependency).
    private static func shortAddress(_ a: String) -> String {
        guard a.count > 10 else { return a }
        let prefix = a.prefix(6)
        let suffix = a.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}

/// `Decodable` shim that just stashes the JSON object as a
/// `[String: Any]`. Used by `RetargetHandleSheet.postRaw` to keep a
/// single decode pass while accepting both the "already aligned" and
/// "sponsored bytes" response shapes.
struct PassthroughJSON: Decodable {
    let value: [String: Any]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // The route always returns a JSON object at the top level — if
        // it ever returned a primitive we'd surface a typeMismatch and
        // bubble up to the catch block as a clean error.
        if let dict = try? container.decode([String: AnyCodableValue].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.typeMismatch(
                [String: Any].self,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "expected JSON object"
                )
            )
        }
    }
}

/// Tiny Codable wrapper used by `PassthroughJSON` to walk a JSON value
/// of unknown shape. Only the cases we'll actually hit in the retarget
/// response (string / number / bool / null / array / nested object) are
/// implemented — anything else falls through to `null`.
private struct AnyCodableValue: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = NSNull()
        } else if let v = try? c.decode(Bool.self) {
            value = v
        } else if let v = try? c.decode(Int.self) {
            value = v
        } else if let v = try? c.decode(Double.self) {
            value = v
        } else if let v = try? c.decode(String.self) {
            value = v
        } else if let v = try? c.decode([AnyCodableValue].self) {
            value = v.map { $0.value }
        } else if let v = try? c.decode([String: AnyCodableValue].self) {
            value = v.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
}
