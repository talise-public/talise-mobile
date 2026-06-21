import SwiftUI
import UIKit

/// On-chain receipt — appears when the user taps "Details" on an
/// activity row. Mirrors the web app's receipt: amount in the user's
/// display currency, USDsui below, counterparty, timestamp, and the
/// Suiscan link to the canonical tx digest. Always the chain as the
/// source of truth.
struct TxReceiptView: View {
    let entry: ActivityEntryDTO
    @Environment(\.dismiss) private var dismiss
    @State private var digestCopied = false
    @State private var showShareableReceipt = false

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                directionBadge
                amountBlock
                detailsCard
                actions
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task {
            // If the FX cache is stale (cold launch with old persisted
            // rates), refresh in the background so the amount picks up
            // the right local-currency conversion the next time the
            // view re-renders.
            if CurrencySettings.shared.isStale() {
                await CurrencySettings.shared.refresh()
            }
        }
        .sheet(isPresented: $showShareableReceipt) {
            ShareableReceiptSheet(
                headerLabel: headerLabel,
                primaryAmount: primaryAmount,
                usdsuiLine: usdsuiLine,
                rows: receiptRows,
                statusLabel: entry.offramp.map { cashOutStatusLabel($0.status) },
                digest: entry.digest,
                accent: badgeFg,
                isCashout: category == .cashout
            )
            .presentationDetents([.large])
            .presentationBackground(TaliseColor.bg)
        }
    }

    // MARK: - Direction badge

    /// Category — mirrors HistoryRow's classification so the receipt
    /// hero matches the row the user tapped. Earlier versions hardcoded
    /// `isReceived ? received : sent`, which left every invest/withdraw
    /// receipt rendering with the brick-red "Sent" badge + label.
    private enum Category {
        case sent, received, invest, withdraw, cashout
    }

    private var category: Category {
        // A fiat off-ramp (Linq) rides direction "sent" but renders as its
        // own CASH-OUT receipt — bank destination, naira payout, FX rate.
        if entry.offramp != nil { return .cashout }
        switch entry.direction {
        case "received": return .received
        case "invest":   return .invest
        case "withdraw": return .withdraw
        default:         return .sent
        }
    }

    private var badgeBg: Color {
        switch category {
        case .sent:     return TaliseColor.badgeSent
        case .cashout:  return TaliseColor.badgeSent
        case .received: return TaliseColor.badgeReceived
        case .invest:   return TaliseColor.accent.opacity(0.22)
        case .withdraw: return TaliseColor.badgeReceived
        }
    }

    private var badgeFg: Color {
        switch category {
        case .sent:     return Color(hex: 0xE08D8A)
        case .cashout:  return Color(hex: 0xE08D8A)
        case .received: return Color(hex: 0x79D96C)
        case .invest:   return TaliseColor.accent
        case .withdraw: return Color(hex: 0x79D96C)
        }
    }

    private var badgeIcon: String {
        switch category {
        case .sent:     return "arrow.up.right"
        case .cashout:  return "building.columns"
        case .received: return "arrow.down.left"
        case .invest:   return "leaf.fill"
        case .withdraw: return "leaf"
        }
    }

    private var headerLabel: String {
        switch category {
        case .sent:     return "Sent"
        case .cashout:  return "Cash out"
        case .received: return "Received"
        case .invest:
            if let v = entry.venue, !v.isEmpty {
                return "Invested in \(displayVenueName(v))"
            }
            return "Invested"
        case .withdraw:
            if let v = entry.venue, !v.isEmpty {
                return "Withdrew from \(displayVenueName(v))"
            }
            return "Withdrew"
        }
    }

    private var directionBadge: some View {
        VStack(spacing: 10) {
            ZStack {
                // FLAT hero chip — a solid tinted disc, no gradient highlight,
                // white rim, or shadow.
                Circle()
                    .fill(badgeBg)
                    .frame(width: 68, height: 68)
                Image(systemName: badgeIcon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(badgeFg)
            }
            MicroLabel(text: headerLabel, color: TaliseColor.fgDim)
                .kerning(2.0)
        }
        .padding(.top, 16)
    }

    // MARK: - Amount

    private var amountBlock: some View {
        VStack(spacing: 6) {
            Text(primaryAmount)
                .font(TaliseFont.display(40, weight: .medium))
                .kerning(-1.4)
                .foregroundStyle(category == .cashout ? Color(hex: 0xE5484D) : TaliseColor.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let usdsui = entry.amountUsdsui {
                Text(String(format: "%@ USDsui", TaliseFormat.usd2(Swift.abs(usdsui))))
                    .font(TaliseFont.mono(12, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
        }
    }

    private var primaryAmount: String {
        // U+202F NARROW NO-BREAK SPACE between sign and currency symbol
        // so "-₦0.01" doesn't render with the minus stroke kissing the
        // ₦ glyph at this big point size.
        // Inflow (received + withdraw from a venue) reads "+"; outflow
        // (sent + invest into a venue) reads "-".
        // Cash-out hero is the NGN payout the user received, in red-outflow
        // form ("-‍₦142,350.00"). The USDsui leg drops to the subtitle below.
        if let off = entry.offramp {
            return "-\u{202F}" + TaliseFormat.ngn(off.amountNgn)
        }
        let isInflow = entry.isReceived || entry.isWithdraw
        let prefix = isInflow ? "+\u{202F}" : "-\u{202F}"
        // Non-USDsui/non-SUI movement (WAL, USDC, USDT, …) — show the actual
        // token amount + symbol rather than a "—" the row already avoids.
        if let other = entry.otherCoin {
            return "\(prefix)\(other.displayAmount) \(other.symbol)"
        }
        if let usd = entry.amountUsdsui {
            return prefix + TaliseFormat.local2(Swift.abs(usd))
        }
        if let sui = entry.amountSui {
            return String(format: "\(prefix)%.4f SUI", Swift.abs(sui))
        }
        return prefix + "—"
    }

    // MARK: - Details card

    @ViewBuilder
    private var detailsCard: some View {
        if let off = entry.offramp {
            cashOutDetailsCard(off)
        } else {
            transferDetailsCard
        }
    }

    /// CASH-OUT receipt body: destination bank, the USDsui debited, the
    /// applied FX rate, the disbursement status, date, and the on-chain
    /// digest (the chain leg is still the source of truth — keeps the
    /// Suiscan link working).
    private func cashOutDetailsCard(_ off: OfframpInfo) -> some View {
        VStack(spacing: 0) {
            row(label: "To", value: cashOutDestination(off))
            divider
            if let usd = entry.amountUsdsui {
                row(label: "You sent",
                    value: String(format: "%@ USDsui", TaliseFormat.usd2(Swift.abs(usd))))
                divider
            }
            row(label: "Rate", value: "$1 = \(TaliseFormat.ngn(off.rate))")
            divider
            row(label: "Status", value: cashOutStatusLabel(off.status))
            divider
            row(label: "Date", value: dateFormatter.string(from: timestamp))
            divider
            row(label: "Digest", value: shortDigest, mono: true)
        }
        .padding(.vertical, 4)
        .receiptFlatCard(cornerRadius: 22)
    }

    private func cashOutDestination(_ off: OfframpInfo) -> String {
        let bank = (off.bankName?.isEmpty == false) ? off.bankName! : "Bank"
        if let last4 = off.accountLast4, !last4.isEmpty {
            return "\(bank) \u{2022}\u{2022}\u{2022}\u{2022}\(last4)"
        }
        return bank
    }

    /// Friendly Linq status → user-facing copy.
    private func cashOutStatusLabel(_ status: String) -> String {
        // Linq statuses are free text (e.g. "Settled in treasury") — substring-match.
        let s = status.lowercased()
        if s.contains("disburse") || s.contains("settled") || s.contains("complete")
            || s.contains("success") || s.contains("paid") {
            return "Paid out"
        }
        if s.contains("timeout") || s.contains("fail") || s.contains("error")
            || s.contains("cancel") || s.contains("reject") || s.contains("declin") {
            return "Failed"
        }
        return "Pending"
    }

    private var transferDetailsCard: some View {
        VStack(spacing: 0) {
            // Counterparty row depends on direction:
            //   sent     → "To"   <recipient>
            //   received → "From" <sender>
            //   invest   → "Venue" <NAVI/DEEPBOOK>
            //   withdraw → "Venue" <NAVI/DEEPBOOK>
            // Old code always said "From" which read backwards for any
            // outgoing transfer, and showed "—" for venue txs because
            // there's no AddressOwner counterparty.
            switch category {
            // `.cashout` is routed to `cashOutDetailsCard` before we ever
            // reach here, so this branch is unreachable — but the switch
            // must remain exhaustive.
            case .sent, .cashout:
                row(label: "To", value: counterpartyOrAddress, mono: !hasCounterpartyName)
            case .received:
                row(label: "From", value: counterpartyOrAddress, mono: !hasCounterpartyName)
            case .invest, .withdraw:
                row(
                    label: "Venue",
                    value: entry.venue.map(displayVenueName) ?? "—"
                )
            }
            // Round-up save leg — only on sends that bundled an auto-save.
            // Shows the concrete portion that went to the user's savings so
            // the receipt explains the "+ saved" the row title advertised.
            if let save = entry.roundupUsdsui, save > 0 {
                divider
                row(label: "Saved", value: "+\(TaliseFormat.local2(save))")
            }
            divider
            row(label: "Date", value: dateFormatter.string(from: timestamp))
            divider
            row(label: "Network", value: "Sui Mainnet")
            divider
            row(label: "Digest", value: shortDigest, mono: true)
        }
        .padding(.vertical, 4)
        .receiptFlatCard(cornerRadius: 22)
    }

    private func row(label: String, value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            Spacer()
            Text(value)
                .font(mono
                      ? TaliseFont.mono(12, weight: .light)
                      : TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fg)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.05))
            .frame(height: 1).padding(.horizontal, 14)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            // PRIMARY — Talise receipt the user can save / share as an image.
            Button {
                showShareableReceipt = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 13, weight: .medium))
                    Text("View Receipt")
                        .font(TaliseFont.heading(15, weight: .medium))
                }
                .foregroundStyle(TaliseColor.bg)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(TaliseColor.fg)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // SECONDARY — the canonical on-chain record on SuiVision.
            Button {
                openSuiVision()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .medium))
                    Text("View on SuiVision")
                        .font(TaliseFont.heading(15, weight: .medium))
                }
                .foregroundStyle(TaliseColor.fg)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                // FLAT secondary action — a solid surface2 capsule.
                .background(Capsule().fill(TaliseColor.surface2))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // TERTIARY — quiet copy-digest text action.
            Button {
                UIPasteboard.general.string = entry.digest
                withAnimation(.easeInOut(duration: 0.15)) { digestCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run { digestCopied = false }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: digestCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                    Text(digestCopied ? "Copied" : "Copy digest")
                        .font(TaliseFont.body(13, weight: .light))
                }
                .foregroundStyle(TaliseColor.fgMuted)
                .frame(height: 36)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private var hasCounterpartyName: Bool {
        (entry.counterpartyName?.isEmpty == false)
    }

    private var counterpartyOrAddress: String {
        if let name = entry.counterpartyName, !name.isEmpty { return name }
        if let addr = entry.counterparty {
            return short(addr)
        }
        return "—"
    }

    private var shortDigest: String {
        let d = entry.digest
        guard d.count > 14 else { return d }
        return String(d.prefix(10)) + "…" + String(d.suffix(6))
    }

    private var timestamp: Date {
        Date(timeIntervalSince1970: entry.timestampMs / 1000)
    }

    private func short(_ a: String) -> String {
        guard a.count > 14 else { return a }
        return String(a.prefix(8)) + "…" + String(a.suffix(6))
    }

    private func openSuiVision() {
        guard let url = URL(string: "https://suivision.xyz/txblock/\(entry.digest)") else {
            return
        }
        UIApplication.shared.open(url)
    }

    /// The "X USDsui" subtitle line, shared by the on-screen amount block and
    /// the shareable receipt.
    private var usdsuiLine: String? {
        guard let usdsui = entry.amountUsdsui else { return nil }
        return String(format: "%@ USDsui", TaliseFormat.usd2(Swift.abs(usdsui)))
    }

    /// The detail rows, derived once and reused by the on-screen card and the
    /// shareable receipt so the two never drift.
    private var receiptRows: [ReceiptRowData] {
        if let off = entry.offramp {
            var rows: [ReceiptRowData] = [
                ReceiptRowData(label: "To", value: cashOutDestination(off), mono: false),
            ]
            if let usd = entry.amountUsdsui {
                rows.append(ReceiptRowData(
                    label: "You sent",
                    value: String(format: "%@ USDsui", TaliseFormat.usd2(Swift.abs(usd))),
                    mono: false))
            }
            rows.append(ReceiptRowData(label: "Rate", value: "$1 = \(TaliseFormat.ngn(off.rate))", mono: false))
            rows.append(ReceiptRowData(label: "Status", value: cashOutStatusLabel(off.status), mono: false))
            rows.append(ReceiptRowData(label: "Date", value: dateFormatter.string(from: timestamp), mono: false))
            rows.append(ReceiptRowData(label: "Network", value: "Sui Mainnet", mono: false))
            return rows
        }
        var rows: [ReceiptRowData] = []
        switch category {
        case .received:
            rows.append(ReceiptRowData(label: "From", value: counterpartyOrAddress, mono: !hasCounterpartyName))
        case .invest, .withdraw:
            rows.append(ReceiptRowData(label: "Venue", value: entry.venue.map(displayVenueName) ?? "—", mono: false))
        case .sent, .cashout:
            rows.append(ReceiptRowData(label: "To", value: counterpartyOrAddress, mono: !hasCounterpartyName))
        }
        // Round-up save leg — mirrors the on-screen card so the two never drift.
        if let save = entry.roundupUsdsui, save > 0 {
            rows.append(ReceiptRowData(label: "Saved", value: "+\(TaliseFormat.local2(save))", mono: false))
        }
        rows.append(ReceiptRowData(label: "Date", value: dateFormatter.string(from: timestamp), mono: false))
        rows.append(ReceiptRowData(label: "Network", value: "Sui Mainnet", mono: false))
        return rows
    }
}

/// One label/value pair on a receipt.
struct ReceiptRowData: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let mono: Bool
}

/// FLAT card for the receipt's details block — a single solid
/// `TaliseColor.surface` fill on a continuous rounded rectangle. No
/// material, blur, gradient sheen, gradient stroke, or shadow.
private struct ReceiptFlatCard: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(TaliseColor.surface))
            .clipShape(shape)
    }
}

private extension View {
    func receiptFlatCard(cornerRadius: CGFloat = 22) -> some View {
        modifier(ReceiptFlatCard(cornerRadius: cornerRadius))
    }
}

// MARK: - Shareable receipt

/// A branded, downloadable/shareable receipt. Renders the card to an image and
/// offers it through the system share sheet (Save to Photos, WhatsApp, etc.).
/// This is the Talise receipt; the on-chain record is "View on SuiVision".
struct ShareableReceiptSheet: View {
    let headerLabel: String
    let primaryAmount: String
    let usdsuiLine: String?
    let rows: [ReceiptRowData]
    let statusLabel: String?
    let digest: String
    let accent: Color
    let isCashout: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var rendered: UIImage?

    private let cardWidth: CGFloat = 340

    private var card: ShareableReceiptCard {
        ShareableReceiptCard(
            headerLabel: headerLabel,
            primaryAmount: primaryAmount,
            usdsuiLine: usdsuiLine,
            rows: rows,
            digest: digest,
            isCashout: isCashout
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Receipt")
                    .font(TaliseFont.heading(17, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TaliseColor.fgMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 6)

            ScrollView {
                card
                    .frame(width: cardWidth)
                    .padding(.vertical, 18)
            }

            shareButton
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .onAppear(perform: renderImage)
    }

    @ViewBuilder
    private var shareButton: some View {
        if let img = rendered {
            ShareLink(
                item: Image(uiImage: img),
                preview: SharePreview("Talise receipt", image: Image(uiImage: img))
            ) {
                shareLabel(enabled: true)
            }
            .buttonStyle(.plain)
        } else {
            shareLabel(enabled: false)
        }
    }

    private func shareLabel(enabled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14, weight: .medium))
            Text("Save / Share receipt")
                .font(TaliseFont.heading(15, weight: .medium))
        }
        .foregroundStyle(TaliseColor.bg)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(TaliseColor.fg)
        .clipShape(Capsule())
        .opacity(enabled ? 1 : 0.5)
    }

    @MainActor private func renderImage() {
        let renderer = ImageRenderer(content: card.frame(width: cardWidth))
        renderer.scale = max(UIScreen.main.scale, 3)
        rendered = renderer.uiImage
    }
}

/// The visual receipt itself — also used standalone by the renderer.
struct ShareableReceiptCard: View {
    let headerLabel: String
    let primaryAmount: String
    let usdsuiLine: String?
    let rows: [ReceiptRowData]
    let digest: String
    let isCashout: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Brand header + amount
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(TaliseColor.greenMint).frame(width: 9, height: 9)
                    Text("talise")
                        .font(TaliseFont.heading(20, weight: .semibold))
                        .kerning(-0.5)
                        .foregroundStyle(TaliseColor.fg)
                }
                Text(headerLabel.uppercased())
                    .font(TaliseFont.mono(11, weight: .regular))
                    .kerning(2)
                    .foregroundStyle(TaliseColor.fgDim)
                Text(primaryAmount)
                    .font(TaliseFont.display(34, weight: .medium))
                    .kerning(-1.2)
                    .foregroundStyle(isCashout ? Color(hex: 0xE5484D) : TaliseColor.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let line = usdsuiLine {
                    Text(line)
                        .font(TaliseFont.mono(12, weight: .light))
                        .foregroundStyle(TaliseColor.fgMuted)
                }
            }
            .padding(.top, 30)
            .padding(.bottom, 22)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)

            DashedLine()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Color.white.opacity(0.10))
                .frame(height: 1)
                .padding(.horizontal, 20)

            // Detail rows
            VStack(spacing: 0) {
                ForEach(rows) { r in
                    HStack {
                        Text(r.label)
                            .font(TaliseFont.body(13, weight: .light))
                            .foregroundStyle(TaliseColor.fgMuted)
                        Spacer()
                        Text(r.value)
                            .font(r.mono
                                  ? TaliseFont.mono(12, weight: .light)
                                  : TaliseFont.body(13, weight: .light))
                            .foregroundStyle(TaliseColor.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 12)
                    if r.id != rows.last?.id {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 6)

            // Digest
            VStack(spacing: 6) {
                Text("TRANSACTION DIGEST")
                    .font(TaliseFont.mono(9, weight: .regular))
                    .kerning(1.5)
                    .foregroundStyle(TaliseColor.fgDim)
                Text(digest)
                    .font(TaliseFont.mono(10, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 18)

            // Footer
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(TaliseColor.greenMint)
                Text("Verified on Sui Mainnet · talise.io")
                    .font(TaliseFont.body(11, weight: .light))
                    .foregroundStyle(TaliseColor.fgDim)
            }
            .padding(.bottom, 24)
        }
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(TaliseColor.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

/// A single horizontal dashed rule used as the receipt's perforation line.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return p
    }
}
