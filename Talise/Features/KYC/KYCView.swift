import SwiftUI

struct KYCView: View {
    let user: UserDTO
    @Environment(AppSession.self) private var session
    @State private var country: String = "NG"
    @State private var accountType: AccountType = .personal
    @State private var submitting = false
    @State private var error: String?
    /// Off-ramp Phase 3 — drives the optional "get paid in Naira" bank-link
    /// step shown ONLY to Nigeria (country == "NG") after onboarding posts.
    /// Non-Nigeria users never see it; we bootstrap straight through.
    @State private var showBankLink = false

    private let countries: [(String, String)] = [
        ("NG", "Nigeria"),
        ("US", "United States"),
        ("GB", "United Kingdom"),
        ("OTHER", "Other"),
    ]

    var body: some View {
        ZStack {
            // Flat near-black canvas — matches the sign-in screen so the
            // onboarding flow reads as one continuous surface.
            TaliseColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "Verify · 1 of 1")
                        Text("Finish setting up\nyour account")
                            .font(TaliseFont.display(30, weight: .medium))
                            .kerning(-0.8)
                            .foregroundStyle(TaliseColor.fg)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("We verified your Google account. One last step: tell us where you'll be using Talise, and whether this is for you or your business.")
                            .font(TaliseFont.body(14))
                            .foregroundStyle(TaliseColor.fgMuted)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "Country")
                        VStack(spacing: 0) {
                            ForEach(countries, id: \.0) { code, name in
                                row(code: code, name: name)
                                if code != countries.last?.0 {
                                    Rectangle()
                                        .fill(TaliseColor.line)
                                        .frame(height: 1)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: TaliseRadius.lg, style: .continuous)
                                .fill(TaliseColor.surface)
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "Account type")
                        HStack(spacing: 12) {
                            typeTile(.personal, title: "Personal", sub: "Send, receive, earn")
                            typeTile(.business, title: "Business", sub: "Invoices, payroll")
                        }
                    }

                    if let error {
                        Text(error)
                            .font(TaliseFont.body(12))
                            .foregroundStyle(TaliseColor.danger)
                    }

                    // Flat solid primary CTA — green fill, dark ink, no glass.
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if submitting {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                                    .tint(Color(hex: 0x0A140C))
                            } else {
                                Text("Continue")
                                    .font(TaliseFont.heading(16, weight: .medium))
                            }
                        }
                        .foregroundStyle(Color(hex: 0x0A140C))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(TaliseColor.greenMint)
                        )
                        .opacity(submitting ? 0.85 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .disabled(submitting)
                    .padding(.top, 8)
                }
                .padding(24)
            }
        }
        // Nigeria-only optional bank-link step. Presented after a successful
        // /api/onboarding post for country == "NG"; on continue/skip we run
        // the handle claim + bootstrap that the non-NG path runs inline.
        .fullScreenCover(isPresented: $showBankLink) {
            OnboardingBankLinkView(onContinue: {
                showBankLink = false
                Task { await finishOnboarding() }
            })
        }
    }

    private func row(code: String, name: String) -> some View {
        Button {
            country = code
        } label: {
            HStack {
                Text(name)
                    .font(TaliseFont.body(14))
                    .foregroundStyle(TaliseColor.fg)
                Spacer()
                if country == code {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TaliseColor.fg)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func typeTile(_ type: AccountType, title: String, sub: String) -> some View {
        let selected = accountType == type
        return Button {
            accountType = type
        } label: {
            tileLabel(title: title, sub: sub, selected: selected)
        }
        .buttonStyle(.plain)
    }

    /// Selected = a flat brand-green tile (dark ink on the bright mint).
    /// Unselected = a flat neutral surface. No gradient, no specular sheen.
    @ViewBuilder
    private func tileLabel(title: String, sub: String, selected: Bool) -> some View {
        let inkColor: Color = selected ? Color(hex: 0x0A140C) : TaliseColor.fg
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TaliseFont.heading(15))
                .foregroundStyle(inkColor)
            Text(sub)
                .font(TaliseFont.body(12))
                .foregroundStyle(selected ? inkColor.opacity(0.66) : TaliseColor.fgMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: TaliseRadius.md, style: .continuous)
                .fill(selected ? TaliseColor.greenMint : TaliseColor.surface)
        )
        .animation(.easeOut(duration: 0.2), value: selected)
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        struct OnboardBody: Encodable {
            let country: String
            let accountType: String
        }
        struct OnboardResp: Decodable { let ok: Bool }
        do {
            let _: OnboardResp = try await APIClient.shared.post(
                "/api/onboarding",
                body: OnboardBody(country: country, accountType: accountType.rawValue)
            )

            // Nigeria → offer the optional "get paid in Naira" bank-link
            // step before finishing. Every other country bootstraps straight
            // through, exactly as before.
            if country == "NG" {
                showBankLink = true
                return
            }
            await finishOnboarding()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Claims the sponsored SuiNS handle then bootstraps the session into the
    /// authenticated app. Shared by the non-NG inline path and the NG
    /// bank-link continue/skip path so onboarding completes identically.
    private func finishOnboarding() async {
        // Sponsored SuiNS subname mint — the talise.sui operator wallet
        // signs + pays gas, so the user is never asked to fund or sign
        // this transaction. Best-effort: if the handle is taken or the
        // operator is misconfigured, we still proceed to the dashboard
        // (the user can claim later from /settings).
        await claimTaliseHandle()
        await session.bootstrap()
    }

    /// Derives a candidate handle from the user's Google name (falling back
    /// to the email local-part), then POSTs /api/username/claim. On a
    /// collision (HTTP 409), we append a 4-digit suffix and retry up to
    /// three times.
    private func claimTaliseHandle() async {
        let base = candidateHandle()
        guard !base.isEmpty else { return }

        struct ClaimBody: Encodable { let username: String }
        var attempt = 0
        var handle = base
        while attempt < 3 {
            do {
                let _: UsernameClaimResponse = try await APIClient.shared.post(
                    "/api/username/claim",
                    body: ClaimBody(username: handle)
                )
                return
            } catch APIError.status(let code, _) where code == 409 {
                // Taken — append a short numeric suffix and try again.
                let suffix = String(Int.random(in: 100...9999))
                handle = String((base + suffix).prefix(20))
                attempt += 1
            } catch {
                // Operator down / RPC flake — fail silently. User keeps
                // the wallet, just no on-chain handle yet.
                return
            }
        }
    }

    private func candidateHandle() -> String {
        // Prefer first word of display name; fall back to the email local-part.
        // NEVER suggest from a hide-my-email relay address — Apple sign-in
        // users get `c7zh9mf9zz@privaterelay.appleid.com` shapes, and the
        // gibberish local-part autotyped into the field read as a bug (and
        // got CLAIMED on-chain by one tester). Empty is better than noise.
        let source: String = {
            let name = (user.name ?? "").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty,
               let first = name.split(separator: " ").first {
                return String(first)
            }
            if !user.email.lowercased().hasSuffix("@privaterelay.appleid.com"),
               let local = user.email.split(separator: "@").first {
                return String(local)
            }
            return ""
        }()
        // Normalize to what SuiNS accepts: [a-z0-9_] 3-20 chars.
        let normalized = source
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) }
            .map(String.init)
            .joined()
        return String(normalized.prefix(20))
    }
}
