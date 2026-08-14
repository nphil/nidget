import SwiftUI

// MARK: - HouseholdInputsSheet
//
// The editor behind the pencil on the Household Plan. Same shape as AssumptionsSheet: a local
// draft seeded at init, themed cards instead of a Form, keypad-backed money rows, sliders for
// rates and steppers for years, and nothing persisted until Save.
//
// The rows are built from a table rather than written out one by one, so adding a field is one
// line in `groups` and nothing else. Every field in that table maps to a real Retiron input (see
// `RetironProfileMapper`); the config fields Retiron has no home for (the ages, the horizon, the
// tax table, the contribution caps) are deliberately absent, because editing them here would look
// like it saved and then quietly reset on the next fetch.

@MainActor
struct HouseholdInputsSheet: View {
    private let onSave: (HouseholdPlanConfig) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft: HouseholdPlanConfig
    @State private var moneyEdit: MoneyEdit?

    init(config: HouseholdPlanConfig, onSave: @escaping (HouseholdPlanConfig) -> Void) {
        self.onSave = onSave
        _draft = State(initialValue: config)
    }

    // MARK: Field table

    /// One editable row. `kind` carries the writable key path, so the row and the value never
    /// drift apart.
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

    private var groups: [FieldGroup] {
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
            FieldGroup(title: "Atlanta", fields: [
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
            FieldGroup(title: "Tacoma", fields: [
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.layout.spacing) {
                    ForEach(groups) { group in
                        SectionHeader(group.title)
                        card(for: group)
                    }
                    Text("These go back to Retiron as soon as you save. Anything Retiron holds that this screen does not show is left exactly as it was.")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, theme.layout.cardPadding)
                .padding(.top, theme.layout.spacing * 0.5)
                .padding(.bottom, theme.layout.cardSpacing)
            }
            .scrollIndicators(.hidden)
            .themedScreen()
            .navigationTitle("Plan Inputs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(item: $moneyEdit) { edit in
            HouseholdAmountSheet(title: edit.title,
                                 caption: edit.caption,
                                 initial: Money(clampedDollars: draft[keyPath: edit.keyPath])) { amount in
                draft[keyPath: edit.keyPath] = max(0, amount.doubleValue)
            }
            .presentationDetents([.height(520), .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: Rows

    private func card(for group: FieldGroup) -> some View {
        VStack(spacing: theme.layout.spacing * 0.5) {
            ForEach(Array(group.fields.enumerated()), id: \.element.id) { index, field in
                row(field)
                if index < group.fields.count - 1 {
                    Rectangle()
                        .fill(theme.palette.separator)
                        .frame(height: 1)
                }
            }
        }
        .themedCard()
    }

    @ViewBuilder
    private func row(_ field: Field) -> some View {
        switch field.kind {
        case .money(let keyPath):
            moneyRow(field, keyPath: keyPath)
        case .percent(let keyPath, let range, let step):
            percentRow(field, keyPath: keyPath, range: range, step: step)
        case .count(let keyPath, let range):
            countRow(field, keyPath: keyPath, range: range)
        case .flag(let keyPath):
            flagRow(field, keyPath: keyPath)
        }
    }

    private func moneyRow(_ field: Field,
                          keyPath: WritableKeyPath<HouseholdPlanConfig, Double>) -> some View {
        Button {
            moneyEdit = MoneyEdit(title: field.title,
                                  caption: field.caption ?? "Tap the numbers to change it.",
                                  keyPath: keyPath)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                labelStack(field)
                Spacer(minLength: theme.layout.spacing)
                AmountText(Money(clampedDollars: draft[keyPath: keyPath]), style: .body,
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

    private func percentRow(_ field: Field,
                            keyPath: WritableKeyPath<HouseholdPlanConfig, Double>,
                            range: ClosedRange<Double>, step: Double) -> some View {
        let value = draft[keyPath: keyPath]
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                labelStack(field)
                Spacer(minLength: theme.layout.spacing)
                Text(Self.percentText(value))
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: value)
            }
            Slider(value: binding(keyPath), in: range, step: step)
                .tint(theme.palette.accent)
                .accessibilityLabel(field.title)
        }
        .frame(minHeight: 44)
    }

    private func countRow(_ field: Field,
                          keyPath: WritableKeyPath<HouseholdPlanConfig, Int>,
                          range: ClosedRange<Int>) -> some View {
        let value = draft[keyPath: keyPath]
        return Stepper(value: binding(keyPath), in: range) {
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

    private func flagRow(_ field: Field,
                         keyPath: WritableKeyPath<HouseholdPlanConfig, Bool>) -> some View {
        Toggle(isOn: binding(keyPath)) {
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

    // MARK: Plumbing

    /// One pending trip to the keypad, identified by the field it edits.
    private struct MoneyEdit: Identifiable {
        var title: String
        var caption: String
        var keyPath: WritableKeyPath<HouseholdPlanConfig, Double>
        var id: String { title }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<HouseholdPlanConfig, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] },
                set: { draft[keyPath: keyPath] = $0 })
    }

    private func save() {
        onSave(draft)
        Haptics.success()
        dismiss()
    }

    private static func percentText(_ value: Double) -> String {
        let safe = value.isFinite ? min(max(value, 0), 999) : 0
        return (safe / 100).formatted(.percent.precision(.fractionLength(0...2)))
    }
}

// MARK: - HouseholdAmountSheet
//
// Keypad-backed amount entry for one plan number: title, a line of explanation, a live display
// that ticks with `.numericText()`, the shared `AmountKeypad` (no sign, these are all magnitudes)
// and a Set button. The staged amount only leaves through `onSet`.
//
// The same sheet serves the inputs editor and the debt section, which is why it lives here rather
// than inside either of them.

struct HouseholdAmountSheet: View {
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
        _amount = State(initialValue: initial)
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
                    .minimumScaleFactor(0.7)
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
