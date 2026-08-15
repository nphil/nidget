import SwiftUI

// MARK: - DebtView
//
// "Debt", pushed via `Route.retireDebt`: what is owed, what it costs, when it goes, and the two
// levers that change all three (the payoff order and the money going at it every month).
//
// Edits flow through `HouseholdPlanModel`'s apply methods, which write into the scenario's
// `debtState` through `RetironProfileMapper` and refresh the mirror fields the yearly projection
// reads, so the glance and the Years screen move the moment a balance changes. Adding and
// removing accounts stays in Retiron on purpose: this screen edits what is already there.
//
// The payoff chart is `HouseholdDebtChart`, over in HouseholdPlanCharts.swift with the others.

struct DebtView: View {
    /// Optional on purpose: a force read traps if this destination is ever built outside the
    /// Retire tab's injected stack, so the model is unwrapped once and the screen shows a
    /// placeholder instead of crashing.
    @Environment(HouseholdPlanModel.self) private var household: HouseholdPlanModel?

    var body: some View {
        if let household {
            DebtContent(household: household)
        } else {
            RetirePlaceholderScreen(title: "Debt")
        }
    }
}

@MainActor
private struct DebtContent: View {
    let household: HouseholdPlanModel

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expandedAccount: String?
    @State private var moneyEdit: MoneyEdit?
    /// Debounces the trip to the model, so a held stepper is one save and not thirty.
    @State private var applyTask: Task<Void, Never>?
    /// The accounts as edited on this phone. The trip to the model is debounced in `update`, and
    /// the projection behind it is debounced again inside `HouseholdPlanModel`, so
    /// `plan.accounts` lags every edit; the rows read from here until it catches up, otherwise a
    /// held Stepper would keep adding its step to the same stale rate. Dropped the moment a
    /// fresh plan lands, so a scenario switch always wins.
    @State private var draftAccounts: [DebtAccount]?

    private var accounts: [DebtAccount] { draftAccounts ?? household.plan?.accounts ?? [] }

    /// One pending trip to the keypad. The closure is where the edited amount goes home to.
    private struct MoneyEdit: Identifiable {
        var id: String
        var title: String
        var caption: String
        var initial: Money
        var apply: (Money) -> Void
    }

    var body: some View {
        Group {
            if let plan = household.plan {
                planScroll(plan)
            } else {
                loadingView
            }
        }
        .themedScreen()
        .navigationTitle("Debt")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $moneyEdit) { edit in
            AmountEntrySheet(title: edit.title, caption: edit.caption, initial: edit.initial) {
                edit.apply($0)
            }
        }
        .onChange(of: household.plan?.accounts) { _, _ in draftAccounts = nil }
        .task(id: household.recomputeKey) {
            await household.recompute()
        }
    }

    private var loadingView: some View {
        VStack(spacing: theme.layout.spacing) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.palette.accent)
            Text("Working out the payoff…")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Layout

    private func planScroll(_ plan: HouseholdPlanResult) -> some View {
        ScrollView {
            VStack(spacing: theme.layout.cardSpacing) {
                tilesCard(plan)
                leversCard(plan)
                let promoWarnings = warnings(plan)
                if !promoWarnings.isEmpty {
                    warningsCard(promoWarnings)
                }
                if isDebtFree(plan) {
                    debtFreeCard(hasAccounts: !plan.accounts.isEmpty)
                    // Cleared cards still open for editing, so a balance can come back.
                    if !plan.accounts.isEmpty {
                        accountsCard
                    }
                } else {
                    HouseholdDebtChart(plan: plan)
                    accountsCard
                }
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Tiles

    private func tilesCard(_ plan: HouseholdPlanResult) -> some View {
        let totalNow = plan.accounts.reduce(0) { $0 + $1.balance }
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("Where the debt stands")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: theme.layout.spacing),
                                GridItem(.flexible(), spacing: theme.layout.spacing)],
                      spacing: theme.layout.spacing) {
                tile("Owed today", Money(clampedDollars: totalNow), caption: "across every account")
                tile("Interest to come", Money(clampedDollars: plan.debt.totalInterest),
                     caption: "if nothing changes")
                textTile("Clear in", payoffText(plan), caption: payoffCaption(plan))
                tile("Going at it", Money(clampedDollars: plan.monthlyDebtBudget),
                     caption: "every month")
            }
        }
        .themedCard()
    }

    private func tile(_ label: String, _ amount: Money, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(label)
            AmountText(amount, style: .title, colorized: false)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func textTile(_ label: String, _ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(label)
            Text(value)
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func isEverCleared(_ plan: HouseholdPlanResult) -> Bool {
        plan.debt.payoffMonths < DebtSimulator.maxMonths - 1
    }

    /// Nothing owed, which is not the same as no accounts: a cleared card stays in the list
    /// until it is removed in Retiron. The glance tile draws the line here too, so the two
    /// screens never disagree.
    private func isDebtFree(_ plan: HouseholdPlanResult) -> Bool {
        !plan.accounts.contains { $0.balance > 0 }
    }

    private func payoffText(_ plan: HouseholdPlanResult) -> String {
        guard !isDebtFree(plan) else { return "Done" }
        guard isEverCleared(plan) else { return "Over 10 yr" }
        let months = plan.debt.payoffMonths
        if months < 24 { return "\(months) mo" }
        return "\(months / 12) yr \(months % 12) mo"
    }

    private func payoffCaption(_ plan: HouseholdPlanResult) -> String {
        guard !isDebtFree(plan) else { return "nothing left to pay" }
        guard isEverCleared(plan), let last = plan.debt.schedule.last else {
            return "more money a month would fix it"
        }
        return last.date.formatted(.dateTime.month(.abbreviated).year())
    }

    // MARK: Levers

    /// Reports the order that is actually being simulated, including `.custom`. Collapsing it
    /// onto one of the two named orders would light up a chip that is not what the chart is
    /// running, and ChipPicker ignores a tap on the chip it already shows as selected.
    private var strategyBinding: Binding<DebtStrategy> {
        Binding(get: { [household] in
            household.plan?.strategy ?? .avalanche
        }, set: { [household] in
            household.applyStrategy($0)
        })
    }

    /// The order Retiron is holding only earns a chip while it is the one in use, and it drops
    /// out of the row the moment the user picks one of the two Nidget can set.
    private func strategyItems(_ plan: HouseholdPlanResult) -> [DebtStrategy] {
        plan.strategy == .custom ? [.avalanche, .snowball, .custom] : [.avalanche, .snowball]
    }

    private func leversCard(_ plan: HouseholdPlanResult) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("How you pay it off")
            ChipPicker(items: strategyItems(plan),
                       selection: strategyBinding,
                       label: { Self.strategyLabel($0) })
            Text(Self.strategyExplainer(plan.strategy))
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            separator
            Button {
                moneyEdit = MoneyEdit(id: "budget",
                                      title: "Monthly Debt Payment",
                                      caption: "Everything you put towards cards and loans in a month.",
                                      initial: Money(clampedDollars: plan.monthlyDebtBudget)) { amount in
                    household.applyDebtBudget(max(0, amount.doubleValue))
                }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Every month")
                            .font(theme.font(.body))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text("Minimums first, then the rest goes to the front of the queue.")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: theme.layout.spacing)
                    AmountText(Money(clampedDollars: plan.monthlyDebtBudget), style: .body,
                               colorized: false)
                    Image(systemName: "chevron.right")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the amount keypad")
        }
        .themedCard()
    }

    // MARK: Warnings

    /// Promo rates about to run out, in the order they run out.
    private func warnings(_ plan: HouseholdPlanResult) -> [String] {
        plan.accounts
            .filter { $0.promoEndMonth > 0 && $0.promoEndMonth <= 6 && $0.balance > 0 }
            .sorted { $0.promoEndMonth < $1.promoEndMonth }
            .map { account in
                let months = account.promoEndMonth
                let when = months == 1 ? "next month" : "in \(months) months"
                let rate = Self.percentText(account.postPromoAPRPct)
                return "\(account.name) leaves its intro rate \(when), and then it charges \(rate)."
            }
    }

    private func warningsCard(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            SectionHeader("Worth knowing")
            ForEach(warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: theme.layout.spacing * 0.75) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(theme.font(.body))
                        .symbolVariant(theme.icons.fill ? .fill : .none)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.palette.warning)
                        .accessibilityHidden(true)
                    Text(warning)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 32)
            }
        }
        .themedCard()
    }

    // MARK: Accounts

    private var accountsCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            SectionHeader("Your accounts")
            ForEach(accounts) { account in
                accountRow(account)
                if account.id != accounts.last?.id {
                    separator
                }
            }
            Text("Adding or removing accounts happens in Retiron.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    private func accountRow(_ account: DebtAccount) -> some View {
        let isOpen = expandedAccount == account.id
        return VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            Button {
                toggle(account.id)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name)
                            .font(theme.font(.body))
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(1)
                        Text("\(Self.percentText(account.aprPct)) rate")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                    Spacer(minLength: theme.layout.spacing)
                    AmountText(Money(clampedDollars: account.balance), style: .body, colorized: false)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                editorRows(account)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: isOpen)
    }

    @ViewBuilder
    private func editorRows(_ account: DebtAccount) -> some View {
        VStack(spacing: theme.layout.spacing * 0.5) {
            amountEditRow("Balance", Money(clampedDollars: account.balance)) {
                moneyEdit = MoneyEdit(id: "balance-\(account.id)",
                                      title: "\(account.name) Balance",
                                      caption: "What is owed on it right now.",
                                      initial: Money(clampedDollars: account.balance)) { amount in
                    update(account.id) { $0.balance = max(0, amount.doubleValue) }
                }
            }
            rateStepper(account)
            amountEditRow("Smallest payment", Money(clampedDollars: account.minPay)) {
                moneyEdit = MoneyEdit(id: "min-\(account.id)",
                                      title: "\(account.name) Minimum",
                                      caption: "The least you have to pay each month.",
                                      initial: Money(clampedDollars: account.minPay)) { amount in
                    update(account.id) { $0.minPay = max(0, amount.doubleValue) }
                }
            }
        }
    }

    private func amountEditRow(_ label: String, _ amount: Money,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer(minLength: theme.layout.spacing)
                AmountText(amount, style: .body, colorized: false)
                Image(systemName: "chevron.right")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the amount keypad")
    }

    /// A stepper rather than a slider on purpose: a nudge is a deliberate edit that goes to
    /// Retiron, and a dragged slider would be a hundred of them. A held stepper still fires
    /// fast, so `update` debounces the commit behind it.
    private func rateStepper(_ account: DebtAccount) -> some View {
        Stepper(value: rateBinding(account), in: 0...40, step: 0.25) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rate")
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer(minLength: theme.layout.spacing)
                Text(Self.percentText(account.aprPct))
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: account.aprPct)
            }
        }
        .tint(theme.palette.accent)
        .frame(minHeight: 44)
    }

    private func rateBinding(_ account: DebtAccount) -> Binding<Double> {
        Binding(get: { accounts.first(where: { $0.id == account.id })?.aprPct ?? account.aprPct },
                set: { newValue in
                    Haptics.tick()
                    update(account.id) { $0.aprPct = max(0, newValue) }
                })
    }

    private func debtFreeCard(hasAccounts: Bool) -> some View {
        EmptyStateView(systemImage: "checkmark.circle",
                       title: "All clear",
                       message: hasAccounts
                           ? "Every account is down to zero, so there is nothing left to pay down."
                           : "Nothing left to pay down. Adding or removing accounts happens in Retiron.")
            .themedCard()
    }

    // MARK: Edits

    /// The rows move at once off `draftAccounts`, and the model hears about it once the finger
    /// stops. A held rate stepper fires about ten times a second, and every one of those was a
    /// whole profile encoded and written to disk.
    private func update(_ id: String, _ change: (inout DebtAccount) -> Void) {
        var edited = accounts
        guard let index = edited.firstIndex(where: { $0.id == id }) else { return }
        change(&edited[index])
        draftAccounts = edited
        applyTask?.cancel()
        applyTask = Task { [household, edited] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            household.applyAccounts(edited)
        }
    }

    private func toggle(_ id: String) {
        Haptics.tick()
        let apply = { expandedAccount = (expandedAccount == id) ? nil : id }
        if reduceMotion {
            apply()
        } else {
            withAnimation(theme.motion.snappy) { apply() }
        }
    }

    // MARK: Helpers

    private var separator: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }

    private static func strategyLabel(_ strategy: DebtStrategy) -> String {
        switch strategy {
        case .avalanche: return "Priciest first"
        case .snowball: return "Smallest first"
        case .custom: return "Your order"
        }
    }

    private static func strategyExplainer(_ strategy: DebtStrategy) -> String {
        switch strategy {
        case .avalanche:
            return "Spare money goes at the highest rate first. It costs the least in the end."
        case .snowball:
            return "Spare money clears the smallest balance first. It costs a little more, and it feels like progress sooner."
        case .custom:
            return "Retiron is holding an order of your own. Pick priciest first or smallest first to change it."
        }
    }

    private static func percentText(_ value: Double) -> String {
        let safe = value.isFinite ? min(max(value, 0), 999) : 0
        return (safe / 100).formatted(.percent.precision(.fractionLength(0...2)))
    }
}
