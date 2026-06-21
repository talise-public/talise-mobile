import SwiftUI

/// Single history row. Reused by Home (top 4) and HistoryView (full list).
///
/// FLAT row — the enclosing card supplies the surface; the row itself is
/// transparent at rest with a flat solid circular icon chip. On press it
/// picks up a faint directional wash:
///   • Sent     → small forest-green wash
///   • Received → small mint-green wash
///   • Other    → no tint (neutral)
///
/// No material, blur, or gradient — clean Apple-system list row.
struct HistoryRow: View {
    /// Mirrors the Home privacy eye — when on, amounts render as dots.
    @AppStorage("talise.amountsHidden") private var amountsHidden = false

    let entry: ActivityEntryDTO
    let onTap: () -> Void
    /// Optional callback fired when the user taps the "Swap to USDsui"
    /// CTA that appears on inbound non-USDsui coin rows (2026-05-29 —
    /// replaces the archived auto-swap cron). When nil, the CTA is
    /// hidden and the row behaves as before.
    var onSwapToUsdsui: (() -> Void)? = nil

    /// True when the inbound coin on this row should surface the
    /// "Swap to USDsui" affordance. Triggers on:
    ///   • direction == "received"
    ///   • otherCoin present (i.e. NOT a plain USDsui/SUI receive)
    ///   • otherCoin.symbol is not already USDsui
    private var showsSwapCTA: Bool {
        guard onSwapToUsdsui != nil else { return false }
        guard entry.direction == "received" else { return false }
        guard let other = entry.otherCoin else { return false }
        return other.symbol.uppercased() != "USDSUI"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    // Tinted directional badge — a FLAT solid circular chip.
                    // Mossy green for Received, forest for Sent, accent for
                    // Invest. No gradient highlight, no white rim — just a
                    // clean colored disc.
                    Circle()
                        .fill(badgeBgColor)
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(badgeFgColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(TaliseFont.body(13, weight: .light))
                            .kerning(-0.48)
                            .foregroundStyle(TaliseColor.fg)
                        // Cash-out rows carry a small disbursement-status
                        // pill (Pending / Paid out / Failed) so the user
                        // can tell at a glance whether the naira has landed.
                        if let pill = offrampStatusPill {
                            Text(pill.label)
                                .font(TaliseFont.body(9, weight: .semibold))
                                .kerning(0.2)
                                .foregroundStyle(pill.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(pill.color.opacity(0.16))
                                )
                        }
                    }
                    MicroLabel(text: subtitle, color: TaliseColor.fgDim)
                        .kerning(-0.32)
                    if showsSwapCTA {
                        // "Swap to USDsui" — small, accent-tinted CTA
                        // shown directly under the subtitle on inbound
                        // non-USDsui coin rows. Replaces the archived
                        // auto-swap cron. POSTs `/api/swap/prepare` via
                        // the caller-supplied `onSwapToUsdsui` handler.
                        Button {
                            onSwapToUsdsui?()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Swap to USDsui")
                                    .font(TaliseFont.body(11, weight: .medium))
                            }
                            .foregroundStyle(TaliseColor.accent)
                            .padding(.top, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                // Amount only — the whole row is tappable so the
                // "Details ↗" eyebrow was visual filler. Subtitle
                // already carries the "tap me" affordance via the
                // row-press tint.
                Text(amountsHidden ? "\u{2022}\u{2022}\u{2022}\u{2022}" : amountFormatted)
                    .font(TaliseFont.body(14, weight: .light))
                    .kerning(-0.56)
                    .foregroundStyle(amountsHidden ? TaliseColor.fgMuted : amountColor)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        // Directional tint is only applied while the user is pressing
        // the row — at rest the row reads as neutral glass; on press
        // it picks up red (sent) or green (received) with a smooth
        // crossfade. Neutral category never tints.
        .buttonStyle(HistoryRowButtonStyle(
            tintColor: tintColor,
            tintAlpha: tintAlpha
        ))
    }

    // MARK: - Category + tint

    private enum Category {
        case sent
        case received
        case invest
        case withdraw
        case autoswap
        case cashout
        case neutral
    }

    /// Server-side `direction` field carries the classification. Plain
    /// transfers ride the chain-derived sent/received; yield venue
    /// txs (DeepBook supply, NAVI lending) come back as
    /// `invest`/`withdraw`; vault auto-swap conversions come back as
    /// `autoswap` (emitted by `VaultAutoSwap` event in the Move
    /// `talise::vault` module). Each gets its own icon + tint.
    private var category: Category {
        // A fiat off-ramp comes back as direction "sent" (venue "linq") but
        // we surface it as its own CASH-OUT category so it never reads as an
        // anonymous on-chain transfer.
        if entry.offramp != nil { return .cashout }
        switch entry.direction {
        case "received": return .received
        case "invest":   return .invest
        case "withdraw": return .withdraw
        case "autoswap": return .autoswap
        // DEX swaps (the legacy Convert banner, manual Cetus calls,
        // anything where the user moved one coin in and a different
        // one out in the same tx) share the auto-swap visual
        // language — green leaf, accent tint — because the user
        // doesn't care which path moved the funds; what matters is
        // "I converted X into Y." Auto-swap and manual swap render
        // identically.
        case "swap":     return .autoswap
        case "sent":     return .sent
        default:         return .neutral
        }
    }

    // Direction reads by COLOR: RED for money-out (Sent), GREEN for money-in
    // (Received). Invest / withdraw / auto-swap stay on the brand accent green.
    private var tintColor: Color {
        switch category {
        case .sent:     return Color(hex: 0xE5484D)
        case .cashout:  return Color(hex: 0xE5484D)
        case .received: return Color(hex: 0x79D96C)
        case .invest:   return TaliseColor.accent
        case .withdraw: return Color(hex: 0x79D96C)
        case .autoswap: return TaliseColor.accent
        case .neutral:  return TaliseColor.fgMuted
        }
    }

    /// Circular badge fill — a flat green disc (no glass). Money-in gets the
    /// LIGHT mint shade; money-out gets the LOW forest shade.
    private var badgeBgColor: Color {
        switch category {
        case .sent:     return Color(hex: 0xE5484D).opacity(0.16)
        case .cashout:  return Color(hex: 0xE5484D).opacity(0.16)
        case .received: return Color(hex: 0x79D96C).opacity(0.20)
        case .invest:   return TaliseColor.accent.opacity(0.20)
        case .withdraw: return Color(hex: 0xCAFFB8).opacity(0.42)
        case .autoswap: return TaliseColor.accent.opacity(0.20)
        case .neutral:  return TaliseColor.surface2
        }
    }

    /// Arrow color inside the badge — a deeper green on the light mint disc,
    /// a brighter accent green on the low forest wash. Always green-on-green.
    private var badgeFgColor: Color {
        switch category {
        case .sent:     return Color(hex: 0xFF6B6B)
        case .cashout:  return Color(hex: 0xFF6B6B)
        case .received: return Color(hex: 0xCAFFB8)
        case .invest:   return TaliseColor.accent
        case .withdraw: return Color(hex: 0x2E5E1F)
        case .autoswap: return TaliseColor.accent
        case .neutral:  return TaliseColor.fg
        }
    }

    private var tintAlpha: Double {
        switch category {
        case .sent, .cashout, .received, .invest, .withdraw, .autoswap: return 0.18
        case .neutral:                                                  return 0
        }
    }

    /// SF Symbol used in the circular badge. Invest uses the leaf
    /// (matches the Invest tab bar icon, so the connection between
    /// "the tab I supplied from" and "this row" is visual not just
    /// textual). Withdraw mirrors with the leaf inverted via
    /// arrow.down-on-leaf — see invest case below.
    private var iconName: String {
        switch category {
        case .sent:     return "arrow.up.right"
        case .cashout:  return "building.columns"
        case .received: return "arrow.down.left"
        case .invest:   return "leaf.fill"
        case .withdraw: return "leaf"
        // Auto-swap reuses the leaf — same family as the Earn / Invest
        // tab, signalling "the system worked for you". The conversion
        // is implicit in the title ("Auto-swapped 0.5 SUI → $1.20").
        case .autoswap: return "leaf.fill"
        case .neutral:  return "circle"
        }
    }

    /// Small disbursement-status pill for cash-out rows. Nil when the row
    /// isn't a cash-out, or when the payout is already settled (a "Paid out"
    /// pill on a done payout is noise — the red naira amount already reads
    /// as a completed outflow). Only surfaces Pending / Failed.
    private var offrampStatusPill: (label: String, color: Color)? {
        guard let off = entry.offramp else { return nil }
        // Linq statuses are free text ("Settled in treasury", "disbursed",
        // "processing: in bank queue", "timeout: no deposit received"…), so
        // substring-match rather than exact-match.
        let s = off.status.lowercased()
        if s.contains("disburse") || s.contains("settled") || s.contains("complete")
            || s.contains("success") || s.contains("paid") {
            return nil // done — the red naira amount already reads as a completed outflow
        }
        if s.contains("timeout") || s.contains("fail") || s.contains("error")
            || s.contains("cancel") || s.contains("reject") || s.contains("declin") {
            return ("Failed", Color(hex: 0xE5484D))
        }
        return ("Pending", Color(hex: 0xD9A441))
    }

    /// Named counterparty for the row title — the resolved @handle/name when
    /// the server gave us one, else a shortened 0x address, else nil (so the
    /// title falls back to a bare verb). Mirrors the receipt's resolution.
    private var counterpartyLabel: String? {
        if let name = entry.counterpartyName, !name.isEmpty { return name }
        if let addr = entry.counterparty, !addr.isEmpty {
            guard addr.count > 14 else { return addr }
            return String(addr.prefix(6)) + "\u{2026}" + String(addr.suffix(4))
        }
        return nil
    }

    private var title: String {
        // Fiat cash-out takes priority over every other classification.
        if let off = entry.offramp {
            if let bank = off.bankName, !bank.isEmpty {
                return "Cash out \u{2192} \(bank)"
            }
            return "Cash out"
        }
        // Non-USDsui/non-SUI rows (WAL, USDC, USDT, …) override the
        // default "Sent"/"Received" so the row clearly shows the coin.
        if let other = entry.otherCoin {
            return entry.isReceived
                ? "Received \(other.symbol)"
                : "Sent \(other.symbol)"
        }
        switch category {
        case .sent:
            // Prefer a named/short-address counterparty so the row reads
            // "Sent to ruru@talise" instead of an anonymous "Sent". When the
            // send bundled a round-up save leg, the verb carries it inline.
            if let who = counterpartyLabel {
                return entry.hasRoundup ? "Sent to \(who) + saved" : "Sent to \(who)"
            }
            return entry.hasRoundup ? "Sent + saved" : "Sent"
        // Unreachable — the offramp guard above returns first — but the
        // switch must stay exhaustive.
        case .cashout:  return "Cash out"
        case .received:
            if let who = counterpartyLabel { return "Received from \(who)" }
            return "Received"
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
        case .autoswap:
            // Two flavors share this case:
            //   • direction == "autoswap" → the vault's cron-driven
            //     swap (sub-second auto-conversion). Server emits the
            //     source coin via `venue`.
            //   • direction == "swap" → any DEX swap touching the
            //     user's wallet (legacy Convert banner, direct Cetus
            //     call, etc.). For these we render "Swapped X → Y"
            //     using the SUI / otherCoin / USDsui legs we have.
            //
            // Title is just the verb; `amountFormatted` does the
            // "X → Y" composition.
            if entry.direction == "swap" { return "Swapped" }
            if let v = entry.venue, !v.isEmpty {
                return "Auto-swapped \(v.uppercased())"
            }
            return "Auto-swapped to USDsui"
        case .neutral:  return "Activity"
        }
    }

    private var subtitle: String {
        // Cash-out rows show the destination bank + masked account instead
        // of a relative timestamp — the "where the money went" matters more
        // than "when" on a payout.
        if let off = entry.offramp {
            let bank = (off.bankName?.isEmpty == false) ? off.bankName! : "Bank"
            if let last4 = off.accountLast4, !last4.isEmpty {
                return "\(bank) \u{2022}\u{2022}\u{2022}\u{2022}\(last4)"
            }
            return bank
        }
        let date = Date(timeIntervalSince1970: entry.timestampMs / 1000)
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        let relative = fmt.localizedString(for: date, relativeTo: Date())
        // Round-up sends surface the auto-saved portion alongside the
        // timestamp ("Saved $0.40 · 2h ago") so the "+ saved" in the title
        // is backed by a concrete amount.
        if let save = entry.roundupUsdsui, save > 0 {
            return "Saved \(TaliseFormat.local2(save)) \u{2022} \(relative)"
        }
        return relative
    }

    /// Amount color — money IN reads green (matches the design ref where a
    /// received credit is green and a debit is neutral); auto-swap is a
    /// net-neutral conversion so it stays neutral, not green.
    private var amountColor: Color {
        // Cash-out is money leaving the wallet for a bank — render the
        // naira payout in the SENT red so it reads as an outflow.
        if category == .cashout { return Color(hex: 0xE5484D) }
        if category == .autoswap { return TaliseColor.fg }
        let isInflow = entry.isReceived || entry.isWithdraw
        return isInflow ? Color(hex: 0x4FB35E) : TaliseColor.fg
    }

    private var amountFormatted: String {
        // Cash-out shows the NGN payout the user actually received, not
        // the USDsui debit — "−₦142,350.00".
        if let off = entry.offramp {
            return "\u{2212}\(TaliseFormat.ngn(off.amountNgn))"
        }
        // Auto-swap & manual swap are net-neutral economically — one
        // coin in, a different coin out. We render BOTH legs of the
        // transformation ("0.1 SUI → ₦139.59") so the row reads as
        // a conversion rather than a debit/credit. The title already
        // tells the user what category they're looking at.
        if category == .autoswap {
            // Build the leg strings independently so we can compose
            // "from → to" no matter which fields the server populated:
            //   • SUI ↔ USDsui swap: amountSui + amountUsdsui
            //   • USDC/WAL/etc → USDsui: otherCoin + amountUsdsui
            //   • USDsui → SUI (rare): amountUsdsui + amountSui
            var legs: [String] = []
            if let sui = entry.amountSui, sui > 0 {
                legs.append(String(format: "%.4f SUI", sui))
            }
            if let other = entry.otherCoin {
                legs.append("\(other.displayAmount) \(other.symbol)")
            }
            if let usd = entry.amountUsdsui, usd > 0 {
                legs.append(TaliseFormat.local2(usd))
            }
            switch legs.count {
            case 0: return "→ —"
            case 1: return "→ \(legs[0])"
            default:
                // Always end on USDsui when present — that's the
                // canonical Talise unit, and the "destination" the
                // user opted into when they enabled auto-swap.
                return "\(legs[0]) → \(legs[1])"
            }
        }
        // Invest = wallet → pool (debit, "-"); Withdraw = pool → wallet
        // (credit, "+"). Plain transfers use direction directly.
        let isInflow = entry.isReceived || entry.isWithdraw
        let prefix = isInflow ? "+" : "-"
        // Non-USDsui/non-SUI row: format raw u64 with the coin's
        // decimals + symbol. We don't compute a USD value because
        // we don't have a reliable price for arbitrary tokens.
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
}

/// Flat, Apple-system row press style — NO glassmorphism. At rest the row is
/// fully transparent (the enclosing card supplies the surface); on press it
/// picks up a faint wash of the row's directional green + a hairline settle.
/// We deliberately drop the old `.ultraThinMaterial` / black overlay / white
/// gradient border / drop shadow for a clean, flat finish.
private struct HistoryRowButtonStyle: ButtonStyle {
    let tintColor: Color
    let tintAlpha: Double

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return configuration.label
            .background(
                shape.fill(
                    configuration.isPressed
                        ? tintColor.opacity(tintAlpha)
                        : Color.clear
                )
            )
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.99 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
