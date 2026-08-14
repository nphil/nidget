import SwiftUI

// MARK: - HouseholdDebtSection
//
// The Debt face of the Household Plan: what is owed, what it costs, when it goes, and the two
// levers that change all three (the payoff order and the money going at it every month).
//
// Edits here write straight back into the scenario's `debtState` through `RetironProfileMapper`,
// which also refreshes the five mirror fields the yearly projection reads, so the Overview and
// the Years sections move the moment a balance changes. Adding and removing accounts stays in
// Retiron on purpose: this screen edits what is already there.
//
// The payoff chart is `HouseholdDebtChart`, over in HouseholdPlanCharts.swift with the others.

struct HouseholdDebtSection: View {
    let plan: HouseholdPlanResult
    let onEditAccounts: ([DebtAccount]) -> Void
    let onSetBudget: (Double) -> Void
    let onSetStrategy: (DebtStrategy) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expandedAccount: String?
    @State private var moneyEdit: MoneyEdit?
    /// The accounts as edited on this phone. The projection behind them is debounced (250 ms in
    /// `HouseholdPlanView.recompute`), so `plan.accounts` lags every edit; the rows read from here
    /// until it catches up, otherwise a held Stepper would keep adding its step to the same stale
    /// rate. Dropped the moment a fresh plan lands, so a scenario switch always wins.
    @State private var draftAccounts: [DebtAccount]?

    private var accounts: [DebtAccount] { draftAccounts ?? plan.accounts }

    /// One pending trip to the keypad. The closure is where the edited amount goes home to.
    private struct MoneyEdit: Identifiable {
        var id: String
        var title: String
        var caption: String
        var initial: Money
        var apply: (Money) -> Void
    }

    var body: some View {
        VStack(spacing: theme.layout.cardSpacing) {
            tilesCard
            leversCard
            if !warnings.isEmpty {
                warningsCard
            }
            if !plan.accounts.isEmpty {
                HouseholdDebtChart(plan: plan)
                accountsCard
            } else {
                emptyCard
            }
        }
        .sheet(item: $moneyEdit) { edit in
            HouseholdAmountSheet(title: edit.title, caption: edit.caption, initial: edit.initial) {
                edit.apply($0)
            }
            .presentationDetents([.height(520), .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: plan.accounts) { _, _ in draftAccounts = nil }
    }

    // MARK: Tiles

    private var tilesCard: some View {
        let totalNow = plan.accounts.reduce(0) { $0 + $1.balance }
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("Where The Debt Stands")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: theme.layout.spacing),
                                GridItem(.flexible(), spacing: theme.layout.spacing)],
                      spacing: theme.layout.spacing) {
                tile("Owed today", Money(clampedDollars: totalNow), caption: "across every account")
                tile("Interest to come", Money(clampedDollars: plan.debt.totalInterest),
                     caption: "if nothing changes")
                textTile("Clear in", payoffText, caption: payoffCaption)
                tile("Going at it", Money(clampedDollars: plan.monthlyDebtBudget),
                     caption: "every month")
            }
        }
        .themedCard()
    }

    private func tile(_ label: String, _ amount: Money, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            cardLabel(label)
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
            cardLabel(label)
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

    private var isEverCleared: Bool {
        plan.debt.payoffMonths < DebtSimulator.maxMonths - 1
    }

    private var payoffText: String {
        guard !plan.accounts.isEmpty else { return "Done" }
        guard isEverCleared else { return "Over 10 yr" }
        let months = plan.debt.payoffMonths
        if months < 24 { return "\(months) mo" }
        return "\(months / 12) yr \(months % 12) mo"
    }

    private var payoffCaption: String {
        guard !plan.accounts.isEmpty else { return "nothing left to pay" }
        guard isEverCleared, let last = plan.debt.schedule.last else {
            return "more money a month would fix it"
        }
        return last.date.formatted(.dateTime.month(.abbreviated).year())
    }

    // MARK: Levers

    private var strategyBinding: Binding<DebtStrategy> {
        Binding(get: { plan.strategy == .snowball ? .snowball : .avalanche },
                set: { onSetStrategy($0) })
    }

    private var leversCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("How You Pay It Off")
            ChipPicker(items: [DebtStrategy.avalanche, DebtStrategy.snowball],
                       selection: strategyBinding,
                       label: { Self.strategyLabel($0) })
            Text(Self.strategyExplainer(plan.strategy))
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(theme.palette.separator)
                .frame(height: 1)
            Button {
                moneyEdit = MoneyEdit(id: "budget",
                                      title: "Monthly Debt Payment",
                                      caption: "Everything you put towards cards and loans in a month.",
                                      initial: Money(clampedDollars: plan.monthlyDebtBudget)) { amount in
                    onSetBudget(max(0, amount.doubleValue))
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
    private var warnings: [String] {
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

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            cardLabel("Worth Knowing")
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
            cardLabel("Your Accounts")
            ForEach(accounts) { account in
                accountRow(account)
                if account.id != accounts.last?.id {
                    Rectangle()
                        .fill(theme.palette.separator)
                        .frame(height: 1)
                }
            }
            Text("Retiron is where accounts get added and removed. Here you keep the numbers honest.")
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

    /// A stepper rather than a slider on purpose: every nudge is one committed edit that goes to
    /// Retiron, and a dragged slider would be a hundred of them.
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

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No debt in this scenario")
                .font(theme.font(.headline))
                .foregroundStyle(theme.palette.textPrimary)
            Text("Nothing to pay off, which is the whole point. Add an account in Retiron if that changes.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    // MARK: Edits

    private func update(_ id: String, _ change: (inout DebtAccount) -> Void) {
        var edited = accounts
        guard let index = edited.firstIndex(where: { $0.id == id }) else { return }
        change(&edited[index])
        draftAccounts = edited
        onEditAccounts(edited)
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
            return "Retiron is holding an order of your own. Pick one of these two to change it."
        }
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }

    private static func percentText(_ value: Double) -> String {
        let safe = value.isFinite ? min(max(value, 0), 999) : 0
        return (safe / 100).formatted(.percent.precision(.fractionLength(0...2)))
    }
}
