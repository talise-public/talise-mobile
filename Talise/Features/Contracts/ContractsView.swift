import SwiftUI

// MARK: - DTOs (match /api/contracts, /api/contracts/[id])

/// A Work contract — milestone/recurring pay wrapping an underlying stream.
/// Mirrors `ProjectedContract` from GET /api/contracts.
struct ContractDTO: Decodable, Identifiable {
    let id: String
    let payeeAddress: String
    let payeeHandle: String?
    let title: String
    let rateUsd: Double
    let cadence: String          // hourly | daily | weekly | monthly
    let cadenceLabel: String?
    let periods: Int
    let totalUsd: Double
    let streamId: String
    let status: String           // active | completed | cancelled
    let createdAt: Double
    let paidUsd: Double?
    let remainingUsd: Double?
    let periodsPaid: Int?
    let nextPayAt: Double?
    let streamState: String?
}

private struct ContractsListResp: Decodable { let contracts: [ContractDTO] }
private struct ContractCreateResp: Decodable { let ok: Bool; let contract: ContractDTO? }
/// POST /api/contracts/[id] {action:"cancel"}. On the escrow rail the server
/// refunds the remainder; on the on-chain rail it returns `onchainCancelPath`
/// pointing at the stream cancel endpoint the sender must sign.
private struct ContractCancelResp: Decodable {
    let ok: Bool?
    let status: String?
    let refunded: Bool?
    let refundUsd: Double?
    let onchainCancelPath: String?
}

// MARK: - Reused stream prepare/record/cancel DTOs

private struct CtrStreamPrepareResp: Decodable {
    let mode: String?
    let bytes: String?
    let escrowAddress: String?
    let error: String?
}
private struct CtrStreamRecordResp: Decodable { let id: String? }
private struct CtrStreamEscrowResp: Decodable { let escrowAddress: String }
private struct CtrStreamCancelResp: Decodable {
    let mode: String?
    let bytes: String?
    let refundUsd: Double?
}

// MARK: - Contracts hub (list + create + cancel)

struct ContractsView: View {
    var onDone: () -> Void
    /// Session-expiry path: an unrecoverable zkLogin session routes to a
    /// clean sign-out → re-auth (mirrors Send) instead of a dead-end error.
    @Environment(AppSession.self) private var session
    @State private var rows: [ContractDTO] = []
    @State private var loading = true
    @State private var error: String?
    @State private var creating = false
    @State private var cancelling: Set<String> = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                LiquidGlassButton(
                    title: "New contract", icon: "plus",
                    tint: TaliseColor.greenMint, size: .md
                ) { creating = true }

                if loading {
                    loadingState
                } else if let error {
                    errorState(error)
                } else if rows.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 12) { ForEach(rows) { contractRow($0) } }
                }
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 22).padding(.top, 18)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task { await load() }
        .fullScreenCover(isPresented: $creating) {
            CreateContractView {
                creating = false
                Task { await load() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Contracts")
                Text("Hire & pay over time")
                    .font(TaliseFont.heading(24, weight: .medium)).kerning(-0.8).foregroundStyle(TaliseColor.fg)
                Text("Set a rate and a number of periods. Payments drip automatically — no network fee.")
                    .font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
            }
            Spacer()
            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(TaliseColor.fg)
                    .frame(width: 32, height: 32).background(Circle().fill(TaliseColor.surface2)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(TaliseColor.surface).frame(height: 110).redacted(reason: .placeholder)
            }
        }.overlay(ProgressView().tint(TaliseColor.fgMuted))
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Text(msg).font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted).multilineTextAlignment(.center)
            LiquidGlassButton(title: "Try again", tint: nil, size: .md, fullWidth: false) { Task { await load() } }
        }.frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.below.ecg")
                .font(.system(size: 40, weight: .light)).foregroundStyle(TaliseColor.fgDim)
            Text("No contracts yet").font(TaliseFont.heading(18, weight: .medium)).foregroundStyle(TaliseColor.fg)
            Text("Create one to pay a contractor or employee on a schedule.")
                .font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }.frame(maxWidth: .infinity).padding(.top, 50)
    }

    private func contractRow(_ c: ContractDTO) -> some View {
        let paid = c.paidUsd ?? 0
        let progress = c.totalUsd > 0 ? min(1, paid / c.totalUsd) : 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(TaliseFont.heading(16, weight: .medium)).foregroundStyle(TaliseColor.fg).lineLimit(1)
                    Text("\(c.payeeHandle ?? shortAddr(c.payeeAddress)) · \(TaliseFormat.usd2(c.rateUsd)) / \(c.cadenceLabel ?? c.cadence)")
                        .font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgDim).lineLimit(1)
                }
                Spacer()
                statusPill(c.status)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06)).frame(height: 6)
                    Capsule().fill(TaliseColor.greenMint).frame(width: geo.size.width * progress, height: 6)
                }
            }.frame(height: 6)
            HStack {
                Text("\(TaliseFormat.usd2(paid)) of \(TaliseFormat.usd2(c.totalUsd))")
                    .font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgMuted)
                Spacer()
                Text("\(c.periodsPaid ?? 0)/\(c.periods) periods").font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgDim)
            }
            if c.status == "active" {
                LiquidGlassButton(
                    title: cancelling.contains(c.id) ? "Cancelling…" : "Cancel & refund remainder",
                    icon: cancelling.contains(c.id) ? nil : "stop.circle",
                    tint: nil, size: .md, loading: cancelling.contains(c.id)
                ) { Task { await cancel(c) } }
                    .disabled(!cancelling.isEmpty).padding(.top, 4)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TaliseColor.surface))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func statusPill(_ status: String) -> some View {
        let tint: Color
        switch status {
        case "active": tint = TaliseColor.accent
        case "completed": tint = TaliseColor.greenMint
        default: tint = TaliseColor.fgDim
        }
        return Text(status.capitalized)
            .font(TaliseFont.mono(9, weight: .light)).kerning(0.6).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(tint.opacity(0.15)))
    }

    private func shortAddr(_ a: String) -> String {
        a.count > 10 ? "\(a.prefix(6))…\(a.suffix(4))" : a
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let resp: ContractsListResp = try await APIClient.shared.get("/api/contracts")
            rows = resp.contracts.sorted { $0.createdAt > $1.createdAt }
        } catch APIError.status(let code, let msg) {
            error = friendlyWorkError(code: code, message: msg, noun: "contracts")
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't load your contracts right now."
        }
    }

    /// Cancel a contract. The server stops the stream + flips status, then
    /// EITHER refunds server-side (escrow rail) OR points us at the stream
    /// cancel endpoint to sign the on-chain withdrawal (on-chain rail).
    private func cancel(_ c: ContractDTO) async {
        guard cancelling.isEmpty else { return }
        cancelling.insert(c.id); error = nil
        defer { cancelling.remove(c.id) }
        struct Body: Encodable { let action = "cancel" }
        do {
            let r: ContractCancelResp = try await APIClient.shared.post(
                "/api/contracts/\(c.id)", body: Body()
            )
            // On-chain rail: sign the sender-only withdrawal via the stream cancel endpoint.
            if let path = r.onchainCancelPath {
                struct Empty: Encodable {}
                let cancel: CtrStreamCancelResp = try await APIClient.shared.post(path, body: Empty())
                if cancel.mode == "onchain", let bytes = cancel.bytes {
                    let sent = try await ZkLoginCoordinator.shared.executeSponsorReady(
                        bytesB64: bytes, intent: "Cancel contract"
                    )
                    if let refund = cancel.refundUsd ?? r.refundUsd, refund > 0 {
                        NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                            digest: sent.digest, direction: "received", amountUsdsui: refund,
                            counterparty: nil, counterpartyName: "Contract refund", venue: nil))
                    }
                }
            } else if let refund = r.refundUsd, refund > 0, r.refunded == true {
                // Escrow rail refunded server-side — reflect it in activity.
                NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                    digest: "contract-refund-\(c.id)", direction: "received", amountUsdsui: refund,
                    counterparty: nil, counterpartyName: "Contract refund", venue: nil))
            }
            await load()
        } catch APIError.status(let code, let msg) {
            error = friendlyWorkError(code: code, message: msg, noun: "contract")
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            error = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't cancel the contract right now."
        }
    }
}

// MARK: - Create contract

private struct CreateContractView: View {
    var onClose: () -> Void
    @Environment(AppSession.self) private var session
    @State private var recipientQuery = ""
    @State private var resolved: RecipientResolution?
    @State private var resolving = false
    @State private var resolveFailed = false
    @State private var resolveTask: Task<Void, Never>?

    @State private var title = ""
    @State private var rateText = ""
    @State private var cadence = "weekly"
    @State private var periodsText = "4"

    @State private var creating = false
    @State private var error: String?
    @State private var created = false

    private let cadences: [(String, String)] = [("Hour", "hourly"), ("Day", "daily"), ("Week", "weekly"), ("Month", "monthly")]
    /// cadence → interval in minutes (a month is a flat 30 days).
    private let cadenceMinutes: [String: Int] = ["hourly": 60, "daily": 1440, "weekly": 10080, "monthly": 43200]

    private var rateUsd: Double { Double(rateText) ?? 0 }
    private var periods: Int { Int(periodsText) ?? 0 }
    private var totalUsd: Double { rateUsd * Double(periods) }
    private var canCreate: Bool {
        resolved != nil && !title.isEmpty && rateUsd >= 0.01 && periods >= 1 && (totalUsd / Double(max(1, periods))) >= 0.01
    }

    var body: some View {
        NavigationStack {
            if created {
                successView
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        recipientField
                        fieldsCard
                        previewCard
                        if let error { Text(error).font(TaliseFont.body(12)).foregroundStyle(TaliseColor.danger) }
                        Color.clear.frame(height: 90)
                    }
                    .padding(.horizontal, 22).padding(.top, 18)
                }
                .background(TaliseColor.bg.ignoresSafeArea())
                .overlay(alignment: .bottom) { createBar }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .tint(TaliseColor.fg)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "New contract")
                Text("Set up recurring pay")
                    .font(TaliseFont.heading(24, weight: .medium)).kerning(-0.8).foregroundStyle(TaliseColor.fg)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(TaliseColor.fg)
                    .frame(width: 32, height: 32).background(Circle().fill(TaliseColor.surface2)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
    }

    private var recipientField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("PAYEE").font(TaliseFont.mono(9)).tracking(1.5).foregroundStyle(TaliseColor.fgDim)
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
            if let r = resolved {
                Text("Resolved: \(r.displayString)").font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.accent)
            } else if resolveFailed {
                Text("Couldn't find that payee. Check the @handle or address.")
                    .font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.danger)
            }
        }
        .onChange(of: recipientQuery) { _, _ in
            resolved = nil; resolveFailed = false; scheduleResolve(debounce: true)
        }
    }

    private var fieldsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeled("ROLE / TITLE") {
                TextField("e.g. Designer — Q3 retainer", text: $title)
                    .font(TaliseFont.body(15)).foregroundStyle(TaliseColor.fg)
            }
            labeled("RATE (USDsui per period)") {
                HStack {
                    Text("$").font(TaliseFont.heading(18)).foregroundStyle(TaliseColor.fgMuted)
                    TextField("0.00", text: $rateText).keyboardType(.decimalPad)
                        .font(TaliseFont.display(22, weight: .medium)).foregroundStyle(TaliseColor.fg)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("PER").font(TaliseFont.mono(9)).tracking(1.5).foregroundStyle(TaliseColor.fgDim)
                HStack(spacing: 8) {
                    ForEach(cadences, id: \.1) { opt in
                        let on = cadence == opt.1
                        Button { cadence = opt.1 } label: {
                            Text(opt.0).font(TaliseFont.body(13, weight: on ? .medium : .light))
                                .foregroundStyle(on ? Color(hex: 0x0A130D) : TaliseColor.fg)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(on ? TaliseColor.greenMint : TaliseColor.surface2))
                                .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            labeled("NUMBER OF PERIODS") {
                TextField("4", text: $periodsText).keyboardType(.numberPad)
                    .font(TaliseFont.body(15)).foregroundStyle(TaliseColor.fg)
                    .onChange(of: periodsText) { _, new in periodsText = String(new.filter { $0.isNumber }.prefix(4)) }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TaliseColor.surface))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(TaliseColor.accent)
                Text("\(periods) payments of \(TaliseFormat.usd2(rateUsd))")
                    .font(TaliseFont.heading(15, weight: .medium)).foregroundStyle(TaliseColor.fg)
            }
            Text("\(TaliseFormat.usd2(totalUsd)) total, funded upfront and released one period at a time. No network fee — Talise sponsors the gas.")
                .font(TaliseFont.body(12, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(TaliseColor.accent.opacity(0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(TaliseColor.accent.opacity(0.22), lineWidth: 1))
    }

    private func labeled<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(TaliseFont.mono(9)).tracking(1.5).foregroundStyle(TaliseColor.fgDim)
            content()
            Rectangle().fill(TaliseColor.line).frame(height: 1)
        }
    }

    private var createBar: some View {
        SlideToConfirm(title: creating ? "Funding…" : "Slide to fund & sign") { await create() }
            .disabled(creating || !canCreate).opacity(creating || !canCreate ? 0.5 : 1)
            .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
            .background(LinearGradient(colors: [TaliseColor.bg.opacity(0), TaliseColor.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56)).foregroundStyle(TaliseColor.greenMint)
                .frame(width: 96, height: 96).background(Circle().fill(TaliseColor.greenMint.opacity(0.16)))
            Text("Contract started").font(TaliseFont.heading(22, weight: .medium)).foregroundStyle(TaliseColor.fg)
            Text("\(TaliseFormat.usd2(totalUsd)) to \(resolved?.displayString ?? "payee") · \(periods) periods")
                .font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted).multilineTextAlignment(.center).padding(.horizontal, 30)
            Spacer()
            LiquidGlassButton(title: "Done", tint: TaliseColor.greenMint, action: onClose).padding(.horizontal, 22).padding(.bottom, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(TaliseColor.bg.ignoresSafeArea())
    }

    // MARK: Resolve recipient

    private func scheduleResolve(debounce: Bool) {
        resolveTask?.cancel()
        let q = recipientQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { resolving = false; return }
        resolveTask = Task {
            if debounce { try? await Task.sleep(nanoseconds: 400_000_000); if Task.isCancelled { return } }
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
            guard q == recipientQuery.trimmingCharacters(in: .whitespaces) else { return }
            resolved = r; resolveFailed = false
        } catch {
            if Task.isCancelled || APIError.isCancellation(error) { return }
            guard q == recipientQuery.trimmingCharacters(in: .whitespaces) else { return }
            resolved = nil; resolveFailed = true
        }
    }

    // MARK: Fund stream + create contract

    /// 1. Fund the underlying stream (create-prepare → sign → record).
    /// 2. POST /api/contracts with the resulting streamId + funding digest.
    private func create() async {
        guard let to = resolved?.address, canCreate else { return }
        creating = true; error = nil
        defer { creating = false }
        let intervalMs = (cadenceMinutes[cadence] ?? 10080) * 60_000

        do {
            // ── Fund the stream. ──────────────────────────────────────────
            struct PrepareBody: Encodable { let to: String; let totalUsd: Double; let intervalMs: Int; let numTranches: Int }
            let prep: CtrStreamPrepareResp = try await APIClient.shared.post(
                "/api/streams/create-prepare",
                body: PrepareBody(to: to, totalUsd: totalUsd, intervalMs: intervalMs, numTranches: periods)
            )
            if let e = prep.error, !e.isEmpty { self.error = e; return }

            let sent: ZkLoginCoordinator.SignedSubmission
            if prep.mode == "onchain", let bytes = prep.bytes {
                sent = try await ZkLoginCoordinator.shared.executeSponsorReady(bytesB64: bytes, intent: "Fund contract")
            } else {
                let escrowAddr: String
                if let addr = prep.escrowAddress { escrowAddr = addr }
                else {
                    let escrow: CtrStreamEscrowResp = try await APIClient.shared.get("/api/streams/escrow")
                    escrowAddr = escrow.escrowAddress
                }
                sent = try await ZkLoginCoordinator.shared.signAndSubmitSend(to: escrowAddr, amountUsd: totalUsd, intent: "Fund contract")
            }

            let totalMicros = Int((totalUsd * 1_000_000).rounded())
            let trancheMicros = totalMicros / max(1, periods)
            let now = Int(Date().timeIntervalSince1970 * 1000)
            struct RecordBody: Encodable {
                let fundingDigest: String; let recipientAddress: String; let recipientHandle: String?
                let totalMicros: String; let trancheMicros: String; let numTranches: Int; let startMs: Int; let intervalMs: Int
            }
            let rec: CtrStreamRecordResp = try await APIClient.shared.post(
                "/api/streams/record",
                body: RecordBody(fundingDigest: sent.digest, recipientAddress: to, recipientHandle: resolved?.displayName,
                                 totalMicros: String(totalMicros), trancheMicros: String(trancheMicros),
                                 numTranches: periods, startMs: now, intervalMs: intervalMs)
            )
            guard let streamId = rec.id, !streamId.isEmpty else {
                self.error = "Funded the stream but couldn't link the contract. Check your contracts list."
                return
            }

            // ── Persist the contract metadata wrapping the stream. ─────────
            struct ContractBody: Encodable {
                let streamId: String; let payeeAddress: String; let payeeHandle: String?
                let title: String; let rateUsd: Double; let cadence: String; let periods: Int; let fundingDigest: String
            }
            let _: ContractCreateResp = try await APIClient.shared.post(
                "/api/contracts",
                body: ContractBody(streamId: streamId, payeeAddress: to, payeeHandle: resolved?.displayName,
                                   title: title, rateUsd: rateUsd, cadence: cadence, periods: periods, fundingDigest: sent.digest)
            )
            NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                digest: sent.digest, direction: "sent", amountUsdsui: totalUsd,
                counterparty: to, counterpartyName: "Contract", venue: nil))
            withAnimation { created = true }
        } catch APIError.status(let code, let msg) {
            error = friendlyWorkError(code: code, message: msg, noun: "contract")
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            error = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't create the contract right now."
        }
    }
}
