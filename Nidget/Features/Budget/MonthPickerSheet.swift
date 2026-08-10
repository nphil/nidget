import SwiftUI

// MARK: - MonthPickerSheet
//
// Native replacement for the inline month ChipPicker row that used to live in BudgetView's
// header (UX_ROUND2 §3): a year stepper over a 3x4 grid of month abbreviations. This sheet is a
// pure picker — it only reports the tapped month through `onSelect` and dismisses itself; the
// caller owns the actual navigation (direction + spring animation), which keeps this file
// reusable as-is from Reports later without dragging BudgetView's nav-direction state along.

struct MonthPickerSheet: View {
    let currentMonth: BudgetMonth
    let onSelect: (BudgetMonth) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var displayedYear: Int

    init(currentMonth: BudgetMonth, onSelect: @escaping (BudgetMonth) -> Void) {
        self.currentMonth = currentMonth
        self.onSelect = onSelect
        self._displayedYear = State(initialValue: currentMonth.year)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    /// Months from here on are dimmed (still selectable) — mirrors the range BudgetView's
    /// chevrons already navigate: the current month plus one.
    private var lastFullySelectableMonth: BudgetMonth { BudgetMonth.current.advanced(by: 1) }

    var body: some View {
        ScrollView {
            VStack(spacing: theme.layout.spacing * 1.25) {
                header
                yearStepper
                monthGrid
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScreen()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            Text("Jump to Month")
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
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

    // MARK: Year stepper

    private var yearStepper: some View {
        HStack {
            yearStepButton(systemImage: "chevron.left", label: "Previous year") { displayedYear -= 1 }
            Spacer()
            Text(String(displayedYear))
                .font(theme.font(.headline))
                .foregroundStyle(theme.palette.textPrimary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: displayedYear)
            Spacer()
            yearStepButton(systemImage: "chevron.right", label: "Next year") { displayedYear += 1 }
        }
    }

    private func yearStepButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(theme.font(.headline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Month grid

    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(1...12, id: \.self) { monthNumber in
                monthCell(BudgetMonth(year: displayedYear, month: monthNumber))
            }
        }
    }

    private func monthCell(_ month: BudgetMonth) -> some View {
        let isSelected = month == currentMonth
        let isCurrent = month == .current
        let isDimmed = month > lastFullySelectableMonth

        return Button {
            Haptics.tick()
            onSelect(month)
            dismiss()
        } label: {
            Text(month.shortName)
                .font(theme.font(.body))
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(cellForeground(isSelected: isSelected, isDimmed: isDimmed))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background {
                    theme.controlShape
                        .fill(isSelected ? theme.palette.accent : theme.palette.fill)
                }
                .overlay {
                    if isCurrent && !isSelected {
                        theme.controlShape
                            .strokeBorder(theme.palette.accent, lineWidth: 1.5)
                    }
                }
                .contentShape(theme.controlShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(month.displayName))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func cellForeground(isSelected: Bool, isDimmed: Bool) -> Color {
        if isSelected { return theme.palette.onAccent }
        if isDimmed { return theme.palette.textTertiary }
        return theme.palette.textPrimary
    }
}
