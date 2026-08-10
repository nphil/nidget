import SwiftUI

// MARK: - AssumptionsSheet
//
// Full `RetirementConfig` editor, pushed via `Route.retirementAssumptions` (ARCHITECTURE §16 —
// the `AssumptionsSheet()` initializer is binding). Themed cards rather than a plain Form:
// age steppers, keypad-backed money rows, rate sliders with 0.1-precision labels, and a
// linked-accounts multi-select (off-budget accounts first — that's where investments live).
// Under the contribution row, a detected value from real transfers into the linked accounts
// (`ContributionDetector`, averaged over 6 months) offers itself with a Use button; the manual
// keypad override always stays available.
//
// Editing happens on a local copy seeded from `Preferences.retirementConfigJSON` at init;
// nothing persists until Save (which sanitizes age ordering, encodes deterministically, and
// fires `Haptics.success`). Cancel — or just popping back — discards every change.

@MainActor
struct AssumptionsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var config: RetirementConfig
    /// Last non-nil spending override, so toggling "Derive from budget" off restores it.
    @State private var rememberedOverride: Money?
    /// Last-12-months outflow, loaded async for the derive-toggle caption and override seed.
    @State private var derivedAnnualSpending: Money?
    /// Monthly contribution detected from transfers into the linked accounts; nil = none found.
    @State private var detectedContribution: Money?
    @State private var editingField: MoneyField?

    init() {
        let decoded = RetirementConfigCodec.decode(Preferences.shared.retirementConfigJSON)
        _config = State(initialValue: decoded)
        _rememberedOverride = State(initialValue: decoded.annualSpendingOverride)
    }

    // MARK: Money fields

    private enum MoneyField: String, Identifiable {
        case extraAssets, monthlyContribution, annualSpending

        var id: String { rawValue }

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

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                SectionHeader("Ages")
                agesCard
                SectionHeader("Money")
                moneyCard
                SectionHeader("Market Assumptions")
                ratesCard
                SectionHeader("Linked Accounts")
                accountsCard
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
        }
        .scrollIndicators(.hidden)
        .themedScreen()
        .navigationTitle("Assumptions")
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
        .task {
            await loadDerivedSpending()
        }
        .task(id: config.linkedAccountIDs) {
            await loadDetectedContribution()
        }
        .sheet(item: $editingField) { field in
            MoneyEntrySheet(title: field.title,
                            caption: field.caption,
                            initial: amount(for: field)) { newValue in
                setAmount(newValue, for: field)
            }
            .presentationDetents([.height(520), .large])
            .presentationDragIndicator(.visible)
        }
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
    /// `ClosedRange` would trap), while still keeping retire ≥ current and horizon ≥ retire
    /// as the user steps values around.
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
            moneyRow(field: .extraAssets, value: config.extraAssets)
            divider
            moneyRow(field: .monthlyContribution, value: config.monthlyContribution)
            if let detectedContribution {
                detectedContributionRow(detectedContribution)
            }
            divider
            deriveToggleRow
            if let override = config.annualSpendingOverride {
                moneyRow(field: .annualSpending, value: override)
                    .transition(.opacity)
            }
        }
        .themedCard()
        .animation(reduceMotion ? nil : theme.motion.spring,
                   value: config.annualSpendingOverride == nil)
    }

    private func moneyRow(field: MoneyField, value: Money) -> some View {
        Button {
            editingField = field
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

    private func amount(for field: MoneyField) -> Money {
        switch field {
        case .extraAssets: return config.extraAssets
        case .monthlyContribution: return config.monthlyContribution
        case .annualSpending: return config.annualSpendingOverride ?? derivedAnnualSpending ?? .zero
        }
    }

    private func setAmount(_ value: Money, for field: MoneyField) {
        let clamped = Money(cents: max(value.cents, 0))
        switch field {
        case .extraAssets:
            config.extraAssets = clamped
        case .monthlyContribution:
            config.monthlyContribution = clamped
        case .annualSpending:
            config.annualSpendingOverride = clamped
            rememberedOverride = clamped
        }
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
                Text(percentText(value.wrappedValue))
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

    private func percentText(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(1)))
    }

    // MARK: Linked accounts

    /// Open accounts, off-budget first — investment accounts usually live off-budget.
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

    // MARK: Save & data

    private func save() {
        var sanitized = config
        sanitized.retireAge = max(sanitized.retireAge, sanitized.currentAge)
        sanitized.lifeExpectancy = max(sanitized.lifeExpectancy, sanitized.retireAge)
        guard let json = RetirementConfigCodec.encode(sanitized) else {
            Haptics.warning()
            return
        }
        preferences.retirementConfigJSON = json
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
}

// MARK: - MoneyEntrySheet
//
// Keypad-backed amount entry for one money field: title + caption, a live display that ticks
// with `.numericText()`, the shared `AmountKeypad` (no sign — these are all magnitudes), and a
// Set button. The staged value only reaches the config through `onSet`; the outer Save persists.

private struct MoneyEntrySheet: View {
    private let title: String
    private let caption: String
    private let onSet: (Money) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var amount: Money

    init(title: String, caption: String, initial: Money, onSet: @escaping (Money) -> Void) {
        self.title = title
        self.caption = caption
        self.onSet = onSet
        self._amount = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: theme.layout.spacing) {
                header
                AmountText(amount, style: .display, colorized: false)
                    .frame(maxWidth: .infinity)
                AmountKeypad(amount: $amount, allowsSign: false)
                NidgetButton("Set Amount", systemImage: "checkmark") {
                    onSet(Money(cents: max(amount.cents, 0)))
                    dismiss()
                }
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScreen()
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text(caption)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: theme.layout.spacing)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(theme.font(.title))
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.palette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }
}
