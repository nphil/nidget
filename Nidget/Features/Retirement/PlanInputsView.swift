import SwiftUI

// MARK: - PlanInputsView
//
// The one editor behind the gear, pushed via `Route.planInputs`. One scroll, two tiers: the
// "You" section edits a local RetirementConfig draft that stays on this phone, and the
// "Household" section (rendered only when Retiron is connected and a scenario is in hand)
// edits a HouseholdPlanConfig draft seeded from the mapper. Cancel discards both drafts; Save
// applies whichever changed: the local draft encodes to `Preferences.retirementConfigJSON`,
// the household draft goes through `HouseholdPlanModel.applyConfig`, which updates the cache
// synchronously and pushes to Retiron on the model's debounce.
//
// The household rows are built from a table rather than written out one by one, so adding a
// field is one line in `groups` and nothing else. Every field in that table maps to a real
// Retiron input (see `RetironProfileMapper`); the config fields Retiron has no home for (the
// ages, the horizon, the tax table, the contribution caps) are deliberately absent, because
// editing them here would look like it saved and then quietly reset on the next fetch.

@MainActor
struct PlanInputsView: View {
    @Environment(AppStore.self) private var store
    @Environment(Preferences.self) private var preferences
    /// Optional on purpose: a force read traps if this editor is ever built outside the Retire
    /// tab's injected stack. The "You" tier does not need the model at all, so a missing one
    /// simply hides the Household section instead of blanking the screen.
    @Environment(HouseholdPlanModel.self) private var household: HouseholdPlanModel?
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The local draft. Nothing persists until Save.
    @State private var config: RetirementConfig
    /// Last non-nil spending override, so toggling "Derive from budget" off restores it.
    @State private var rememberedOverride: Money?
    /// Last-12-months outflow, loaded async for the derive-toggle caption and override seed.
    @State private var derivedAnnualSpending: Money?
    /// Monthly contribution detected from transfers into the linked accounts; nil = none found.
    @State private var detectedContribution: Money?

    /// The household draft, seeded once the model's profile is in hand; nil hides the section.
    @State private var householdDraft: HouseholdPlanConfig?
    /// What the household draft was seeded as, so Save only commits a real change.
    @State private var householdSeed: HouseholdPlanConfig?

    @State private var moneyEdit: MoneyEdit?

    init() {
        let decoded = RetirementConfigCodec.decode(Preferences.shared.retirementConfigJSON)
        _config = State(initialValue: decoded)
        _rememberedOverride = State(initialValue: decoded.annualSpendingOverride)
    }

    // MARK: Money edits

    private enum LocalMoneyField: String {
        case extraAssets, monthlyContribution, annualSpending

        var title: String {
            switch self {
            case .extraAssets: return "Outside Assets"
            case .monthlyContribution: return "Monthly Contribution"
            case .annualSpending: return "Annual Spending"
            }
        }

        var caption: String {
            switch self {
            case .extraAssets: return "Investments not tracked in Actual."
            case .monthlyContribution: return "What you add to investments each month."
            case .annualSpending: return "What a year of retirement costs."
            }
        }
    }

    /// One pending trip to the keypad, local or household, identified by the field it edits.
    /// Field titles are unique across both tiers, so the title is the identity.
    private struct MoneyEdit: Identifiable {
        enum Target {
            case local(LocalMoneyField)
            case household(WritableKeyPath<HouseholdPlanConfig, Double>)
        }

        var title: String
        var caption: String
        var target: Target
        var id: String { title }
    }

    // MARK: Household field table

    /// One editable household row. `kind` carries the writable key path, so the row and the
    /// value never drift apart.
    private struct Field: Identifiable {
        enum Kind {
            case money(WritableKeyPath<HouseholdPlanConfig, Double>)
            case percent(WritableKeyPath<HouseholdPlanConfig, Double>, ClosedRange<Double>, Double)
            case count(WritableKeyPath<HouseholdPlanConfig, Int>, ClosedRange<Int>)
            case flag(WritableKeyPath<HouseholdPlanConfig, Bool>)
        }

        var title: String
        var caption: String?
        var kind: Kind
        var id: String { title }
    }

    private struct FieldGroup: Identifiable {
        var title: String
        var fields: [Field]
        var id: String { title }
    }

    /// Falls back the getters of household bindings during the one frame a row could outlive
    /// its draft; never user-visible.
    private static let fallbackHousehold = HouseholdPlanConfig()

    private func groups(for draft: HouseholdPlanConfig) -> [FieldGroup] {
        let nameA = draft.personA.name
        let nameB = draft.personB.name
        return [
            FieldGroup(title: "\(nameA) Today", fields: [
                Field(title: "Salary", caption: nil, kind: .money(\.personA.baseSalary)),
                Field(title: "Bonus", caption: "share of salary", kind: .percent(\.personA.bonusPct, 0...60, 0.5)),
                Field(title: "Stock", caption: "granted each year, before withholding", kind: .percent(\.personA.rsuPct, 0...60, 0.5)),
                Field(title: "Into the 401k", caption: nil, kind: .percent(\.personA.k401Pct, 0...30, 0.5)),
                Field(title: "Employer match", caption: nil, kind: .percent(\.personA.matchPct, 0...15, 0.5)),
                Field(title: "401k balance", caption: nil, kind: .money(\.personA.retirementBalance)),
                Field(title: "Roth balance", caption: nil, kind: .money(\.rothBalance)),
                Field(title: "HSA balance", caption: nil, kind: .money(\.hsaBalance)),
                Field(title: "Cash on hand", caption: "seeds the down payment pot", kind: .money(\.liquidCash)),
                Field(title: "Paying into the HSA again", caption: nil, kind: .flag(\.hsaRestart)),
                Field(title: "HSA restarts in", caption: "years from now", kind: .count(\.hsaStartYear, 0...25)),
                Field(title: "HSA each year", caption: nil, kind: .money(\.hsaAnnualContribution)),
            ]),
            FieldGroup(title: "\(nameA)'s Career", fields: [
                Field(title: "Yearly raise until the promotion", caption: nil, kind: .percent(\.colRaisePct, 0...10, 0.25)),
                Field(title: "Promotion in", caption: "years from now", kind: .count(\.promoInYears, 0...25)),
                Field(title: "Salary after it", caption: nil, kind: .money(\.promoBaseSalary)),
                Field(title: "Bonus after it", caption: nil, kind: .percent(\.promoBonusPct, 0...60, 0.5)),
                Field(title: "Stock after it", caption: nil, kind: .percent(\.promoRSUPct, 0...60, 0.5)),
                Field(title: "Raise after it", caption: "every year", kind: .percent(\.promoAnnualRaisePct, 0...10, 0.25)),
            ]),
            FieldGroup(title: nameB, fields: [
                Field(title: "Salary now", caption: nil, kind: .money(\.personB.baseSalary)),
                Field(title: "As high as it goes", caption: "part time ceiling", kind: .money(\.personBSalaryCap)),
                Field(title: "Into retirement", caption: nil, kind: .percent(\.personB.k401Pct, 0...30, 0.5)),
                Field(title: "Retirement balance", caption: nil, kind: .money(\.personB.retirementBalance)),
                Field(title: "Going full time", caption: nil, kind: .flag(\.personBFullTime)),
                Field(title: "Full time in", caption: "years from now", kind: .count(\.personBFullTimeYear, 0...25)),
                Field(title: "Full time salary", caption: nil, kind: .money(\.personBFullTimeSalary)),
                Field(title: "Full time ceiling", caption: nil, kind: .money(\.personBFullTimeCap)),
            ]),
            FieldGroup(title: "Goals And Rates", fields: [
                Field(title: "A year of living", caption: "what you want to spend, in today's money", kind: .money(\.annualSpend)),
                Field(title: "Investments grow", caption: "every year", kind: .percent(\.investmentReturnPct, 0...15, 0.25)),
                Field(title: "Inflation", caption: nil, kind: .percent(\.inflationPct, 0...10, 0.25)),
            ]),
            FieldGroup(title: HouseholdCopy.homeCity, fields: [
                Field(title: "What it is worth", caption: nil, kind: .money(\.atlValue)),
                Field(title: "Left on the mortgage", caption: nil, kind: .money(\.atlMortgage)),
                Field(title: "Mortgage payment", caption: "a month, with taxes", kind: .money(\.atlMortgagePaymentMonthly)),
                Field(title: "It gains", caption: "every year", kind: .percent(\.atlAppreciationPct, 0...12, 0.25)),
                Field(title: "Property tax rises in", caption: "years from now", kind: .count(\.atlTaxBumpYear, 0...25)),
                Field(title: "And rises by", caption: "a month", kind: .money(\.atlTaxBumpMonthly)),
                Field(title: "Rent in the first year", caption: "a month", kind: .money(\.atlRentYear1Monthly)),
                Field(title: "Rent rises", caption: "every year", kind: .percent(\.atlRentGrowthPct, 0...10, 0.25)),
                Field(title: "Running it costs", caption: "a month, all in", kind: .money(\.atlRentExpensesMonthly)),
            ]),
            FieldGroup(title: HouseholdCopy.nextCity, fields: [
                Field(title: "Price", caption: nil, kind: .money(\.tacPrice)),
                Field(title: "Bought in", caption: "years from now", kind: .count(\.tacBuyYear, 0...25)),
                // 5 to 25 in whole steps is all Retiron's own slider can hold, and it silently
                // snaps anything else, so keep the phone inside the same range.
                Field(title: "Deposit", caption: "share of the price", kind: .percent(\.tacDownPct, 5...25, 1)),
                Field(title: "Mortgage rate", caption: nil, kind: .percent(\.tacRatePct, 0...12, 0.125)),
                Field(title: "It gains", caption: "every year", kind: .percent(\.tacAppreciationPct, 0...12, 0.25)),
            ]),
        ]
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                youSection
                if let draft = householdDraft {
                    householdSection(draft)
                }
                retironRow
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
        }
        .scrollIndicators(.hidden)
        .themedScreen()
        .navigationTitle("Plan Inputs")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    save()
                }
                .fontWeight(.semibold)
            }
        }
        // Keyed on the profile, not onAppear: a cache-first load can land the profile a beat
        // after this screen is on, and the Household section has to appear when it does. The
        // `householdDraft == nil` guard inside keeps it a seed-once.
        .task(id: household?.profile) {
            seedHouseholdDraft()
        }
        .task {
            await loadDerivedSpending()
        }
        .task(id: config.linkedAccountIDs) {
            await loadDetectedContribution()
        }
        .sheet(item: $moneyEdit) { edit in
            AmountEntrySheet(title: edit.title,
                             caption: edit.caption,
                             initial: amount(for: edit)) { newValue in
                setAmount(newValue, for: edit)
            }
        }
    }

    private func seedHouseholdDraft() {
        guard householdDraft == nil, let household, household.isConnected,
              let profile = household.profile else { return }
        let seeded = RetironProfileMapper.config(from: profile)
        householdDraft = seeded
        householdSeed = seeded
    }

    // MARK: You section

    private var youSection: some View {
        Group {
            Group {
                SectionHeader("You")
                sectionCaption("These stay on this phone.")
                SectionHeader("Ages")
                agesCard
                SectionHeader("Money")
                moneyCard
            }
            Group {
                SectionHeader("Market Assumptions")
                ratesCard
                if householdDraft != nil {
                    sectionCaption("The household plan keeps its own return and inflation below.")
                }
                SectionHeader("Linked Accounts")
                accountsCard
            }
        }
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Ages

    private var agesCard: some View {
        VStack(spacing: theme.layout.spacing * 0.5) {
            stepperRow(title: "Current age", value: $config.currentAge, range: 16...90)
            divider
            stepperRow(title: "Retire at", value: $config.retireAge, range: retireAgeRange)
            divider
            stepperRow(title: "Plan through age", value: $config.lifeExpectancy, range: lifeExpectancyRange)
        }
        .themedCard()
    }

    /// Ranges are clamped so the lower bound can never exceed the upper bound (a reversed
    /// `ClosedRange` would trap), while still keeping retire at or past current and the horizon
    /// at or past retirement as the user steps values around.
    private var retireAgeRange: ClosedRange<Int> {
        min(max(config.currentAge, 30), 95)...95
    }

    private var lifeExpectancyRange: ClosedRange<Int> {
        min(max(config.retireAge, 50), 110)...110
    }

    private func stepperRow(title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: theme.layout.spacing)
                Text("\(value.wrappedValue)")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: value.wrappedValue)
            }
        }
        .tint(theme.palette.accent)
        .frame(minHeight: 44)
        .onChange(of: value.wrappedValue) { _, _ in
            Haptics.tick()
        }
    }

    // MARK: Money

    private var moneyCard: some View {
        VStack(spacing: theme.layout.spacing * 0.5) {
            localMoneyRow(field: .extraAssets, value: config.extraAssets)
            divider
            localMoneyRow(field: .monthlyContribution, value: config.monthlyContribution)
            if let detectedContribution {
                detectedContributionRow(detectedContribution)
            }
            divider
            deriveToggleRow
            if let override = config.annualSpendingOverride {
                localMoneyRow(field: .annualSpending, value: override)
                    .transition(.opacity)
            }
        }
        .themedCard()
        .animation(reduceMotion ? nil : theme.motion.spring,
                   value: config.annualSpendingOverride == nil)
    }

    private func localMoneyRow(field: LocalMoneyField, value: Money) -> some View {
        Button {
            moneyEdit = MoneyEdit(title: field.title, caption: field.caption,
                                  target: .local(field))
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.title)
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(field.caption)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: theme.layout.spacing)
                AmountText(value, style: .body, colorized: false)
                chevron
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the amount keypad")
    }

    /// Contribution detected from real transfers into the linked accounts, with a Use button.
    /// The keypad row above stays the manual override; this just saves the typing.
    private func detectedContributionRow(_ detected: Money) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Detected from your transfers")
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                HStack(spacing: 4) {
                    Text("About")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                    AmountText(detected, style: .caption, colorized: false)
                    Text("a month over the last 6 months.")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            Spacer(minLength: theme.layout.spacing)
            if config.monthlyContribution == detected {
                Image(systemName: "checkmark.circle.fill")
                    .font(theme.font(.title))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.palette.accent)
                    .accessibilityLabel("Already in use")
            } else {
                Button {
                    Haptics.tick()
                    withAnimation(reduceMotion ? nil : theme.motion.snappy) {
                        config.monthlyContribution = detected
                    }
                } label: {
                    Text("Use")
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.palette.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use the detected contribution")
            }
        }
        .frame(minHeight: 44)
    }

    private var deriveToggleRow: some View {
        Toggle(isOn: deriveFromBudgetBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Derive from budget")
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                derivedCaption
            }
        }
        .tint(theme.palette.accent)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var derivedCaption: some View {
        if let derivedAnnualSpending {
            HStack(spacing: 4) {
                Text("Last 12 months:")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                AmountText(derivedAnnualSpending, style: .caption, colorized: false)
            }
        } else {
            Text("Uses your last 12 months of spending.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
    }

    private var deriveFromBudgetBinding: Binding<Bool> {
        Binding(
            get: { config.annualSpendingOverride == nil },
            set: { derive in
                Haptics.tick()
                if derive {
                    if let override = config.annualSpendingOverride {
                        rememberedOverride = override
                    }
                    config.annualSpendingOverride = nil
                } else {
                    config.annualSpendingOverride = rememberedOverride
                        ?? derivedAnnualSpending
                        ?? .zero
                }
            }
        )
    }

    // MARK: Rates

    private var ratesCard: some View {
        VStack(spacing: theme.layout.spacing) {
            rateSlider(title: "Expected return", value: $config.expectedReturnPct,
                       range: 0...15, step: 0.1)
            rateSlider(title: "Volatility (std. dev.)", value: $config.returnStdDevPct,
                       range: 0...30, step: 0.5)
            rateSlider(title: "Inflation", value: $config.inflationPct,
                       range: 0...10, step: 0.1)
            rateSlider(title: "Withdrawal rate", value: $config.withdrawalRatePct,
                       range: 1...10, step: 0.1)
        }
        .themedCard()
    }

    private func rateSlider(title: String, value: Binding<Double>,
                            range: ClosedRange<Double>, step: Double) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer(minLength: theme.layout.spacing)
                Text(Self.rateText(value.wrappedValue))
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: value.wrappedValue)
            }
            Slider(value: value, in: range, step: step)
                .tint(theme.palette.accent)
                .accessibilityLabel(title)
        }
        .frame(minHeight: 44)
    }

    // MARK: Linked accounts

    /// Open accounts, off-budget first, because investment accounts usually live off-budget.
    private var linkableAccounts: [Account] {
        let open = store.accounts.filter { !$0.closed }
        return open.filter(\.offBudget) + open.filter { !$0.offBudget }
    }

    @ViewBuilder
    private var accountsCard: some View {
        if linkableAccounts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No accounts to link")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Accounts from your Actual budget will show up here. Off-budget investment accounts work best.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .themedCard()
        } else {
            VStack(spacing: 0) {
                ForEach(linkableAccounts) { account in
                    accountRow(account)
                    if account.id != linkableAccounts.last?.id {
                        divider
                    }
                }
            }
            .themedCard()
        }
    }

    private func accountRow(_ account: Account) -> some View {
        let isLinked = config.linkedAccountIDs.contains(account.id)
        return Button {
            toggleLinked(account.id)
        } label: {
            HStack(spacing: theme.layout.spacing * 0.75) {
                Image(systemName: isLinked ? "checkmark.circle.fill" : "circle")
                    .font(theme.font(.title))
                    .fontWeight(theme.icons.weight)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isLinked ? theme.palette.accent : theme.palette.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: isLinked)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Text(account.offBudget ? "Off budget" : "On budget")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                Spacer(minLength: theme.layout.spacing)
                AmountText(account.balance, style: .body, colorized: false)
            }
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isLinked ? [.isSelected] : [])
    }

    private func toggleLinked(_ id: String) {
        Haptics.tick()
        if let index = config.linkedAccountIDs.firstIndex(of: id) {
            config.linkedAccountIDs.remove(at: index)
        } else {
            config.linkedAccountIDs.append(id)
        }
    }

    // MARK: Household section

    private func householdSection(_ draft: HouseholdPlanConfig) -> some View {
        Group {
            SectionHeader("Household")
            sectionCaption("These numbers save to Retiron for both of you.")
            ForEach(groups(for: draft)) { group in
                SectionHeader(group.title)
                householdCard(for: group, draft: draft)
                if group.title == "Goals And Rates" {
                    sectionCaption("Your sandbox uses the rates above.")
                }
            }
            sectionCaption("These go back to Retiron as soon as you save. Anything Retiron holds that this screen does not show is left exactly as it was.")
        }
    }

    private func householdCard(for group: FieldGroup, draft: HouseholdPlanConfig) -> some View {
        VStack(spacing: theme.layout.spacing * 0.5) {
            ForEach(Array(group.fields.enumerated()), id: \.element.id) { index, field in
                householdRow(field, draft: draft)
                if index < group.fields.count - 1 {
                    divider
                }
            }
        }
        .themedCard()
    }

    @ViewBuilder
    private func householdRow(_ field: Field, draft: HouseholdPlanConfig) -> some View {
        switch field.kind {
        case .money(let keyPath):
            householdMoneyRow(field, keyPath: keyPath, draft: draft)
        case .percent(let keyPath, let range, let step):
            householdPercentRow(field, keyPath: keyPath, range: range, step: step, draft: draft)
        case .count(let keyPath, let range):
            householdCountRow(field, keyPath: keyPath, range: range, draft: draft)
        case .flag(let keyPath):
            householdFlagRow(field, keyPath: keyPath)
        }
    }

    private func householdMoneyRow(_ field: Field,
                                   keyPath: WritableKeyPath<HouseholdPlanConfig, Double>,
                                   draft: HouseholdPlanConfig) -> some View {
        Button {
            moneyEdit = MoneyEdit(title: field.title,
                                  caption: field.caption ?? "Tap the numbers to change it.",
                                  target: .household(keyPath))
        } label: {
            HStack(alignment: .firstTextBaseline) {
                labelStack(field)
                Spacer(minLength: theme.layout.spacing)
                AmountText(Money(clampedDollars: draft[keyPath: keyPath]), style: .body,
                           colorized: false)
                chevron
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the amount keypad")
    }

    private func householdPercentRow(_ field: Field,
                                     keyPath: WritableKeyPath<HouseholdPlanConfig, Double>,
                                     range: ClosedRange<Double>, step: Double,
                                     draft: HouseholdPlanConfig) -> some View {
        let value = draft[keyPath: keyPath]
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                labelStack(field)
                Spacer(minLength: theme.layout.spacing)
                Text(Self.householdPercentText(value))
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: value)
            }
            Slider(value: householdBinding(keyPath), in: range, step: step)
                .tint(theme.palette.accent)
                .accessibilityLabel(field.title)
        }
        .frame(minHeight: 44)
    }

    private func householdCountRow(_ field: Field,
                                   keyPath: WritableKeyPath<HouseholdPlanConfig, Int>,
                                   range: ClosedRange<Int>,
                                   draft: HouseholdPlanConfig) -> some View {
        let value = draft[keyPath: keyPath]
        return Stepper(value: householdBinding(keyPath), in: range) {
            HStack(alignment: .firstTextBaseline) {
                labelStack(field)
                Spacer(minLength: theme.layout.spacing)
                Text("\(value)")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: value)
            }
        }
        .tint(theme.palette.accent)
        .frame(minHeight: 44)
        .onChange(of: value) { _, _ in Haptics.tick() }
    }

    private func householdFlagRow(_ field: Field,
                                  keyPath: WritableKeyPath<HouseholdPlanConfig, Bool>) -> some View {
        Toggle(isOn: householdBinding(keyPath)) {
            labelStack(field)
        }
        .tint(theme.palette.accent)
        .frame(minHeight: 44)
    }

    private func labelStack(_ field: Field) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.title)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let caption = field.caption {
                Text(caption)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func householdBinding<Value>(
        _ keyPath: WritableKeyPath<HouseholdPlanConfig, Value>
    ) -> Binding<Value> {
        Binding(get: { householdDraft?[keyPath: keyPath] ?? Self.fallbackHousehold[keyPath: keyPath] },
                set: { householdDraft?[keyPath: keyPath] = $0 })
    }

    // MARK: Retiron connection

    private var retironRow: some View {
        Button {
            Haptics.tick()
            router.push(.retironSettings)
        } label: {
            HStack(spacing: theme.layout.spacing * 0.75) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(theme.font(.title))
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.accent)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                Text("Retiron connection")
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer(minLength: theme.layout.spacing)
                chevron
            }
            .frame(minHeight: 44)
            .themedCard()
            .contentShape(theme.cardShape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: Keypad plumbing

    private func amount(for edit: MoneyEdit) -> Money {
        switch edit.target {
        case .local(let field):
            switch field {
            case .extraAssets: return config.extraAssets
            case .monthlyContribution: return config.monthlyContribution
            case .annualSpending: return config.annualSpendingOverride ?? derivedAnnualSpending ?? .zero
            }
        case .household(let keyPath):
            return Money(clampedDollars: householdDraft?[keyPath: keyPath] ?? 0)
        }
    }

    private func setAmount(_ value: Money, for edit: MoneyEdit) {
        let clamped = Money(cents: max(value.cents, 0))
        switch edit.target {
        case .local(let field):
            switch field {
            case .extraAssets:
                config.extraAssets = clamped
            case .monthlyContribution:
                config.monthlyContribution = clamped
            case .annualSpending:
                config.annualSpendingOverride = clamped
                rememberedOverride = clamped
            }
        case .household(let keyPath):
            householdDraft?[keyPath: keyPath] = max(0, clamped.doubleValue)
        }
    }

    // MARK: Save & data

    private func save() {
        var sanitized = config
        sanitized.retireAge = max(sanitized.retireAge, sanitized.currentAge)
        sanitized.lifeExpectancy = max(sanitized.lifeExpectancy, sanitized.retireAge)
        guard let json = RetirementConfigCodec.encode(sanitized) else {
            Haptics.warning()
            return
        }
        // Apply whichever drafts changed; an untouched tier writes nothing.
        if json != preferences.retirementConfigJSON {
            preferences.retirementConfigJSON = json
        }
        if let draft = householdDraft, let seed = householdSeed, draft != seed {
            household?.applyConfig(draft)
        }
        Haptics.success()
        dismiss()
    }

    private func loadDerivedSpending() async {
        let series = await store.monthlySpendSeries(monthsBack: 12)
        guard !Task.isCancelled else { return }
        derivedAnnualSpending = series.reduce(Money.zero) { $0 + $1.1.magnitude }
    }

    private func loadDetectedContribution() async {
        let detected = await ContributionDetector.detectedMonthlyContribution(
            store: store, linkedAccountIDs: config.linkedAccountIDs)
        guard !Task.isCancelled else { return }
        detectedContribution = detected
    }

    // MARK: Shared bits

    private var divider: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(theme.font(.caption))
            .fontWeight(theme.icons.weight)
            .foregroundStyle(theme.palette.textTertiary)
            .accessibilityHidden(true)
    }

    private static func rateText(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(1)))
    }

    private static func householdPercentText(_ value: Double) -> String {
        let safe = value.isFinite ? min(max(value, 0), 999) : 0
        return (safe / 100).formatted(.percent.precision(.fractionLength(0...2)))
    }
}
