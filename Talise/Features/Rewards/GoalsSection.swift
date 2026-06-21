import SwiftUI

/// Phase 3 — Savings Goals.
///
/// Horizontal carousel of named savings buckets ("Laptop fund",
/// "Wedding 2026") plus a dashed "+ New goal" tile at the end. Tap a
/// card to open an action sheet: deposit, edit, or archive.
///
/// v1 reality: a "deposit" here is a TRACKING entry, not an actual
/// on-chain segregation — the dollars sit alongside the user's main
/// NAVI position. The deposit endpoint just bumps `current_usd` and
/// mints a `goal_deposit` rewards_event (4 pts/$1 via the canonical
/// earn engine). Future: per-goal NAVI sub-positions.
///
/// Owns its own data lifecycle — pull-to-refresh on the parent Rewards
/// view does NOT call into here; we reload via `.task` + after every
/// mutation. The Insights section is independent for the same reason.
struct GoalsSection: View {
    @State private var goals: [SavingsGoal] = []
    @State private var loading = true
    @State private var error: String?

    @State private var selected: SavingsGoal?
    @State private var showingNewGoal = false

    /// Goals still being saved toward (shown in the main row).
    private var activeGoals: [SavingsGoal] { goals.filter { !$0.isComplete } }
    /// Goals that hit their target — moved out of the active row into the
    /// "Completed" section below.
    private var completedGoals: [SavingsGoal] { goals.filter { $0.isComplete } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Savings goals")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    if loading && goals.isEmpty {
                        GoalCardSkeleton()
                        GoalCardSkeleton()
                    } else {
                        ForEach(activeGoals) { goal in
                            GoalCard(goal: goal)
                                .onTapGesture { selected = goal }
                        }
                    }
                    NewGoalTile()
                        .onTapGesture { showingNewGoal = true }
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 148)

            // Completed goals leave the active row and live here.
            if !completedGoals.isEmpty {
                SectionHeader("Completed")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(completedGoals) { goal in
                            GoalCard(goal: goal)
                                .opacity(0.7)
                                .onTapGesture { selected = goal }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 148)
            }

            if let error, !error.isEmpty {
                Text(error)
                    .font(TaliseFont.mono(10, weight: .light))
                    .foregroundStyle(TaliseColor.danger)
                    .padding(.horizontal, 4)
            }
        }
        .task { await load() }
        .sheet(item: $selected, onDismiss: { Task { await load() } }) { g in
            GoalActionSheet(goal: g) { Task { await load() } }
        }
        .fullScreenCover(isPresented: $showingNewGoal, onDismiss: { Task { await load() } }) {
            NewGoalScreen()
        }
    }

    // MARK: - Data

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let resp: SavingsGoalsResponse = try await APIClient.shared.get("/api/rewards/goals")
            goals = resp.goals
            error = nil
        } catch {
            if !APIError.isCancellation(error) {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Goal card

private struct GoalCard: View {
    let goal: SavingsGoal

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(goal.name)
                        .font(TaliseFont.heading(15, weight: .medium))
                        .foregroundStyle(TaliseColor.fg)
                        .lineLimit(1)
                    if let label = goal.deadlineLabel {
                        Text(label)
                            .font(TaliseFont.mono(10, weight: .regular))
                            .kerning(-0.32)
                            .foregroundStyle(TaliseColor.fgDim)
                    }
                }
                Spacer()
                ProgressRing(progress: goal.progress)
                    .frame(width: 36, height: 36)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(TaliseFormat.local2(goal.currentUsd))
                    .font(TaliseFont.heading(18, weight: .medium))
                    .kerning(-0.5)
                    .foregroundStyle(TaliseColor.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("of \(TaliseFormat.local2(goal.targetUsd))")
                    .font(TaliseFont.mono(10, weight: .regular))
                    .kerning(-0.32)
                    .foregroundStyle(TaliseColor.fgDim)
                    .lineLimit(1)
            }
        }
        .padding(18)
        .frame(width: 168, height: 148, alignment: .topLeading)
        .earnHeroGlass(cornerRadius: 20)
    }
}

/// Goal progress ring — honest math, no fake floor. An empty goal reads
/// empty (mirrors `QuietProgressBar`'s clamp with no minimum).
private struct ProgressRing: View {
    let progress: Double

    private var clamped: CGFloat { CGFloat(min(max(progress, 0), 1)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 4)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(TaliseColor.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(clamped * 100))%")
                .font(TaliseFont.mono(9, weight: .regular))
                .foregroundStyle(TaliseColor.accent)
        }
    }
}

/// Loading placeholder shaped exactly like a `GoalCard` (A.8) — a badge
/// disc + two capsule bars, redacted. Honors the section's `loading`.
private struct GoalCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Capsule().fill(TaliseColor.line).frame(width: 80, height: 10)
                Spacer()
                Circle().fill(TaliseColor.surface2).frame(width: 36, height: 36)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(TaliseColor.line).frame(width: 70, height: 12)
                Capsule().fill(TaliseColor.line).frame(width: 50, height: 8)
            }
        }
        .padding(18)
        .frame(width: 168, height: 148, alignment: .topLeading)
        .earnHeroGlass(cornerRadius: 20)
        .redacted(reason: .placeholder)
        .opacity(0.6)
    }
}

private struct NewGoalTile: View {
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(TaliseColor.surface2)
                    .frame(width: 36, height: 36)
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TaliseColor.accent)
            }
            Text("New goal")
                .font(TaliseFont.heading(13, weight: .medium))
                .foregroundStyle(TaliseColor.fg)
            Text("Name a bucket")
                .font(TaliseFont.mono(10, weight: .regular))
                .kerning(-0.32)
                .foregroundStyle(TaliseColor.fgDim)
                .multilineTextAlignment(.center)
        }
        .frame(width: 168, height: 148)
        .background(TaliseColor.bg)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    TaliseColor.accent.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Action sheet (deposit / edit / archive)

private struct GoalActionSheet: View {
    let goal: SavingsGoal
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var depositText: String = ""
    @State private var busy = false
    @State private var error: String?
    @State private var lastPointsAwarded: Int?
    /// Non-nil after a successful deposit → shows the full-screen success
    /// cover (and, by replacing the form, prevents an accidental re-tap that
    /// would stack a second deposit). Holds the pre-formatted amount added.
    @State private var depositDone: String?
    /// Non-nil after a successful withdrawal → shows the same target success
    /// cover with the "withdrawn" copy. Holds the pre-formatted amount.
    @State private var withdrawDone: String?
    /// Mirrors `goal.yieldOn` for the earn switch; flipped optimistically on
    /// tap and reverted if the on-chain op fails.
    @State private var earnOn = false
    /// Add vs Withdraw, chosen by the segmented toggle.
    @State private var mode: Mode = .add
    private enum Mode { case add, withdraw }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    summary
                    deposit
                    if goal.vaultObjectId != nil { earnToggle }
                    archive
                    if let error {
                        Text(error)
                            .font(TaliseFont.body(12, weight: .light))
                            .foregroundStyle(TaliseColor.danger)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .taliseScreenBackground()
            .navigationTitle(goal.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(TaliseColor.accent)
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { depositDone != nil },
                set: { if !$0 { depositDone = nil } }
            )) {
                GoalSuccessView(
                    amountText: depositDone ?? "",
                    goalName: goal.name,
                    // Back to Invest: clear the cover, then close the sheet so
                    // the user lands back on the Invest screen.
                    onDismiss: { depositDone = nil; dismiss() }
                )
            }
            .fullScreenCover(isPresented: Binding(
                get: { withdrawDone != nil },
                set: { if !$0 { withdrawDone = nil } }
            )) {
                GoalSuccessView(
                    kind: .withdraw,
                    amountText: withdrawDone ?? "",
                    goalName: goal.name,
                    onDismiss: { withdrawDone = nil; dismiss() }
                )
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeroAmount(
                eyebrow: "Saved so far",
                value: TaliseFormat.local2(goal.currentUsd),
                caption: "of \(TaliseFormat.local2(goal.targetUsd)) target",
                captionAccent: false
            )
            QuietProgressBar(progress: goal.progress)
            if let pts = lastPointsAwarded, pts > 0 {
                Text("+\(pts) points earned")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.accent)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .earnHeroGlass(cornerRadius: 24)
    }

    private var deposit: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(mode == .add ? "Add to goal" : "Withdraw from goal")
            VStack(alignment: .leading, spacing: 14) {
                // Add / Withdraw segmented toggle — pick the action, one field below.
                HStack(spacing: 4) {
                    modeTab("Add money", .add)
                    modeTab("Withdraw", .withdraw)
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(TaliseColor.fg.opacity(0.06))
                )

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(CurrencySettings.shared.current.symbol)
                        .font(TaliseFont.heading(28, weight: .medium))
                        .foregroundStyle(TaliseColor.fgDim)
                    TextField("0.00", text: $depositText)
                        .keyboardType(.decimalPad)
                        .font(TaliseFont.heading(28, weight: .medium))
                        .kerning(-0.8)
                        .tint(TaliseColor.accent)
                        .foregroundStyle(TaliseColor.fg)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .earnFieldGlass()

                Text(mode == .add
                     ? "Tracking only — funds stay in your earning balance and keep earning points + yield."
                     : "Moves tracked savings back to your spendable balance.")
                    .font(TaliseFont.body(13, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)

                LiquidGlassButton(
                    title: actionTitle,
                    tint: TaliseColor.accent,
                    size: .lg,
                    loading: busy
                ) {
                    Task { mode == .add ? await runDeposit() : await runWithdraw() }
                }
                .disabled(busy || !canDeposit)
            }
            .padding(20)
            .earnHeroGlass(cornerRadius: 20)
        }
    }

    private var actionTitle: String {
        if busy { return mode == .add ? "Adding…" : "Withdrawing…" }
        return mode == .add ? "Add to goal" : "Withdraw"
    }

    @ViewBuilder
    private func modeTab(_ title: String, _ m: Mode) -> some View {
        Button { mode = m } label: {
            Text(title)
                .font(TaliseFont.body(15, weight: .medium))
                .foregroundStyle(mode == m ? Color.black.opacity(0.85) : TaliseColor.fgMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(mode == m ? TaliseColor.accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    /// Earn / stop-earning toggle. When on, the goal's balance is supplied to
    /// NAVI (under an AccountCap parked in its vault) and earns yield; off keeps
    /// it idle in the vault. Only shown for vault-backed goals.
    private var earnToggle: some View {
        HStack(spacing: 10) {
            Image(systemName: earnOn ? "leaf.fill" : "leaf")
                .foregroundStyle(earnOn ? TaliseColor.accent : TaliseColor.fgDim)
            VStack(alignment: .leading, spacing: 2) {
                Text(earnOn ? "Earning yield" : "Earn yield on this goal")
                    .font(TaliseFont.body(15, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
                Text("Your savings grow · withdraw anytime")
                    .font(TaliseFont.body(12, weight: .light))
                    .foregroundStyle(TaliseColor.fgDim)
            }
            Spacer()
            if busy {
                ProgressView()
            } else {
                // Real switch. The set closure drives the on-chain op; on
                // failure runToggleYield reverts `earnOn` so the switch snaps
                // back to the true state.
                Toggle("", isOn: Binding(
                    get: { earnOn },
                    set: { want in
                        guard want != earnOn else { return }
                        earnOn = want
                        Task { await runToggleYield(start: want) }
                    }
                ))
                .labelsHidden()
                .tint(TaliseColor.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .earnHeroGlass(cornerRadius: 16)
        .disabled(busy || goal.currentUsd <= 0)
        .onAppear { earnOn = goal.yieldOn == true }
    }

    /// Start or stop earning on the whole goal balance. start=true → yield-start
    /// (move vault principal into NAVI); start=false → yield-withdraw (redeem the
    /// full position back to the vault). Confirms server-side after the tx lands.
    private func runToggleYield(start: Bool) async {
        busy = true
        defer { busy = false }
        let op = start ? "yield-start" : "yield-withdraw"
        let amountUsd = goal.currentUsd
        guard amountUsd > 0 else { earnOn = !start; return }
        do {
            self.error = nil
            let sub = try await ZkLoginCoordinator.shared.signAndSubmitGoalVault(
                op: op, goalId: goal.id, amountUsd: amountUsd
            )
            // Best-effort tracker sync. The on-chain tx already succeeded (we
            // hold a digest) → a confirm failure (index race, proxy hiccup, or a
            // response-decode quirk) must NOT report the action as failed. The
            // list reload (onChanged) reflects the real, server-synced state.
            let _: GoalVaultConfirmResponse? = try? await APIClient.shared.post(
                "/api/goals/vault/confirm",
                body: GoalVaultConfirmBody(
                    goalId: goal.id, op: op, amountUsd: amountUsd, digest: sub.digest
                )
            )
            // Stay on the sheet; reflect the new earning state + refresh the list.
            earnOn = start
            onChanged()
        } catch ZkLoginCoordinator.CoordinatorError.structured(_, let code, _)
            where code == "GOAL_YIELD_DISABLED" || code == "GOAL_VAULT_DISABLED"
               || code == "HTTP_404" || code == "HTTP_503" {
            earnOn = !start  // revert the switch — yield rail unavailable
            self.error = "Earning is rolling out — check back soon."
        } catch {
            earnOn = !start  // revert the switch — the op failed, nothing moved
            self.error = friendlyGoalError(error)
        }
    }

    private var archive: some View {
        Button {
            Task { await runArchive() }
        } label: {
            Text("Archive goal")
                .font(TaliseFont.body(13, weight: .light))
                .foregroundStyle(TaliseColor.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var canDeposit: Bool {
        let cleaned = depositText.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(cleaned) else { return false }
        return v > 0
    }

    private func runDeposit() async {
        let cleaned = depositText.replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(cleaned), amount > 0 else { return }
        busy = true
        defer { busy = false }
        // The user types in their display currency (₦, £, …); the goal ledger
        // settles in USD. Convert before sending — same path as EarnView.
        let amountUsd = CurrencySettings.shared.convertToUsd(local: amount)
        do {
            // ON-CHAIN VAULT RAIL — moves REAL USDsui into the goal's segregated
            // GoalVault. The FIRST deposit `create`s + funds the vault; later
            // ones `deposit` into it. We confirm server-side (records the vault
            // id + syncs the display tracker) only after the tx lands.
            do {
                let op = goal.vaultObjectId == nil ? "create" : "deposit"
                let sub = try await ZkLoginCoordinator.shared.signAndSubmitGoalVault(
                    op: op,
                    goalId: goal.id,
                    amountUsd: amountUsd,
                    name: op == "create" ? goal.name : nil,
                    targetUsd: op == "create" ? goal.targetUsd : nil
                )
                // Best-effort tracker sync — the on-chain tx already succeeded
                // (we hold a digest), so a confirm failure must NOT report the
                // action as failed. onChanged() reloads the real server state.
                let _: GoalVaultConfirmResponse? = try? await APIClient.shared.post(
                    "/api/goals/vault/confirm",
                    body: GoalVaultConfirmBody(
                        goalId: goal.id, op: op, amountUsd: amountUsd, digest: sub.digest
                    )
                )
            } catch ZkLoginCoordinator.CoordinatorError.structured(_, let code, _)
                where code == "GOAL_VAULT_DISABLED" || code == "HTTP_404" {
                // Vault rail unavailable here (disabled, or the endpoint isn't
                // deployed to this API) → DB tracking model.
                let resp: SavingsGoalMutationResponse = try await APIClient.shared.post(
                    "/api/rewards/goals/\(goal.id)",
                    body: GoalDepositRequest(amountUsd: amountUsd)
                )
                lastPointsAwarded = resp.pointsAwarded
            }
            depositText = ""
            onChanged()
            // Show the success cover (and stop the form from being re-tapped,
            // which was stacking duplicate deposits). Amount in the display ccy.
            depositDone = TaliseFormat.local2(amountUsd)
        } catch {
            self.error = friendlyGoalError(error)
        }
    }

    /// Withdraw the typed amount back out of the goal. On-chain vault rail pulls
    /// REAL USDsui from the goal's GoalVault back to the user's wallet; falls
    /// back to the DB tracking model when the vault rail is off or the goal
    /// predates on-chain backing. Dismisses so the refreshed list reflects it.
    private func runWithdraw() async {
        let cleaned = depositText.replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(cleaned), amount > 0 else { return }
        busy = true
        defer { busy = false }
        let amountUsd = CurrencySettings.shared.convertToUsd(local: amount)
        do {
            do {
                let sub = try await ZkLoginCoordinator.shared.signAndSubmitGoalVault(
                    op: "withdraw",
                    goalId: goal.id,
                    amountUsd: amountUsd
                )
                // Best-effort tracker sync — the on-chain tx already succeeded
                // (we hold a digest), so a confirm failure must NOT report the
                // action as failed. onChanged() reloads the real server state.
                let _: GoalVaultConfirmResponse? = try? await APIClient.shared.post(
                    "/api/goals/vault/confirm",
                    body: GoalVaultConfirmBody(
                        goalId: goal.id, op: "withdraw", amountUsd: amountUsd, digest: sub.digest
                    )
                )
            } catch ZkLoginCoordinator.CoordinatorError.structured(_, let code, _)
                where code == "GOAL_VAULT_DISABLED" || code == "GOAL_NOT_ON_CHAIN"
                   || code == "HTTP_404" {
                // Vault off, endpoint not deployed here, or goal predates
                // on-chain backing → tracking model.
                let _: SavingsGoalMutationResponse = try await APIClient.shared.post(
                    "/api/rewards/goals/\(goal.id)",
                    body: GoalDepositRequest(amountUsd: amountUsd, action: "withdraw")
                )
            }
            depositText = ""
            onChanged()
            // Show the target success cover with the "withdrawn" copy (same
            // design as a deposit), instead of silently dismissing.
            withdrawDone = TaliseFormat.local2(amountUsd)
        } catch {
            self.error = friendlyGoalError(error)
        }
    }

    /// Clean, user-facing copy for a goal action failure — never the raw
    /// "Couldn't read response: {…}" / decode dump. Real server messages
    /// (e.g. a limit or balance error) still pass through.
    private func friendlyGoalError(_ error: Error) -> String {
        let raw = error.localizedDescription
        if raw.localizedCaseInsensitiveContains("couldn't read")
            || raw.localizedCaseInsensitiveContains("decode")
            || raw.contains("{") {
            return "Couldn't complete that just now — please try again."
        }
        return raw
    }


    private func runArchive() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await GoalsAPI.patch(
                id: goal.id,
                body: SavingsGoalUpdateRequest(
                    name: nil,
                    targetUsd: nil,
                    deadlineMs: nil,
                    color: nil,
                    archive: true
                )
            )
            onChanged()
            dismiss()
        } catch {
            self.error = friendlyGoalError(error)
        }
    }
}

// MARK: - New goal screen (full page)

/// Full-screen "New savings goal" page — presented via `.fullScreenCover`
/// so it owns the whole screen (not a half-height sheet). Custom header +
/// a centered hero, the two fields, and a pinned primary action so the
/// page reads as deliberate top-to-bottom instead of a sparse card.
private struct NewGoalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    @State private var name = ""
    @State private var targetText = ""
    @State private var busy = false
    @State private var error: String?

    private enum Field { case name, target }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {
                    hero
                    fields
                    Text("Tracking only — your money stays in your earning balance and keeps earning yield + points toward the target.")
                        .font(TaliseFont.body(12, weight: .light))
                        .foregroundStyle(TaliseColor.fgDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                    if let error {
                        Text(error)
                            .font(TaliseFont.body(12, weight: .light))
                            .foregroundStyle(TaliseColor.danger)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 28)
            }

            Spacer(minLength: 0)

            LiquidGlassButton(
                title: busy ? "Creating…" : "Create goal",
                tint: TaliseColor.accent,
                size: .lg,
                loading: busy
            ) {
                Task { await create() }
            }
            .disabled(busy || !canCreate)
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .taliseScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focus = .name }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .frame(width: 38, height: 38)
                    .glassCircle()
            }
            Spacer()
            MicroLabel(text: "New goal", color: TaliseColor.fgMuted).kerning(2.0)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(TaliseColor.accent.opacity(0.14))
                    .frame(width: 68, height: 68)
                Image(systemName: "flag.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(TaliseColor.accent)
            }
            VStack(spacing: 6) {
                Text("Name a savings bucket")
                    .font(TaliseFont.heading(22, weight: .medium))
                    .kerning(-0.6)
                    .foregroundStyle(TaliseColor.fg)
                Text("Set a target and watch it fill up.")
                    .font(TaliseFont.body(14, weight: .light))
                    .foregroundStyle(TaliseColor.fgMuted)
            }
            .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Goal name (e.g. Laptop fund)", text: $name)
                .font(TaliseFont.body(15, weight: .light))
                .kerning(-0.48)
                .tint(TaliseColor.accent)
                .foregroundStyle(TaliseColor.fg)
                .focused($focus, equals: .name)
                .submitLabel(.next)
                .onSubmit { focus = .target }
                .padding(16)
                .earnFieldGlass()
            TextField("Target amount (USD)", text: $targetText)
                .keyboardType(.decimalPad)
                .font(TaliseFont.body(15, weight: .light))
                .kerning(-0.48)
                .tint(TaliseColor.accent)
                .foregroundStyle(TaliseColor.fg)
                .focused($focus, equals: .target)
                .padding(16)
                .earnFieldGlass()
        }
        .padding(20)
        .earnHeroGlass(cornerRadius: 22)
    }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let cleaned = targetText.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(cleaned), v > 0 else { return false }
        return true
    }

    private func create() async {
        let cleaned = targetText.replacingOccurrences(of: ",", with: ".")
        guard let target = Double(cleaned), target > 0 else { return }
        busy = true
        defer { busy = false }
        do {
            let _: SavingsGoalMutationResponse = try await APIClient.shared.post(
                "/api/rewards/goals",
                body: SavingsGoalCreateRequest(
                    name: name,
                    targetUsd: target,
                    deadlineMs: nil,
                    color: nil
                )
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - PATCH helper
//
// `APIClient` only exposes GET + POST. The PATCH endpoint for goals
// (update / archive) is reached via a thin inline wrapper that reuses
// the auth header SecureSessionStore writes for every other call.
// Kept here (not in APIClient) so the Phase 3 scope stays narrow —
// no shared-network changes.
private enum GoalsAPI {
    @MainActor
    static func patch<B: Encodable>(id: String, body: B) async throws -> SavingsGoalMutationResponse {
        // Defensive: goal ids are server-generated, but never force-unwrap
        // a URL built from interpolated data — a malformed id should error,
        // not crash.
        guard let url = URL(string: AppConfig.shared.apiBaseURL + "/api/rewards/goals/\(id)") else {
            throw APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.httpBody = try JSONEncoder().encode(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = SecureSessionStore.shared.read() {
            req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if !(200...299).contains(http.statusCode) {
            throw APIError.status(http.statusCode, message: String(data: data, encoding: .utf8))
        }
        return try JSONDecoder().decode(SavingsGoalMutationResponse.self, from: data)
    }
}
