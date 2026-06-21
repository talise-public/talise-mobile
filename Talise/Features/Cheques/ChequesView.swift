import SwiftUI

// MARK: - Cover dismiss (shared)

extension View {
    /// A simple top-trailing "X" that dismisses a full-screen cover page (used
    /// across the cheque + stream + work covers so every page has a clear way
    /// back). Top-trailing so it never overlaps the left-aligned page headers.
    func coverDismiss(_ onClose: @escaping () -> Void) -> some View {
        overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TaliseColor.fg)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(TaliseColor.surface2))
            }
            .padding(.trailing, 16)
            .padding(.top, 12)
        }
    }
}

// MARK: - DTOs

private struct ChequeCreateResp: Decodable {
    let chequeId: String
    let amountUsd: Double
    let claimUrl: String
    let secret: String
    /// Funding rail picked by the backend. "onchain" → sign `fundingBytes`
    /// via executeSponsorReady; "escrow" (or absent for older backends) →
    /// fund `escrowAddress` over the normal send rail. Optional so both
    /// response shapes parse.
    let mode: String?
    /// Sponsor-ready `cheque::create` bytes — present only on the on-chain rail.
    let fundingBytes: String?
    /// Talise escrow address — present only on the escrow rail.
    let escrowAddress: String?
}
private struct ChequeConfirmResp: Decodable { let ok: Bool }
/// Reclaim ("Claim back") response. On the on-chain rail the BUILD step
/// returns `mode:"onchain"` + sponsor-ready `reclaimBytes` for the creator
/// to sign; the escrow rail does the refund server-side and returns the
/// final `status` ("voided") with the refund `digest`. All fields optional
/// so both shapes parse from one type.
private struct ChequeReclaimResp: Decodable {
    let ok: Bool?
    let mode: String?
    let reclaimBytes: String?
    let status: String?
    let digest: String?
    let amountUsd: Double?
}
private struct ChequePreviewResp: Decodable {
    let id: String
    let amountUsd: Double
    let status: String
    let payeeLabel: String?
    let memo: String?
    let signatureName: String?
    let creatorDisplay: String
    let allowedCountries: [String]
    let expiresAt: Double
    let claimable: Bool
}
private struct ChequeClaimResp: Decodable { let ok: Bool; let digest: String?; let amountUsd: Double? }
/// One row of GET /api/cheques/mine. `createdAt`/`expiresAt` are epoch ms;
/// `reclaimable` is the server's "funded + unclaimed + not expired" flag.
private struct MyChequeRow: Decodable, Identifiable {
    let id: String
    let amountUsd: Double
    let status: String
    let memo: String?
    let payeeLabel: String?
    let createdAt: Double
    let expiresAt: Double
    let reclaimable: Bool
}
private struct MyChequesResp: Decodable { let cheques: [MyChequeRow] }

// MARK: - Skeuomorphic cheque card

/// A paper-cheque visual: cream stock on the dark app surface, engraved
/// header, pay-to-the-order-of line, a boxed figure amount, the amount in
/// words, memo + signature lines, and a status stamp. Used read-only on the
/// issued/claim screens; the write screen overlays editable fields.
struct ChequeCard<Fields: View>: View {
    var amountUsd: Double
    var payee: String
    var memo: String
    var signature: String
    var chequeNo: String
    var stamp: String? = nil
    @ViewBuilder var fields: () -> Fields

    private let ink = Color(hex: 0x2A2A2A)
    private let inkSoft = Color(hex: 0x6B6357)
    private let paper = Color(hex: 0xF4EFE2)
    private let rule = Color(hex: 0x9C9486)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(hex: 0xF7F3E8), Color(hex: 0xEDE6D5)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            VStack(alignment: .leading, spacing: 0) {
                // Header band
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("TALISE")
                            .font(.system(size: 15, weight: .heavy, design: .serif))
                            .foregroundStyle(TaliseColor.greenDeep)
                            .tracking(2)
                        Text("PAY ANYONE, ANYWHERE")
                            .font(.system(size: 6, weight: .regular, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(inkSoft)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("No. \(chequeNo)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(inkSoft)
                        Text("USDsui")
                            .font(.system(size: 9, weight: .semibold, design: .serif))
                            .foregroundStyle(ink)
                    }
                }
                Rectangle().fill(rule.opacity(0.5)).frame(height: 1).padding(.top, 8)

                // Pay to the order of + figure box
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PAY TO THE ORDER OF")
                            .font(.system(size: 7, weight: .regular, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(inkSoft)
                        Text(payee.isEmpty ? "—" : payee)
                            .font(.system(size: 17, weight: .semibold, design: .serif))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                        Rectangle().fill(rule.opacity(0.6)).frame(height: 1)
                    }
                    VStack(spacing: 2) {
                        Text(TaliseFormat.usd2(amountUsd))
                            .font(.system(size: 18, weight: .bold, design: .serif))
                            .foregroundStyle(ink)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).stroke(ink.opacity(0.5), lineWidth: 1.2))
                    }
                }
                .padding(.top, 14)

                // Amount in words
                HStack(spacing: 6) {
                    Text(amountInWords(amountUsd))
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .italic()
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Rectangle().fill(rule.opacity(0.6)).frame(height: 1)
                    Text("USDsui").font(.system(size: 9, design: .serif)).foregroundStyle(inkSoft)
                }
                .padding(.top, 12)

                Spacer(minLength: 14)

                // Memo + signature
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(memo.isEmpty ? " " : memo)
                            .font(.system(size: 10, design: .serif)).foregroundStyle(ink).lineLimit(1)
                        Rectangle().fill(rule.opacity(0.5)).frame(width: 110, height: 1)
                        Text("MEMO").font(.system(size: 6, design: .monospaced)).foregroundStyle(inkSoft)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(signature.isEmpty ? " " : signature)
                            .font(.custom("SnellRoundhand-Bold", size: 18))
                            .foregroundStyle(TaliseColor.greenDeep).lineLimit(1)
                        Rectangle().fill(rule.opacity(0.5)).frame(width: 120, height: 1)
                        Text("AUTHORIZED SIGNATURE").font(.system(size: 6, design: .monospaced)).foregroundStyle(inkSoft)
                    }
                }
            }
            .padding(18)

            // Editable overlays (write screen) — laid over the paper.
            fields()

            if let stamp {
                Text(stamp)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(Color(hex: 0xA23B2E).opacity(0.85))
                    .rotationEffect(.degrees(-14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(hex: 0xA23B2E).opacity(0.85), lineWidth: 3)
                            .padding(-8)
                    )
                    .rotationEffect(.degrees(0))
                    .opacity(0.9)
            }
        }
        .frame(height: 210)
        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 8)
    }
}

extension ChequeCard where Fields == EmptyView {
    init(amountUsd: Double, payee: String, memo: String, signature: String, chequeNo: String, stamp: String? = nil) {
        self.init(amountUsd: amountUsd, payee: payee, memo: memo, signature: signature,
                  chequeNo: chequeNo, stamp: stamp, fields: { EmptyView() })
    }
}

// MARK: - Write a cheque

struct ChequeWriteView: View {
    var onDone: () -> Void
    @Environment(AppSession.self) private var session
    @State private var amountText = ""
    @State private var payee = ""
    @State private var memo = ""
    @State private var gateCountry = false
    @State private var country = "NG"
    @State private var issuing = false
    @State private var error: String?
    @State private var issued: ChequeCreateResp?

    private var amountUsd: Double { Double(amountText) ?? 0 }
    private var signatureName: String {
        if case .ready(let u) = session.phase { return u.name ?? "Talise" }
        return "Talise"
    }

    var body: some View {
        if let issued {
            ChequeIssuedView(resp: issued, payee: payee, memo: memo, signature: signatureName, onDone: onDone)
        } else {
            authoring
        }
    }

    private var authoring: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header
                ChequeCard(amountUsd: amountUsd, payee: payee, memo: memo,
                           signature: signatureName, chequeNo: "•••••") {
                    EmptyView()
                }
                fieldsCard
                if let error {
                    Text(error).font(TaliseFont.body(12)).foregroundStyle(TaliseColor.danger)
                }
                Color.clear.frame(height: 90)
            }
            .padding(.horizontal, 22).padding(.top, 18)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) { issueBar }
        .coverDismiss(onDone)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: "Write a cheque")
            Text("Money in a link")
                .font(TaliseFont.heading(24, weight: .medium)).kerning(-0.8)
                .foregroundStyle(TaliseColor.fg)
            Text("Send it in any DM. They claim it as real money.")
                .font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
        }
    }

    private var fieldsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeled("AMOUNT (USDsui)") {
                HStack {
                    Text("$").font(TaliseFont.heading(18)).foregroundStyle(TaliseColor.fgMuted)
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(TaliseFont.display(22, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                }
            }
            labeled("PAY TO (name on the cheque)") {
                TextField("e.g. Sele", text: $payee)
                    .font(TaliseFont.body(15)).foregroundStyle(TaliseColor.fg)
            }
            labeled("MEMO (optional)") {
                TextField("What's it for?", text: $memo)
                    .font(TaliseFont.body(15)).foregroundStyle(TaliseColor.fg)
            }
            Toggle(isOn: $gateCountry) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restrict by country").font(TaliseFont.body(14)).foregroundStyle(TaliseColor.fg)
                    Text("Only claimable from one country (IP-checked)")
                        .font(TaliseFont.mono(9)).foregroundStyle(TaliseColor.fgDim)
                }
            }
            .tint(TaliseColor.greenDeep)
            if gateCountry {
                labeled("COUNTRY (ISO code)") {
                    TextField("NG", text: $country)
                        .textInputAutocapitalization(.characters)
                        .font(TaliseFont.body(15)).foregroundStyle(TaliseColor.fg)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 11)).foregroundStyle(TaliseColor.accent)
                Text("Always protected: captcha + no-VPN on claim")
                    .font(TaliseFont.mono(9)).foregroundStyle(TaliseColor.fgDim)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func labeled<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(TaliseFont.mono(9)).tracking(1.5).foregroundStyle(TaliseColor.fgDim)
            content()
            Rectangle().fill(TaliseColor.line).frame(height: 1)
        }
    }

    private var issueBar: some View {
        VStack(spacing: 0) {
            SlideToConfirm(title: issuing ? "Issuing…" : "Slide to sign & fund") {
                await issue()
            }
            .disabled(issuing || amountUsd < 0.01 || payee.isEmpty)
            .opacity(issuing || amountUsd < 0.01 || payee.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
        .background(LinearGradient(colors: [TaliseColor.bg.opacity(0), TaliseColor.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func issue() async {
        guard amountUsd >= 0.01, !payee.isEmpty else { return }
        issuing = true; error = nil
        defer { issuing = false }
        struct CreateBody: Encodable { let amountUsd: Double; let payeeLabel: String; let memo: String?; let allowedCountries: [String] }
        do {
            let created: ChequeCreateResp = try await APIClient.shared.post(
                "/api/cheques/create",
                body: CreateBody(amountUsd: amountUsd, payeeLabel: payee,
                                 memo: memo.isEmpty ? nil : memo,
                                 allowedCountries: gateCountry ? [country.uppercased()] : [])
            )

            // Fund the cheque. Two rails, picked by the server's `mode`:
            //   • "onchain" → sign the sponsor-ready `cheque::create` bytes via
            //     executeSponsorReady (Onara pays gas); the resulting digest is
            //     the create tx the server parses for the on-chain Cheque object.
            //   • "escrow" / absent → fund the escrow address over the normal
            //     send rail (gasless / sponsored), exactly as before.
            // Either way, the digest goes to confirm-funded to flip draft→funded.
            let sent: ZkLoginCoordinator.SignedSubmission
            let counterparty: String
            if created.mode == "onchain", let fundingBytes = created.fundingBytes {
                sent = try await ZkLoginCoordinator.shared.executeSponsorReady(
                    bytesB64: fundingBytes, intent: "Fund cheque"
                )
                counterparty = "onchain"
            } else if let escrow = created.escrowAddress {
                sent = try await ZkLoginCoordinator.shared.signAndSubmitSend(
                    to: escrow, amountUsd: amountUsd, intent: "Fund cheque"
                )
                counterparty = escrow
            } else {
                self.error = "Couldn't issue the cheque right now."
                return
            }
            struct ConfirmBody: Encodable { let digest: String }
            let _: ChequeConfirmResp = try await APIClient.shared.post(
                "/api/cheques/\(created.chequeId)/confirm-funded", body: ConfirmBody(digest: sent.digest)
            )
            NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                digest: sent.digest, direction: "sent", amountUsdsui: amountUsd,
                counterparty: counterparty, counterpartyName: "Cheque", venue: nil
            ))
            withAnimation { issued = created }
        } catch APIError.status(let code, let msg) {
            self.error = chequeError(code: code, message: msg, verb: "issue")
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            // Unrecoverable session — retrying here would fail forever.
            // Route to the clean sign-out → re-auth path (mirrors Send).
            self.error = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't issue the cheque right now."
        }
    }
}

/// Map "backend isn't live yet" cheque responses (404 / 503 /
/// "disabled" / "not configured") to reassuring rollout copy, instead
/// of leaking "HTTP 404". Real, actionable server messages pass through.
func chequeError(code: Int, message: String?, verb: String) -> String {
    let lower = (message ?? "").lowercased()
    let rolloutPhrase = lower.contains("not configured") || lower.contains("disabled")
        || lower.contains("not found") || lower.contains("unavailable")
    if code == 404 || code == 503 || rolloutPhrase {
        return "Cheques are rolling out — check back soon."
    }
    if let msg = message, !msg.isEmpty { return msg }
    return "Couldn't \(verb) the cheque right now."
}

// MARK: - Issued (share)

private struct ChequeIssuedView: View {
    let resp: ChequeCreateResp
    let payee: String
    let memo: String
    let signature: String
    var onDone: () -> Void
    @Environment(AppSession.self) private var session
    @State private var sharing = false
    @State private var reclaiming = false
    @State private var reclaimed = false
    @State private var reclaimError: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 8)
            Text(reclaimed ? "Cheque reclaimed" : "Cheque issued")
                .font(TaliseFont.heading(22, weight: .medium)).foregroundStyle(TaliseColor.fg)
            ChequeCard(amountUsd: resp.amountUsd, payee: payee, memo: memo,
                       signature: signature, chequeNo: String(resp.chequeId.suffix(5)),
                       stamp: reclaimed ? "RECLAIMED" : "ISSUED")
                .padding(.horizontal, 22)
            Text(reclaimed
                 ? "The money is back in your Talise balance."
                 : "Send this link in any DM. They claim it as money.")
                .font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            if let reclaimError {
                Text(reclaimError).font(TaliseFont.body(12)).foregroundStyle(TaliseColor.danger)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
            }
            Spacer()
            VStack(spacing: 10) {
                if reclaimed {
                    LiquidGlassButton(title: "Done", tint: TaliseColor.greenMint, action: onDone)
                } else {
                    LiquidGlassButton(
                        title: "Share cheque link",
                        icon: "square.and.arrow.up",
                        tint: TaliseColor.greenMint
                    ) { sharing = true }
                    // Claim back: pull an unclaimed cheque the user created
                    // back to their own balance before anyone cashes it.
                    LiquidGlassButton(
                        title: reclaiming ? "Claiming back…" : "Claim it back",
                        icon: reclaiming ? nil : "arrow.uturn.backward",
                        tint: nil,
                        loading: reclaiming
                    ) { Task { await reclaim() } }
                        .disabled(reclaiming)
                    Button(action: onDone) {
                        Text("Done").font(TaliseFont.body(15)).foregroundStyle(TaliseColor.fgMuted)
                            .frame(maxWidth: .infinity).frame(height: 44)
                    }.buttonStyle(.plain).disabled(reclaiming)
                }
            }.padding(.horizontal, 22).padding(.bottom, 24)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        // Share the link as a STRING (public.plain-text), not a URL object.
        // Sharing a URL makes messaging apps (WhatsApp) grab the bplist-encoded
        // `public.url` representation, which pasted as "bplist00…%00%00~" garbage.
        // A string is auto-linked cleanly by every app.
        .sheet(isPresented: $sharing) { ShareSheet(items: [resp.claimUrl]) }
    }

    /// Reclaim ("Claim back") the unclaimed cheque the creator just issued.
    ///   • On-chain rail: the BUILD POST returns sponsor-ready `reclaimBytes`;
    ///     we sign+execute via executeSponsorReady, then a CONFIRM POST with
    ///     the reclaim `{digest}` flips funded→reclaimed server-side.
    ///   • Escrow rail: the single POST refunds server-side and returns the
    ///     final status — no client signature needed.
    private func reclaim() async {
        reclaiming = true; reclaimError = nil
        defer { reclaiming = false }
        struct ReclaimBuild: Encodable {}
        struct ReclaimConfirm: Encodable { let digest: String }
        do {
            let built: ChequeReclaimResp = try await APIClient.shared.post(
                "/api/cheques/\(resp.chequeId)/reclaim", body: ReclaimBuild()
            )
            var refundDigest = built.digest
            if built.mode == "onchain", let reclaimBytes = built.reclaimBytes {
                // Creator signs the sponsored cheque::reclaim PTB.
                let sent = try await ZkLoginCoordinator.shared.executeSponsorReady(
                    bytesB64: reclaimBytes, intent: "Reclaim cheque"
                )
                refundDigest = sent.digest
                // Confirm: record the reclaim digest CREATOR-only (funded→reclaimed).
                let _: ChequeReclaimResp = try await APIClient.shared.post(
                    "/api/cheques/\(resp.chequeId)/reclaim", body: ReclaimConfirm(digest: sent.digest)
                )
            }
            if let d = refundDigest {
                NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                    digest: d, direction: "received", amountUsdsui: resp.amountUsd,
                    counterparty: nil, counterpartyName: "Cheque", venue: nil))
            }
            withAnimation { reclaimed = true }
        } catch APIError.status(let code, let msg) {
            reclaimError = chequeError(code: code, message: msg, verb: "reclaim")
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            reclaimError = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            reclaimError = "Couldn't claim this cheque back right now."
        }
    }
}

// MARK: - My cheques

/// The signed-in user's written cheques (GET /api/cheques/mine), newest
/// first. Each row shows the amount, a color-coded status pill, the
/// memo/payee, and the date. Rows the server marks `reclaimable` (funded
/// + unclaimed + not expired) get a "Claim it back" button that runs the
/// same reclaim flow as `ChequeIssuedView`: escrow rail refunds
/// server-side; on-chain rail returns `reclaimBytes` to sign via
/// executeSponsorReady, then a confirm POST with the digest.
struct MyChequesView: View {
    var onDone: () -> Void
    @Environment(AppSession.self) private var session
    @State private var rows: [MyChequeRow] = []
    @State private var loading = true
    @State private var error: String?
    /// Cheque ids with an in-flight reclaim, so we can spin only that row.
    @State private var reclaiming: Set<String> = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                if loading {
                    loadingState
                } else if let error {
                    errorState(error)
                } else if rows.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 12) {
                        ForEach(rows) { row in
                            chequeRow(row)
                        }
                    }
                }
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 22).padding(.top, 18)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "My cheques")
                Text("Cheques you've written")
                    .font(TaliseFont.heading(24, weight: .medium)).kerning(-0.8)
                    .foregroundStyle(TaliseColor.fg)
                Text("Claim back anything that hasn't been cashed yet.")
                    .font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
            }
            Spacer()
            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(TaliseColor.surface2))
                    .clipShape(Circle())
            }.buttonStyle(.plain)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(TaliseColor.surface)
                    .frame(height: 84)
                    .redacted(reason: .placeholder)
            }
        }
        .overlay(ProgressView().tint(TaliseColor.fgMuted))
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Text(msg)
                .font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted)
                .multilineTextAlignment(.center)
            LiquidGlassButton(title: "Try again", tint: nil, size: .md, fullWidth: false) {
                Task { await load() }
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 40, weight: .light)).foregroundStyle(TaliseColor.fgDim)
            Text("No cheques yet")
                .font(TaliseFont.heading(18, weight: .medium)).foregroundStyle(TaliseColor.fg)
            Text("Cheques you write will show up here so you can track and reclaim them.")
                .font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func chequeRow(_ row: MyChequeRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TaliseFormat.local2(row.amountUsd))
                        .font(TaliseFont.display(20, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                    Text(TaliseFormat.usd2(row.amountUsd))
                        .font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgDim)
                }
                Spacer()
                statusPill(row.status)
            }
            let label = subtitle(row)
            if !label.isEmpty {
                Text(label)
                    .font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                    .lineLimit(2)
            }
            HStack {
                Text(dateText(row.createdAt))
                    .font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgDim)
                Spacer()
            }
            if row.reclaimable {
                LiquidGlassButton(
                    title: reclaiming.contains(row.id) ? "Claiming back…" : "Claim it back",
                    icon: reclaiming.contains(row.id) ? nil : "arrow.uturn.backward",
                    tint: nil,
                    size: .md,
                    loading: reclaiming.contains(row.id)
                ) { Task { await reclaim(row) } }
                    .disabled(reclaiming.contains(row.id))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TaliseColor.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Color-code: funded = mint (live/reclaimable), claimed = muted,
    /// reclaimed/voided/expired/draft = dim.
    private func statusPill(_ status: String) -> some View {
        let tint: Color
        switch status {
        case "funded": tint = TaliseColor.greenMint
        case "claimed": tint = TaliseColor.fgMuted
        default: tint = TaliseColor.fgDim   // reclaimed / voided / expired / draft
        }
        return Text(status.capitalized)
            .font(TaliseFont.mono(9, weight: .light)).kerning(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    private func subtitle(_ row: MyChequeRow) -> String {
        if let memo = row.memo, !memo.isEmpty { return memo }
        if let payee = row.payeeLabel, !payee.isEmpty { return "To \(payee)" }
        return ""
    }

    private func dateText(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy"
        return fmt.string(from: date)
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let resp: MyChequesResp = try await APIClient.shared.get("/api/cheques/mine")
            rows = resp.cheques
        } catch APIError.status(let code, let msg) {
            error = chequeError(code: code, message: msg, verb: "load")
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't load your cheques right now."
        }
    }

    /// Reclaim ("Claim it back") one row. Mirrors `ChequeIssuedView.reclaim()`:
    ///   • On-chain rail: the BUILD POST returns sponsor-ready `reclaimBytes`;
    ///     sign+execute via executeSponsorReady, then a CONFIRM POST with the
    ///     reclaim `{digest}` flips funded→reclaimed server-side.
    ///   • Escrow rail: the single POST refunds server-side and returns the
    ///     final status — no client signature needed.
    /// On success, mark the row reclaimed/voided locally and reload the list.
    private func reclaim(_ row: MyChequeRow) async {
        guard !reclaiming.contains(row.id) else { return }
        reclaiming.insert(row.id)
        defer { reclaiming.remove(row.id) }
        struct ReclaimBuild: Encodable {}
        struct ReclaimConfirm: Encodable { let digest: String }
        do {
            let built: ChequeReclaimResp = try await APIClient.shared.post(
                "/api/cheques/\(row.id)/reclaim", body: ReclaimBuild()
            )
            var refundDigest = built.digest
            var finalStatus = built.status
            if built.mode == "onchain", let reclaimBytes = built.reclaimBytes {
                let sent = try await ZkLoginCoordinator.shared.executeSponsorReady(
                    bytesB64: reclaimBytes, intent: "Reclaim cheque"
                )
                refundDigest = sent.digest
                let confirmed: ChequeReclaimResp = try await APIClient.shared.post(
                    "/api/cheques/\(row.id)/reclaim", body: ReclaimConfirm(digest: sent.digest)
                )
                finalStatus = confirmed.status ?? finalStatus
            }
            if let d = refundDigest {
                NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                    digest: d, direction: "received", amountUsdsui: row.amountUsd,
                    counterparty: nil, counterpartyName: "Cheque", venue: nil))
            }
            // Reflect the reclaim immediately, then reconcile from the server.
            if let idx = rows.firstIndex(where: { $0.id == row.id }) {
                let r = rows[idx]
                withAnimation {
                    rows[idx] = MyChequeRow(
                        id: r.id, amountUsd: r.amountUsd,
                        status: finalStatus ?? "reclaimed",
                        memo: r.memo, payeeLabel: r.payeeLabel,
                        createdAt: r.createdAt, expiresAt: r.expiresAt,
                        reclaimable: false
                    )
                }
            }
            await load()
        } catch APIError.status(let code, let msg) {
            error = chequeError(code: code, message: msg, verb: "reclaim")
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            error = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't claim this cheque back right now."
        }
    }
}

// MARK: - Claim a cheque

struct ChequeClaimView: View {
    var onDone: () -> Void
    /// Pre-filled cheque link when the view is opened from a deep link
    /// (talise://c/… or a universal link). When set, we auto-open the
    /// cheque on appear so the recipient lands straight on the claim card.
    var initialLink: String? = nil
    @State private var linkText = ""
    @State private var preview: ChequePreviewResp?
    @State private var parsed: (id: String, secret: String)?
    @State private var loading = false
    @State private var claiming = false
    @State private var error: String?
    @State private var claimedAmount: Double?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Eyebrow(text: "Cash a cheque")
                if let claimedAmount {
                    cashed(claimedAmount)
                } else if let p = preview {
                    cheque(p)
                } else {
                    paste
                }
                if let error { Text(error).font(TaliseFont.body(12)).foregroundStyle(TaliseColor.danger) }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 40)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .coverDismiss(onDone)
        .presentationDragIndicator(.visible)
        .task {
            // Deep-link entry: auto-open the cheque from the pre-filled link.
            if let link = initialLink, !link.isEmpty, preview == nil, !loading {
                linkText = link
                await load()
            }
        }
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste a cheque link").font(TaliseFont.heading(20, weight: .medium)).foregroundStyle(TaliseColor.fg)
            TextField("https://talise.io/c/…", text: $linkText, axis: .vertical)
                .font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fg)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(TaliseColor.surface)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            LiquidGlassButton(
                title: loading ? "Loading…" : "Open cheque",
                tint: TaliseColor.greenMint,
                loading: loading
            ) { Task { await load() } }
                .disabled(loading || linkText.isEmpty)
                .opacity(loading || linkText.isEmpty ? 0.55 : 1)
        }
    }

    private func cheque(_ p: ChequePreviewResp) -> some View {
        VStack(spacing: 18) {
            Text("From \(p.creatorDisplay)").font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted)
            ChequeCard(amountUsd: p.amountUsd, payee: p.payeeLabel ?? "You",
                       memo: p.memo ?? "", signature: p.signatureName ?? "",
                       chequeNo: String(p.id.suffix(5)),
                       stamp: p.claimable ? nil : p.status.uppercased())
            if !p.allowedCountries.isEmpty {
                Label("Claimable only from \(p.allowedCountries.joined(separator: ", "))",
                      systemImage: "globe").font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgDim)
            }
            if p.claimable {
                SlideToConfirm(title: claiming ? "Cashing…" : "Slide to cash this cheque") {
                    await claim()
                }
                .disabled(claiming)
                .opacity(claiming ? 0.5 : 1)
            } else {
                Text("This cheque is \(p.status).").font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted)
            }
        }
    }

    private func cashed(_ amt: Double) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 30)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56)).foregroundStyle(TaliseColor.accent)
                .frame(width: 96, height: 96)
                .background(Circle().fill(TaliseColor.accent.opacity(0.16)))
            Text("\(TaliseFormat.local2(amt)) cashed").font(TaliseFont.heading(22, weight: .medium)).foregroundStyle(TaliseColor.fg)
            Text("It's in your Talise balance.").font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted)
            LiquidGlassButton(title: "Done", tint: TaliseColor.greenMint, action: onDone)
                .padding(.top, 10)
        }
    }

    /// Parse `…/c/<id>#<secret>` (or `talise://c/<id>#<secret>`).
    private func parse(_ s: String) -> (String, String)? {
        guard let hash = s.firstIndex(of: "#") else { return nil }
        let secret = String(s[s.index(after: hash)...])
        let beforeHash = String(s[..<hash])
        guard let slash = beforeHash.range(of: "/c/", options: .backwards) else { return nil }
        let id = String(beforeHash[slash.upperBound...])
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return (id, secret)
    }

    private func load() async {
        guard let (id, secret) = parse(linkText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "That doesn't look like a cheque link."; return
        }
        loading = true; error = nil; defer { loading = false }
        do {
            let p: ChequePreviewResp = try await APIClient.shared.get(
                "/api/cheques/\(id)/preview?s=\(secret)"
            )
            parsed = (id, secret); preview = p
        } catch APIError.status(let code, let msg) where isRollout(code, msg) {
            // Service genuinely not live yet (503 / "disabled"). A bare
            // 404 here is ambiguous — it usually means an invalid or
            // already-claimed cheque — so that keeps its own copy below.
            self.error = "Cheques are rolling out — check back soon."
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't open this cheque — it may be invalid or already claimed."
        }
    }

    private func isRollout(_ code: Int, _ msg: String?) -> Bool {
        let lower = (msg ?? "").lowercased()
        return code == 503 || lower.contains("disabled") || lower.contains("not configured")
    }

    private func claim() async {
        guard let (id, secret) = parsed else { return }
        claiming = true; error = nil; defer { claiming = false }
        struct ClaimBody: Encodable { let secret: String; let turnstileToken: String? }
        do {
            let r: ChequeClaimResp = try await APIClient.shared.post(
                "/api/cheques/\(id)/claim/release", body: ClaimBody(secret: secret, turnstileToken: nil)
            )
            if r.ok {
                if let d = r.digest, let amt = r.amountUsd {
                    NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                        digest: d, direction: "received", amountUsdsui: amt,
                        counterparty: nil, counterpartyName: "Cheque", venue: nil))
                }
                withAnimation { claimedAmount = r.amountUsd ?? preview?.amountUsd }
            }
        } catch APIError.status(let code, let msg) {
            self.error = chequeError(code: code, message: msg, verb: "cash")
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't cash this cheque right now."
        }
    }
}

// MARK: - Share sheet shim

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Amount in words (cheque convention)

func amountInWords(_ usd: Double) -> String {
    let whole = Int(usd)
    let cents = Int((usd - Double(whole)) * 100 + 0.5)
    let dollars = whole == 0 ? "Zero" : numberToWords(whole)
    let centStr = String(format: "%02d", cents)
    return "\(dollars) and \(centStr)/100".capitalizedFirst
}

private func numberToWords(_ n: Int) -> String {
    if n == 0 { return "zero" }
    let ones = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                "seventeen", "eighteen", "nineteen"]
    let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    func under1000(_ x: Int) -> String {
        var parts: [String] = []
        let h = x / 100, r = x % 100
        if h > 0 { parts.append("\(ones[h]) hundred") }
        if r >= 20 {
            let t = tens[r / 10]; let o = r % 10
            parts.append(o > 0 ? "\(t)-\(ones[o])" : t)
        } else if r > 0 { parts.append(ones[r]) }
        return parts.joined(separator: " ")
    }
    var out: [String] = []
    let millions = n / 1_000_000
    let thousands = (n / 1000) % 1000
    let rest = n % 1000
    if millions > 0 { out.append("\(under1000(millions)) million") }
    if thousands > 0 { out.append("\(under1000(thousands)) thousand") }
    if rest > 0 { out.append(under1000(rest)) }
    return out.joined(separator: " ")
}

private extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}
