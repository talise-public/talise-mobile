import SwiftUI

// MARK: - DTOs

private struct StreamEscrowResp: Decodable { let escrowAddress: String }
private struct StreamRecordResp: Decodable { let id: String? }
/// /api/streams/create-prepare response. `mode` selects the funding rail:
///   • "onchain" → sign the sponsor-ready `stream::create` `bytes` via
///     executeSponsorReady; the digest is the create tx the server parses
///     for the on-chain Stream object id.
///   • "gasless" / "sponsored" → fund the `escrowAddress` over the normal
///     send rail (existing flow). All fields optional so every shape parses.
private struct StreamPrepareResp: Decodable {
    let mode: String?
    let bytes: String?
    let escrowAddress: String?
    let error: String?
}
/// /api/streams/[id]/cancel response. On the on-chain rail it returns
/// `mode:"onchain"` + sponsor-ready `bytes` (the sender-signed
/// `cancel_and_withdraw`) for iOS to sign+execute. The escrow rail refunds
/// server-side and just reports `refunded`. All optional so both parse.
private struct StreamCancelResp: Decodable {
    let ok: Bool?
    let state: String?
    let mode: String?
    let bytes: String?
    let refunded: Bool?
    let refundUsd: Double?
}
/// /api/streams/[id]/claim response. On-chain rail returns sponsor-ready
/// `claim_accrued` `bytes` for the caller to sign+execute; `nothingToClaim`
/// when the schedule has nothing newly due.
private struct StreamClaimResp: Decodable {
    let ok: Bool?
    let mode: String?
    let bytes: String?
    let nothingToClaim: Bool?
}
struct StreamDTO: Decodable, Identifiable {
    let id: String
    let state: String
    let role: String?
    let recipientHandle: String?
    let recipientAddress: String?
    let totalUsd: Double?
    let releasedUsd: Double?
    let remainingUsd: Double?
    let tranchesDone: Int?
    let numTranches: Int?
    let nextTrancheAt: Double?
    let startMs: Double?
    let intervalMs: Double?
}
private struct StreamsResp: Decodable { let streams: [StreamDTO] }

// MARK: - Setup flow

struct StreamSetupView: View {
    var onDone: () -> Void
    /// Session-expiry path: an unrecoverable zkLogin session routes to a
    /// clean sign-out → re-auth (mirrors Send) instead of a dead-end error.
    @Environment(AppSession.self) private var session
    @State private var recipientQuery = ""
    @State private var resolved: RecipientResolution?
    @State private var resolving = false
    @State private var amountText = ""
    @State private var durationMin = 60      // default: 1 hour
    @State private var intervalMin = 10      // default: every 10 minutes
    @State private var starting = false
    @State private var error: String?
    @State private var started = false
    @State private var resolveFailed = false
    @State private var resolveTask: Task<Void, Never>?

    private let durations: [(String, Int)] = [("1 hour", 60), ("1 day", 1440), ("1 week", 10080), ("30 days", 43200)]
    private let intervals: [(String, Int)] = [("1 min", 1), ("10 min", 10), ("1 hour", 60), ("1 day", 1440)]

    private var totalUsd: Double { Double(amountText) ?? 0 }
    private var numTranches: Int { max(1, durationMin / max(1, intervalMin)) }
    private var trancheUsd: Double { numTranches > 0 ? totalUsd / Double(numTranches) : 0 }
    private var validSchedule: Bool {
        totalUsd > 0 && trancheUsd >= 0.01 && resolved != nil && numTranches >= 1 && numTranches <= 5000
    }

    var body: some View {
        if started {
            startedView
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    recipientField
                    amountField
                    scheduleCard
                    statusSection
                    if let error { Text(error).font(TaliseFont.body(12)).foregroundStyle(TaliseColor.danger) }
                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 22).padding(.top, 18)
            }
            .background(TaliseColor.bg.ignoresSafeArea())
            .overlay(alignment: .bottom) { startBar }
            .coverDismiss(onDone)
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: "Stream a payment")
            Text("Money over time")
                .font(TaliseFont.heading(24, weight: .medium)).kerning(-0.8).foregroundStyle(TaliseColor.fg)
            Text("Drip a salary, an allowance, a payout — no network fee, Talise sponsors the gas.")
                .font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
        }
    }

    private var recipientField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TO").font(TaliseFont.mono(9)).tracking(1.5).foregroundStyle(TaliseColor.fgDim)
            HStack {
                TextField("@handle or 0x address", text: $recipientQuery)
                    .font(TaliseFont.body(15)).foregroundStyle(TaliseColor.fg)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { scheduleResolve(debounce: false) }
                if resolving { ProgressView().controlSize(.small) }
                else if resolved != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(TaliseColor.accent) }
                else if resolveFailed { Image(systemName: "xmark.circle.fill").foregroundStyle(TaliseColor.danger) }
            }
            Rectangle().fill(TaliseColor.line).frame(height: 1)
            if resolving {
                Text("Looking up recipient…").font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgDim)
            } else if let r = resolved {
                Text("Resolved: \(r.displayString)").font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.accent)
            } else if resolveFailed {
                Text("Couldn't find that recipient. Check the @handle or address.")
                    .font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.danger)
            }
        }
        .onChange(of: recipientQuery) { _, _ in
            resolved = nil; resolveFailed = false
            scheduleResolve(debounce: true)
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TOTAL (USDsui)").font(TaliseFont.mono(9)).tracking(1.5).foregroundStyle(TaliseColor.fgDim)
            HStack {
                Text("$").font(TaliseFont.heading(18)).foregroundStyle(TaliseColor.fgMuted)
                TextField("0.00", text: $amountText).keyboardType(.decimalPad)
                    .font(TaliseFont.display(22, weight: .medium)).foregroundStyle(TaliseColor.fg)
            }
            Rectangle().fill(TaliseColor.line).frame(height: 1)
        }
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            picker("OVER", value: $durationMin, options: durations)
            picker("EVERY", value: $intervalMin, options: intervals)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func picker(_ label: String, value: Binding<Int>, options: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(TaliseFont.mono(9)).tracking(1.5).foregroundStyle(TaliseColor.fgDim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.1) { opt in
                        let on = value.wrappedValue == opt.1
                        Button { value.wrappedValue = opt.1 } label: {
                            Text(opt.0).font(TaliseFont.body(13, weight: on ? .medium : .light))
                                .foregroundStyle(on ? Color(hex: 0x0A130D) : TaliseColor.fg)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(
                                    Capsule().fill(on ? TaliseColor.greenMint : TaliseColor.surface2)
                                )
                                .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Always-visible block under the schedule. When the stream isn't
    /// startable it explains exactly why (no recipient / no amount /
    /// tranche below the gasless minimum); when valid it shows the
    /// existing preview card. The screen never looks empty or dead.
    @ViewBuilder private var statusSection: some View {
        if validSchedule {
            previewCard
        } else {
            statusLine(statusMessage)
        }
    }

    private var statusMessage: String {
        if recipientQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter a recipient — an @handle or a 0x address."
        }
        if resolving { return "Looking up that recipient…" }
        if resolved == nil {
            return "Enter a recipient we can find before streaming."
        }
        if totalUsd <= 0 { return "Enter an amount to stream." }
        if trancheUsd < 0.01 {
            return "Each payment works out to \(TaliseFormat.usd(trancheUsd)) — below the $0.01 minimum. Raise the total or stream less often."
        }
        if numTranches > 5000 {
            return "That's \(numTranches) payments — too many. Stream less often or over a shorter window."
        }
        return "Set a recipient, amount and schedule to start."
    }

    private func statusLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(TaliseColor.fgMuted)
            Text(text)
                .font(TaliseFont.body(12, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(TaliseColor.accent)
                Text("\(numTranches) payments of \(TaliseFormat.usd2(trancheUsd))")
                    .font(TaliseFont.heading(15, weight: .medium)).foregroundStyle(TaliseColor.fg)
            }
            Text("one every \(intervalLabel), finishing in \(durationLabel). First payment fires now.")
                .font(TaliseFont.body(12, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(TaliseFormat.usd2(totalUsd)) total — no network fee, Talise sponsors the gas.")
                .font(TaliseFont.mono(9)).foregroundStyle(TaliseColor.accent)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(TaliseColor.accent.opacity(0.10))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(TaliseColor.accent.opacity(0.22), lineWidth: 1))
    }

    private var startBar: some View {
        SlideToConfirm(title: starting ? "Starting…" : "Slide to start streaming") {
            await start()
        }
        .disabled(!validSchedule || starting)
        .opacity(!validSchedule || starting ? 0.5 : 1)
        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
        .background(LinearGradient(colors: [TaliseColor.bg.opacity(0), TaliseColor.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var startedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 52)).foregroundStyle(TaliseColor.accent)
                .frame(width: 96, height: 96)
                .background(Circle().fill(TaliseColor.accent.opacity(0.16)))
            Text("Streaming started").font(TaliseFont.heading(22, weight: .medium)).foregroundStyle(TaliseColor.fg)
            Text("\(TaliseFormat.usd2(totalUsd)) to \(resolved?.displayString ?? "recipient") · \(numTranches) payments")
                .font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted).multilineTextAlignment(.center).padding(.horizontal, 30)
            Spacer()
            LiquidGlassButton(title: "Done", tint: TaliseColor.greenMint, action: onDone)
                .padding(.horizontal, 22).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaliseColor.bg.ignoresSafeArea())
    }

    private var intervalLabel: String { intervals.first { $0.1 == intervalMin }?.0 ?? "\(intervalMin) min" }
    private var durationLabel: String { durations.first { $0.1 == durationMin }?.0 ?? "\(durationMin) min" }

    /// Resolve the recipient automatically as the user types (debounced)
    /// and immediately on submit. Cancels any in-flight lookup so the
    /// latest query always wins and the inline state never lies.
    private func scheduleResolve(debounce: Bool) {
        resolveTask?.cancel()
        let q = recipientQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { resolving = false; return }
        resolveTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 400_000_000) // ~0.4s
                if Task.isCancelled { return }
            }
            await resolve(q)
        }
    }

    private func resolve(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        resolving = true; resolveFailed = false
        defer { resolving = false }
        do {
            let r: RecipientResolution = try await APIClient.shared.get(
                "/api/recipient/resolve?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)"
            )
            if Task.isCancelled { return }
            // Guard against a stale response landing after the field changed.
            guard q == recipientQuery.trimmingCharacters(in: .whitespaces) else { return }
            resolved = r; resolveFailed = false
        } catch {
            if Task.isCancelled || APIError.isCancellation(error) { return }
            guard q == recipientQuery.trimmingCharacters(in: .whitespaces) else { return }
            resolved = nil; resolveFailed = true
        }
    }

    private func start() async {
        guard let to = resolved?.address, validSchedule else { return }
        starting = true; error = nil; defer { starting = false }
        let totalMicros = Int((totalUsd * 1_000_000).rounded())
        let trancheMicros = totalMicros / numTranches
        let intervalMs = intervalMin * 60_000
        let now = Int(Date().timeIntervalSince1970 * 1000)
        do {
            // Build the funding tx. The server picks the rail and returns `mode`:
            //   • "onchain" → sign the sponsor-ready `stream::create` bytes via
            //     executeSponsorReady (Onara pays gas); the digest is the create
            //     tx the server parses for the on-chain Stream object id.
            //   • "gasless" / "sponsored" → fund the escrow address over the
            //     normal send rail, exactly as before.
            struct PrepareBody: Encodable {
                let to: String; let totalUsd: Double; let intervalMs: Int; let numTranches: Int
            }
            let prep: StreamPrepareResp = try await APIClient.shared.post(
                "/api/streams/create-prepare",
                body: PrepareBody(to: to, totalUsd: totalUsd, intervalMs: intervalMs, numTranches: numTranches)
            )
            if let serverErr = prep.error, !serverErr.isEmpty {
                self.error = serverErr; return
            }

            let sent: ZkLoginCoordinator.SignedSubmission
            let counterparty: String
            if prep.mode == "onchain", let bytes = prep.bytes {
                sent = try await ZkLoginCoordinator.shared.executeSponsorReady(
                    bytesB64: bytes, intent: "Start stream"
                )
                counterparty = to
            } else {
                // Escrow rail: fund the escrow address over the normal send rail.
                // create-prepare already returns the escrow address in its plan;
                // fall back to /api/streams/escrow only if it's somehow absent.
                let escrowAddr: String
                if let addr = prep.escrowAddress {
                    escrowAddr = addr
                } else {
                    let escrow: StreamEscrowResp = try await APIClient.shared.get("/api/streams/escrow")
                    escrowAddr = escrow.escrowAddress
                }
                sent = try await ZkLoginCoordinator.shared.signAndSubmitSend(
                    to: escrowAddr, amountUsd: totalUsd, intent: "Start stream"
                )
                counterparty = escrowAddr
            }
            struct RecordBody: Encodable {
                let fundingDigest: String; let recipientAddress: String; let recipientHandle: String?
                let totalMicros: String; let trancheMicros: String; let numTranches: Int
                let startMs: Int; let intervalMs: Int
            }
            let _: StreamRecordResp = try await APIClient.shared.post(
                "/api/streams/record",
                body: RecordBody(fundingDigest: sent.digest, recipientAddress: to,
                                 recipientHandle: resolved?.displayName,
                                 totalMicros: String(totalMicros), trancheMicros: String(trancheMicros),
                                 numTranches: numTranches, startMs: now, intervalMs: intervalMs)
            )
            _ = counterparty // funding-leg destination (escrow addr or recipient)
            NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                digest: sent.digest, direction: "sent", amountUsdsui: totalUsd,
                counterparty: to, counterpartyName: "Stream", venue: nil))
            withAnimation { started = true }
        } catch APIError.status(let code, let msg) {
            self.error = Self.friendlyStreamError(code: code, message: msg)
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            self.error = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't start the stream right now."
        }
    }

    /// Map "backend isn't live yet" responses (404 / 503 / "not
    /// configured" / "disabled") to reassuring copy. Real, actionable
    /// server messages still pass through verbatim.
    static func friendlyStreamError(code: Int, message: String?) -> String {
        let lower = (message ?? "").lowercased()
        let rolloutPhrase = lower.contains("not configured") || lower.contains("disabled")
            || lower.contains("not found") || lower.contains("unavailable")
        if code == 404 || code == 503 || rolloutPhrase {
            return "Streaming is rolling out — check back soon."
        }
        if let msg = message, !msg.isEmpty { return msg }
        return "Couldn't start the stream right now."
    }
}

// MARK: - Active streams list

struct StreamsListView: View {
    var onDone: () -> Void
    @Environment(AppSession.self) private var session
    @State private var streams: [StreamDTO] = []
    @State private var loading = true
    @State private var cancellingId: String?
    @State private var claimingId: String?
    @State private var cancelError: String?
    /// Streams already auto-claimed this view session, so opening the list
    /// pulls accrued funds once per stream rather than re-firing on every refresh.
    @State private var autoClaimed: Set<String> = []
    /// Tranches claimed per stream this session — drives the "next claim in Xs"
    /// cooldown so the button locks until the next tranche is actually due.
    @State private var claimedMark: [String: Int] = [:]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Your streams")
                if loading {
                    ProgressView().tint(TaliseColor.fg).frame(maxWidth: .infinity).padding(.top, 40)
                } else if streams.isEmpty {
                    VStack(spacing: 6) {
                        Text("No streams yet").font(TaliseFont.body(14)).foregroundStyle(TaliseColor.fg)
                        Text("Start one to drip money over time.").font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgDim)
                    }.frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    ForEach(streams) { s in streamRow(s) }
                }
                if let cancelError {
                    Text(cancelError).font(TaliseFont.body(12)).foregroundStyle(TaliseColor.danger)
                }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 30)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .coverDismiss(onDone)
        .presentationDragIndicator(.visible)
        .task { await load(); await autoClaimAccrued() }
    }

    /// Auto-pull accrued tranches for every incoming stream when the recipient
    /// opens the list — so funds land without a manual tap (still just the
    /// on-chain Clock + claim_accrued, no cron). Best-effort + silent: once per
    /// stream per session, only when something has accrued, and the manual
    /// "Claim available" button stays for later accruals. Refreshes once after.
    private func autoClaimAccrued() async {
        var claimedAny = false
        for s in streams where s.role == "recipient"
            && s.state == "active"
            && (s.tranchesDone ?? 0) > 0
            && !autoClaimed.contains(s.id) {
            autoClaimed.insert(s.id)
            if await silentClaim(s) { claimedAny = true }
        }
        if claimedAny { await load() }
    }

    /// Silent claim for the auto path — no button spinner, no error surfaced.
    /// Returns true if a claim tx was actually executed.
    private func silentClaim(_ s: StreamDTO) async -> Bool {
        struct ClaimBody: Encodable {}
        do {
            let r: StreamClaimResp = try await APIClient.shared.post(
                "/api/streams/\(s.id)/claim", body: ClaimBody()
            )
            if r.mode == "onchain", let bytes = r.bytes {
                _ = try await ZkLoginCoordinator.shared.executeSponsorReady(
                    bytesB64: bytes, intent: "Claim stream"
                )
                claimedMark[s.id] = liveAccrued(s)
                NotificationCenter.default.post(name: .taliseHomeShouldRefresh, object: nil)
                return true
            }
        } catch {
            // Best-effort: a session lapse or build hiccup just leaves the
            // manual Claim button as the fallback. Never surfaced.
        }
        return false
    }

    private func streamRow(_ s: StreamDTO) -> some View {
        let total = s.totalUsd ?? 0
        let released = s.releasedUsd ?? 0
        let progress = total > 0 ? min(1, released / total) : 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.role == "recipient" ? "Streaming in" : "Streaming out")
                        .font(TaliseFont.mono(9)).tracking(1).foregroundStyle(TaliseColor.fgDim)
                    Text(s.recipientHandle ?? shortAddr(s.recipientAddress))
                        .font(TaliseFont.heading(15, weight: .medium)).foregroundStyle(TaliseColor.fg).lineLimit(1)
                }
                Spacer()
                Text(s.state.capitalized).font(TaliseFont.mono(9))
                    .foregroundStyle(s.state == "active" ? TaliseColor.accent : TaliseColor.fgMuted)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(TaliseColor.surface2))
                    .clipShape(Capsule())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06)).frame(height: 6)
                    Capsule().fill(TaliseColor.greenMint).frame(width: geo.size.width * progress, height: 6)
                }
            }.frame(height: 6)
            HStack {
                Text("\(TaliseFormat.usd2(released)) of \(TaliseFormat.usd2(total))")
                    .font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgMuted)
                Spacer()
                Text("\(s.tranchesDone ?? 0)/\(s.numTranches ?? 0) payments")
                    .font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgDim)
            }
            // Recipient: pull the funds the Clock has accrued. Streaming is
            // CLOCK-BASED + cron-less — the contract has released tranches over
            // time, and this claim transfers everything now due into the
            // recipient's wallet (Onara-sponsored, free). Idempotent: claim as
            // often as you like; it only ever moves what's newly accrued.
            // Recipient claim with a live cooldown: "Claim available" while a
            // tranche is due, otherwise "Next claim in Xs" — locked until the
            // next tranche's on-chain Clock time. Re-evaluated every second.
            if s.role == "recipient", s.state == "active" {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    claimControl(s)
                }
                .padding(.top, 4)
            }
            // Sender-only cancel on a live stream. Stops further releases and
            // returns the undistributed remainder to the sender.
            if s.role != "recipient", s.state == "active" || s.state == "paused" {
                LiquidGlassButton(
                    title: cancellingId == s.id ? "Cancelling…" : "Cancel & refund remainder",
                    icon: cancellingId == s.id ? nil : "stop.circle",
                    tint: nil,
                    size: .md,
                    loading: cancellingId == s.id
                ) { Task { await cancel(s) } }
                    .disabled(cancellingId != nil)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Cancel a stream (sender-only). The server flips the row to cancelled,
    /// then EITHER refunds the remainder server-side (escrow rail) OR returns
    /// sponsor-ready `cancel_and_withdraw` bytes for the sender to sign
    /// (on-chain rail) — only the sender's zkLogin can withdraw the on-chain
    /// remainder. We sign+execute those bytes via executeSponsorReady.
    private func cancel(_ s: StreamDTO) async {
        cancellingId = s.id; cancelError = nil
        defer { cancellingId = nil }
        struct CancelBody: Encodable {}
        do {
            let r: StreamCancelResp = try await APIClient.shared.post(
                "/api/streams/\(s.id)/cancel", body: CancelBody()
            )
            if r.mode == "onchain", let bytes = r.bytes {
                let sent = try await ZkLoginCoordinator.shared.executeSponsorReady(
                    bytesB64: bytes, intent: "Cancel stream"
                )
                if let refund = r.refundUsd, refund > 0 {
                    NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                        digest: sent.digest, direction: "received", amountUsdsui: refund,
                        counterparty: nil, counterpartyName: "Stream refund", venue: nil))
                }
            }
            await load()
        } catch APIError.status(let code, let msg) {
            cancelError = StreamSetupView.friendlyStreamError(code: code, message: msg)
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            cancelError = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            cancelError = "Couldn't cancel the stream right now."
        }
    }

    /// Recipient claim: pull the Clock-accrued tranches into the wallet. The
    /// server builds the Onara-sponsored `stream::claim_accrued` PTB; we sign +
    /// execute it. The on-chain contract only ever pays the hardwired recipient,
    /// so this is safe even though the call is permissionless.
    private func claim(_ s: StreamDTO) async {
        claimingId = s.id; cancelError = nil
        defer { claimingId = nil }
        struct ClaimBody: Encodable {}
        do {
            let r: StreamClaimResp = try await APIClient.shared.post(
                "/api/streams/\(s.id)/claim", body: ClaimBody()
            )
            if r.mode == "onchain", let bytes = r.bytes {
                _ = try await ZkLoginCoordinator.shared.executeSponsorReady(
                    bytesB64: bytes, intent: "Claim stream"
                )
                // Pulled everything due as of now → lock the button until the
                // next tranche's clock time.
                claimedMark[s.id] = liveAccrued(s)
                NotificationCenter.default.post(name: .taliseHomeShouldRefresh, object: nil)
            }
            await load()
        } catch APIError.status(let code, let msg) {
            cancelError = StreamSetupView.friendlyStreamError(code: code, message: msg)
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            cancelError = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            cancelError = "Couldn't claim the stream right now."
        }
    }

    /// The Claim button / cooldown for one incoming stream, recomputed every
    /// second by the enclosing TimelineView.
    @ViewBuilder
    private func claimControl(_ s: StreamDTO) -> some View {
        let num = s.numTranches ?? 0
        let accrued = liveAccrued(s)
        let claimed = claimedMark[s.id] ?? 0
        if accrued > claimed {
            // A tranche is due now — claimable.
            LiquidGlassButton(
                title: claimingId == s.id ? "Claiming…" : "Claim available",
                icon: claimingId == s.id ? nil : "arrow.down.circle",
                tint: TaliseColor.greenMint,
                size: .md,
                loading: claimingId == s.id
            ) { Task { await claim(s) } }
                .disabled(claimingId != nil)
        } else if claimed < num {
            // Nothing due yet — count down to the next tranche's clock time.
            let nowMs = Date().timeIntervalSince1970 * 1000
            let secs = max(0, Int(((nextDueMs(s, accrued: accrued) - nowMs) / 1000).rounded(.up)))
            lockedClaimButton("Next claim in \(countdownLabel(secs))")
        } else {
            lockedClaimButton("Fully streamed")
        }
    }

    private func lockedClaimButton(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(.system(size: 14, weight: .medium))
            Text(title).font(TaliseFont.body(15, weight: .medium))
        }
        .foregroundStyle(TaliseColor.fgMuted)
        .frame(maxWidth: .infinity).frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(TaliseColor.surface2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Tranches the on-chain Clock has released by now (mirrors the contract +
    /// the server's projection). Falls back to the server-sent count if the
    /// schedule fields are missing.
    private func liveAccrued(_ s: StreamDTO) -> Int {
        let num = s.numTranches ?? 0
        guard let start = s.startMs, let interval = s.intervalMs, interval > 0, num > 0 else {
            return s.tranchesDone ?? 0
        }
        let now = Date().timeIntervalSince1970 * 1000
        if now < start { return 0 }
        let due = Int((now - start) / interval) + 1   // first tranche fires at start
        return max(0, min(num, due))
    }

    /// Clock time the NEXT (yet-unaccrued) tranche becomes due.
    private func nextDueMs(_ s: StreamDTO, accrued: Int) -> Double {
        (s.startMs ?? 0) + Double(accrued) * (s.intervalMs ?? 0)
    }

    private func countdownLabel(_ secs: Int) -> String {
        secs >= 60 ? "\(secs / 60)m \(secs % 60)s" : "\(secs)s"
    }

    private func shortAddr(_ a: String?) -> String {
        guard let a, a.count > 10 else { return a ?? "—" }
        return "\(a.prefix(6))…\(a.suffix(4))"
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let r: StreamsResp = try await APIClient.shared.get("/api/streams")
            streams = r.streams
        } catch { streams = [] }
    }
}
