import SwiftUI
import SafariServices

/// Bridge ADD-MONEY screen for a chosen corridor. Fetches the funding session
/// and renders one of:
///   • Verify-identity step (hosted Bridge KYC opened in Safari), or
///   • Bank deposit instructions (the virtual account to send fiat to), or
///   • a clean "not available yet" state when Bridge isn't configured.
///
/// Funds land as USDsui directly on the user's Sui address — no swap.
struct BridgeOnrampView: View {
    let corridor: RampCorridor

    @State private var session: OnrampSessionResponse?
    @State private var loading = true
    @State private var unavailable = false
    @State private var errorText: String?
    @State private var safariURL: URL?
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if loading {
                    loadingCard
                } else if unavailable {
                    unavailableCard
                } else if let di = session?.depositInstructions {
                    depositCard(di)
                } else if let kyc = session?.kycUrl {
                    verifyCard(kyc)
                } else if let errorText {
                    messageCard(title: "Something went wrong", body: errorText)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $safariURL) { url in RampSafariView(url: url) }
        .overlay(alignment: .bottom) { copiedToast }
        .animation(.snappy(duration: 0.25), value: copied)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedFlag(code: corridor.code, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Add money · \(corridor.name)")
                    .font(TaliseFont.heading(20, weight: .medium))
                    .kerning(-0.4)
                    .foregroundStyle(TaliseColor.fg)
                Text("Fund in \(corridor.currencyCode) — lands as USDsui on Sui.")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(TaliseColor.greenMint)
            Text("Setting up your funding details…")
                .font(TaliseFont.body(14, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
            Spacer(minLength: 0)
        }
        .padding(18)
        .rampCard()
    }

    private var unavailableCard: some View {
        messageCard(
            title: "Not available just yet",
            body: "Bank funding for \(corridor.name) is being switched on. You can still receive USDsui to your Talise address in the meantime."
        )
    }

    private func verifyCard(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Verify your identity", systemImage: "checkmark.shield.fill")
                .font(TaliseFont.heading(16, weight: .semibold))
                .foregroundStyle(TaliseColor.fg)
            Text("A quick, secure check (handled by Bridge) before your bank funding goes live. Takes a couple of minutes.")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let u = URL(string: url) { safariURL = u }
            } label: {
                Text("Continue")
                    .font(TaliseFont.body(15, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(TaliseColor.greenMint))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .rampCard()
    }

    private func depositCard(_ di: BridgeDepositInstructions) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send \(di.currency.uppercased()) to this account")
                .font(TaliseFont.heading(16, weight: .semibold))
                .foregroundStyle(TaliseColor.fg)
            Text("Transfer from your bank — the amount you send arrives as USDsui on Sui, usually within minutes.")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                if let v = di.beneficiaryName { copyRow("Beneficiary", v) }
                if let v = di.bankName { copyRow("Bank", v) }
                if let v = di.accountNumber { copyRow("Account number", v) }
                if let v = di.routingNumber { copyRow("Routing number", v) }
                if let v = di.iban { copyRow("IBAN", v) }
                if let v = di.bic { copyRow("BIC", v) }
                if let v = di.depositMessage { copyRow("Reference", v) }
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(TaliseColor.surface2.opacity(0.5))
            )
        }
        .padding(18)
        .rampCard()
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            UISelectionFeedbackGenerator().selectionChanged()
            copied = label
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                copied = nil
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(TaliseFont.mono(10, weight: .regular))
                        .kerning(0.4)
                        .foregroundStyle(TaliseColor.fgDim)
                    Text(value)
                        .font(TaliseFont.body(15, weight: .regular))
                        .foregroundStyle(TaliseColor.fg)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TaliseColor.fgDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func messageCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TaliseFont.heading(16, weight: .semibold))
                .foregroundStyle(TaliseColor.fg)
            Text(body)
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .rampCard()
    }

    @ViewBuilder private var copiedToast: some View {
        if let copied {
            Text("\(copied) copied")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.fg)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Capsule().fill(TaliseColor.surface2))
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            // Amount is nominal — a virtual account accepts any deposit; the
            // route just requires a positive value. Currency = the corridor's
            // so a EUR user funds a SEPA account, not USD.
            session = try await BridgeRampAPI.onrampSession(
                amountCents: 10_000,
                currency: corridor.currencyCode
            )
        } catch {
            let msg = (error as NSError).localizedDescription
            // 404 (flag off) / 503 (Bridge unset) → clean "not available" state.
            if msg.contains("404") || msg.contains("disabled") || msg.contains("503") {
                unavailable = true
            } else {
                errorText = "We couldn't set up funding right now. Please try again."
            }
        }
    }
}

/// Shared SFSafariViewController host for the ramps (KYC redirect). Mirrors
/// the private one in DepositFlowView; lives here so the Ramps module is
/// self-contained.
struct RampSafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let cfg = SFSafariViewController.Configuration()
        cfg.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: cfg)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// `URL` is Identifiable for `.sheet(item:)` in the ramps module.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
