import SwiftUI

// MARK: - MoveMoneySheet
//
// Moves budgeted money between two envelopes for a month (ARCHITECTURE §14) — either side may
// be "To Budget" (nil), matching `AppStore.moveBudget(month:from:to:amount:)` exactly. Reached
// from a category row's leading "Move" swipe action; the swiped category preloads as `from`.
// The swap button exchanges the two sides with a spring-rotated icon — a single small view
// animates rather than rebuilding the cards (LESSONS_FROM_STASHY §1: keep the modifier chain
// unconditional, gate the effect not the structure).

struct MoveMoneySheet: View {
    private let month: BudgetMonth

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var fromCategoryID: String?
    @State private var toCategoryID: String?
    @State private var amount: Money = .zero
    @State private var swapRotation: Double = 0
    @State private var isSaving = false

    init(month: BudgetMonth, initialFromCategoryID: String? = nil) {
        self.month = month
        self._fromCategoryID = State(initialValue: initialFromCategoryID)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: theme.layout.spacing) {
                header
                if moveableCategories.isEmpty {
                    EmptyStateView(systemImage: "tag",
                                  title: "No categories yet",
                                  message: "This budget has no categories to move money between.")
                } else {
                    fromToCards
                    AmountKeypad(amount: $amount, allowsSign: false)
                    NidgetButton("Save", systemImage: "checkmark", role: .primary) {
                        save()
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScreen()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Move Money")
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(month.displayName)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
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

    // MARK: From / To

    private var fromToCards: some View {
        VStack(spacing: 10) {
            categoryCard(title: "From", selection: $fromCategoryID)
            swapButton
            categoryCard(title: "To", selection: $toCategoryID)
        }
    }

    private func categoryCard(title: String, selection: Binding<String?>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                Text(displayName(selection.wrappedValue))
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            Picker("", selection: selection) {
                Text("To Budget").tag(String?.none)
                ForEach(moveableCategories) { category in
                    Text(category.name).tag(String?.some(category.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(theme.palette.accent)
        }
        .frame(minHeight: 44)
        .themedCard()
    }

    private var swapButton: some View {
        HStack {
            Spacer()
            Button {
                Haptics.tick()
                let swapped = (fromCategoryID, toCategoryID)
                if reduceMotion {
                    fromCategoryID = swapped.1
                    toCategoryID = swapped.0
                } else {
                    withAnimation(theme.motion.spring) {
                        fromCategoryID = swapped.1
                        toCategoryID = swapped.0
                    }
                }
                swapRotation += 180
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .font(theme.font(.title))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.accent)
                    .rotationEffect(.degrees(swapRotation))
                    .frame(width: 44, height: 44)
                    .animation(reduceMotion ? nil : theme.motion.spring, value: swapRotation)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Swap From and To")
            Spacer()
        }
    }

    // MARK: Data

    private var moveableCategories: [Category] {
        store.categoryGroups
            .filter { !$0.isIncome && !$0.hidden }
            .flatMap { group in group.categories.filter { !$0.hidden && !$0.isIncome } }
    }

    private func displayName(_ id: String?) -> String {
        guard let id else { return "To Budget" }
        let name = store.categoryName(id)
        return name.isEmpty ? "Category" : name
    }

    private var canSave: Bool {
        amount.cents > 0 && fromCategoryID != toCategoryID
    }

    // MARK: Save

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        Task {
            await store.moveBudget(month: month, from: fromCategoryID, to: toCategoryID, amount: amount)
            Haptics.success()
            dismiss()
        }
    }
}
