import SwiftUI

// MARK: - DTOs (match /api/invoices, /api/invoices/[id], /settle)

/// A rich Work invoice (`work_invoices`). Mirrors the `WorkInvoice` shape
/// returned by GET /api/invoices and POST /api/invoices.
struct WorkInvoiceDTO: Decodable, Identifiable {
    let id: String
    let amountUsd: Double
    let currency: String
    let customerName: String?
    let customerEmail: String?
    let lineItems: [InvoiceLineItem]?
    let memo: String?
    /// "open" | "paid" | "void"
    let status: String
    let dueMs: Double?
    let createdAt: Double
    let payDigest: String?
}

struct InvoiceLineItem: Decodable, Hashable {
    let description: String
    let qty: Double
    let unitUsd: Double
}

private struct InvoicesListResp: Decodable { let invoices: [WorkInvoiceDTO] }
private struct InvoiceCreateResp: Decodable {
    let ok: Bool
    let invoice: WorkInvoiceDTO
    let payUrl: String?
}
/// GET /api/invoices/[id] — the owner view returns `{ invoice, owner }`.
/// We only need the public-safe fields to render the pay screen.
private struct InvoiceDetailResp: Decodable {
    let invoice: PublicInvoiceDTO
    let owner: Bool
}
struct PublicInvoiceDTO: Decodable {
    let id: String
    let amountUsd: Double
    let currency: String
    let customerName: String?
    let lineItems: [InvoiceLineItem]?
    let memo: String?
    let status: String
    let dueMs: Double?
    let createdAt: Double
    let issuer: InvoiceIssuer?
}
struct InvoiceIssuer: Decodable {
    let handle: String
    let address: String
    let name: String?
}
private struct InvoiceSettleResp: Decodable {
    let ok: Bool
    let status: String
    let digest: String?
}

// MARK: - Invoices hub (list + create + share)

/// The signed-in user's invoices. Mirrors the web `InvoicesTab`: a list of
/// issued invoices with status pills, a "New invoice" button that opens the
/// create form, and a share action per row.
struct InvoicesView: View {
    var onDone: () -> Void
    @State private var rows: [WorkInvoiceDTO] = []
    @State private var loading = true
    @State private var error: String?
    @State private var creating = false
    @State private var shareItem: ShareItem?

    private struct ShareItem: Identifiable { let id = UUID(); let url: String }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                LiquidGlassButton(
                    title: "New invoice",
                    icon: "plus",
                    tint: TaliseColor.greenMint,
                    size: .md
                ) { creating = true }

                if loading {
                    loadingState
                } else if let error {
                    errorState(error)
                } else if rows.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 12) { ForEach(rows) { invoiceRow($0) } }
                }
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 22).padding(.top, 18)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task { await load() }
        .fullScreenCover(isPresented: $creating) {
            CreateInvoiceView { url in
                creating = false
                Task { await load() }
                if let url { shareItem = ShareItem(url: url) }
            }
        }
        .sheet(item: $shareItem) { item in
            // Share as a STRING, not a URL object — a URL serializes as a
            // bplist `public.url` that pastes as garbage in messaging apps.
            ShareSheet(items: [item.url])
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Invoices")
                Text("Get paid")
                    .font(TaliseFont.heading(24, weight: .medium)).kerning(-0.8)
                    .foregroundStyle(TaliseColor.fg)
                Text("Bill anyone in USDsui. Share a link, they pay, you're settled.")
                    .font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
            }
            Spacer()
            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(TaliseColor.fg)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(TaliseColor.surface2)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(TaliseColor.surface).frame(height: 84).redacted(reason: .placeholder)
            }
        }.overlay(ProgressView().tint(TaliseColor.fgMuted))
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Text(msg).font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted)
                .multilineTextAlignment(.center)
            LiquidGlassButton(title: "Try again", tint: nil, size: .md, fullWidth: false) {
                Task { await load() }
            }
        }.frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 40, weight: .light)).foregroundStyle(TaliseColor.fgDim)
            Text("No invoices yet").font(TaliseFont.heading(18, weight: .medium)).foregroundStyle(TaliseColor.fg)
            Text("Create one to bill a client and get paid in USDsui.")
                .font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }.frame(maxWidth: .infinity).padding(.top, 50)
    }

    private func invoiceRow(_ inv: WorkInvoiceDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TaliseFormat.usd2(inv.amountUsd))
                        .font(TaliseFont.display(20, weight: .medium)).foregroundStyle(TaliseColor.fg)
                    if let name = inv.customerName, !name.isEmpty {
                        Text("To \(name)").font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                    }
                }
                Spacer()
                statusPill(inv.status)
            }
            if let memo = inv.memo, !memo.isEmpty {
                Text(memo).font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted).lineLimit(2)
            }
            HStack {
                Text(dateText(inv.createdAt)).font(TaliseFont.mono(10)).foregroundStyle(TaliseColor.fgDim)
                Spacer()
            }
            if inv.status == "open" {
                LiquidGlassButton(title: "Share pay link", icon: "square.and.arrow.up", tint: nil, size: .md) {
                    shareItem = ShareItem(url: payURL(inv.id))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TaliseColor.surface))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func statusPill(_ status: String) -> some View {
        let tint: Color
        switch status {
        case "paid": tint = TaliseColor.greenMint
        case "open": tint = TaliseColor.accent
        default: tint = TaliseColor.fgDim
        }
        return Text(status.capitalized)
            .font(TaliseFont.mono(9, weight: .light)).kerning(0.6).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    private func payURL(_ id: String) -> String { "https://www.talise.io/i/\(id)" }

    private func dateText(_ ms: Double) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d, yyyy"
        return fmt.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let resp: InvoicesListResp = try await APIClient.shared.get("/api/invoices")
            rows = resp.invoices.sorted { $0.createdAt > $1.createdAt }
        } catch APIError.status(let code, let msg) {
            error = friendlyWorkError(code: code, message: msg, noun: "invoices")
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't load your invoices right now."
        }
    }
}

// MARK: - Create invoice

private struct CreateInvoiceView: View {
    /// Returns the share/pay URL on success (nil if the user cancelled).
    var onClose: (String?) -> Void
    @State private var amountText = ""
    @State private var customerName = ""
    @State private var memo = ""
    @State private var creating = false
    @State private var error: String?

    private var amountUsd: Double { Double(amountText) ?? 0 }
    private var canCreate: Bool { amountUsd >= 0.01 }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    fieldsCard
                    if let error {
                        Text(error).font(TaliseFont.body(12)).foregroundStyle(TaliseColor.danger)
                    }
                    Color.clear.frame(height: 80)
                }
                .padding(.horizontal, 22).padding(.top, 18)
            }
            .background(TaliseColor.bg.ignoresSafeArea())
            .overlay(alignment: .bottom) { createBar }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(TaliseColor.fg)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "New invoice")
                Text("Bill a client")
                    .font(TaliseFont.heading(24, weight: .medium)).kerning(-0.8).foregroundStyle(TaliseColor.fg)
            }
            Spacer()
            Button(action: { onClose(nil) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(TaliseColor.fg)
                    .frame(width: 32, height: 32).background(Circle().fill(TaliseColor.surface2)).clipShape(Circle())
            }.buttonStyle(.plain)
        }
    }

    private var fieldsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeled("AMOUNT (USDsui)") {
                HStack {
                    Text("$").font(TaliseFont.heading(18)).foregroundStyle(TaliseColor.fgMuted)
                    TextField("0.00", text: $amountText).keyboardType(.decimalPad)
                        .font(TaliseFont.display(22, weight: .medium)).foregroundStyle(TaliseColor.fg)
                }
            }
            labeled("BILL TO (optional)") {
                TextField("Client name", text: $customerName)
                    .font(TaliseFont.body(15)).foregroundStyle(TaliseColor.fg)
            }
            labeled("MEMO (optional)") {
                TextField("What's it for?", text: $memo)
                    .font(TaliseFont.body(15)).foregroundStyle(TaliseColor.fg)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TaliseColor.surface))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func labeled<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(TaliseFont.mono(9)).tracking(1.5).foregroundStyle(TaliseColor.fgDim)
            content()
            Rectangle().fill(TaliseColor.line).frame(height: 1)
        }
    }

    private var createBar: some View {
        LiquidGlassButton(
            title: creating ? "Creating…" : "Create invoice",
            tint: TaliseColor.greenMint,
            loading: creating
        ) { Task { await create() } }
            .disabled(creating || !canCreate)
            .opacity(creating || !canCreate ? 0.5 : 1)
            .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
            .background(LinearGradient(colors: [TaliseColor.bg.opacity(0), TaliseColor.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func create() async {
        guard canCreate else { return }
        creating = true; error = nil
        defer { creating = false }
        // Rich-invoice body — the route routes to work_invoices for any
        // signed-in user when a rich field is present. We send amountUsd
        // (no line items) + optional name/memo.
        struct Body: Encodable {
            let amountUsd: Double
            let customerName: String?
            let memo: String?
        }
        do {
            let resp: InvoiceCreateResp = try await APIClient.shared.post(
                "/api/invoices",
                body: Body(amountUsd: amountUsd,
                           customerName: customerName.isEmpty ? nil : customerName,
                           memo: memo.isEmpty ? nil : memo)
            )
            onClose(resp.payUrl ?? "https://www.talise.io/i/\(resp.invoice.id)")
        } catch APIError.status(let code, let msg) {
            error = friendlyWorkError(code: code, message: msg, noun: "invoice")
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't create the invoice right now."
        }
    }
}

// MARK: - Pay an invoice

/// Open + pay an invoice by id (the public /i/<id> flow). Loads the
/// invoice, sends the USDsui to the issuer's address over the normal send
/// rail, then settles it trustlessly with the resulting digest.
struct PayInvoiceView: View {
    let invoiceId: String
    var onDone: () -> Void
    /// Session-expiry path: an unrecoverable zkLogin session routes to a
    /// clean sign-out → re-auth (mirrors Send) instead of a dead-end error.
    @Environment(AppSession.self) private var session
    @State private var invoice: PublicInvoiceDTO?
    @State private var loading = true
    @State private var paying = false
    @State private var paid = false
    @State private var error: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                Eyebrow(text: "Pay invoice")
                if paid {
                    paidState
                } else if loading {
                    ProgressView().tint(TaliseColor.fg).frame(maxWidth: .infinity).padding(.top, 60)
                } else if let inv = invoice {
                    detail(inv)
                } else if let error {
                    Text(error).font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 40)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private func detail(_ inv: PublicInvoiceDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(TaliseFormat.usd2(inv.amountUsd))
                    .font(TaliseFont.display(34, weight: .medium)).foregroundStyle(TaliseColor.fg)
                if let issuer = inv.issuer {
                    Text("To \(issuer.name ?? issuer.handle)")
                        .font(TaliseFont.body(14)).foregroundStyle(TaliseColor.fgMuted)
                }
                if let memo = inv.memo, !memo.isEmpty {
                    Text(memo).font(TaliseFont.body(13, weight: .light)).foregroundStyle(TaliseColor.fgMuted)
                }
            }
            if let error {
                Text(error).font(TaliseFont.body(12)).foregroundStyle(TaliseColor.danger)
            }
            if inv.status == "open" {
                SlideToConfirm(title: paying ? "Paying…" : "Slide to pay") { await pay(inv) }
                    .disabled(paying || inv.issuer == nil).opacity(paying ? 0.5 : 1)
            } else {
                Text("This invoice is \(inv.status).").font(TaliseFont.body(13)).foregroundStyle(TaliseColor.fgMuted)
            }
        }
    }

    private var paidState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 30)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56)).foregroundStyle(TaliseColor.greenMint)
                .frame(width: 96, height: 96).background(Circle().fill(TaliseColor.greenMint.opacity(0.16)))
            Text("Invoice paid").font(TaliseFont.heading(22, weight: .medium)).foregroundStyle(TaliseColor.fg)
            LiquidGlassButton(title: "Done", tint: TaliseColor.greenMint, action: onDone).padding(.top, 10)
        }.frame(maxWidth: .infinity)
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let resp: InvoiceDetailResp = try await APIClient.shared.get("/api/invoices/\(invoiceId)")
            invoice = resp.invoice
        } catch APIError.status(let code, let msg) {
            error = friendlyWorkError(code: code, message: msg, noun: "invoice")
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't open this invoice right now."
        }
    }

    private func pay(_ inv: PublicInvoiceDTO) async {
        guard let issuer = inv.issuer else { return }
        paying = true; error = nil
        defer { paying = false }
        do {
            let sent = try await ZkLoginCoordinator.shared.signAndSubmitSend(
                to: issuer.address, amountUsd: inv.amountUsd, intent: "Pay invoice"
            )
            NotificationCenter.default.post(name: .taliseTxCompleted, object: TaliseTxEvent(
                digest: sent.digest, direction: "sent", amountUsdsui: inv.amountUsd,
                counterparty: issuer.address, counterpartyName: issuer.handle, venue: nil))
            // Settle trustlessly — server verifies the digest credited the issuer.
            struct SettleBody: Encodable { let digest: String }
            let r: InvoiceSettleResp = try await APIClient.shared.post(
                "/api/invoices/\(invoiceId)/settle", body: SettleBody(digest: sent.digest)
            )
            if r.ok { withAnimation { paid = true } }
        } catch APIError.status(let code, let msg) {
            error = friendlyWorkError(code: code, message: msg, noun: "invoice")
        } catch ZkLoginCoordinator.SessionError.rebindRequired {
            error = "Sign in again — your session needs a refresh."
            session.signOut()
        } catch {
            if APIError.isCancellation(error) { return }
            self.error = "Couldn't pay this invoice right now."
        }
    }
}

// MARK: - Shared error mapping for Work (invoices + contracts)

/// Map rollout / not-found responses to reassuring copy; surface real,
/// actionable server messages (rate limits, validation) verbatim.
func friendlyWorkError(code: Int, message: String?, noun: String) -> String {
    let lower = (message ?? "").lowercased()
    if code == 503 || lower.contains("not configured") || lower.contains("disabled") {
        return "This is rolling out — check back soon."
    }
    if code == 429 { return "Too many requests — give it a moment and try again." }
    // Body is often JSON like {"error":"…"} — pull the message out.
    if let data = message?.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let e = obj["error"] as? String, !e.isEmpty {
        return e
    }
    if let msg = message, !msg.isEmpty { return msg }
    return "Couldn't load the \(noun) right now."
}
