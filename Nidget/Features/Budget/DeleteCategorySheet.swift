import SwiftUI

// MARK: - DeleteCategorySheet
//
// Confirms deleting a category (ARCHITECTURE §16 / category-management task): counts how many
// transactions currently point at it (`store.transactions(_:)`, fetched once in `.task`), offers
// a reassignment target — another visible category, or "Leave uncategorized" — then routes the
// confirm tap through `AppStore.deleteCategory(id:reassignTo:)`, which rewrites every affected
// transaction's category cell alongside the category's own tombstone write in ONE CRDT batch.
// Reached from both `ManageCategoriesView` and `BudgetView`'s category context menu.

struct DeleteCategorySheet: View {
    let category: Category

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var transactionCount: Int?
    /// "" means "leave uncategorized" (encoded as a NULL category cell by AppStore).
    @State private var targetCategoryID: String = ""
    @State private var isDeleting = false

    /// "High enough" per the owning task's spec: a personal budget's single category realistically
    /// never approaches this, so the count is effectively exact while still bounding the query.
    private static let countFetchLimit = 10_000

    init(category: Category) {
        self.category = category
    }

    private var otherCategories: [Category] {
        store.categoryGroups
            .flatMap(\.categories)
            .filter { $0.id != category.id && !$0.hidden }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                usageCard
                if (transactionCount ?? 0) > 0 {
                    reassignCard
                }

                NidgetButton("Delete Category", systemImage: "trash", role: .destructive) {
                    Task { await confirmDelete() }
                }
                .disabled(isDeleting || transactionCount == nil)
                .opacity(isDeleting ? 0.6 : 1)
                .animation(reduceMotion ? nil : theme.motion.snappy, value: isDeleting)

                Spacer(minLength: 0)
            }
            .padding(theme.layout.spacing)
            .themedScreen()
            .navigationTitle("Delete Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(theme.palette.textSecondary)
                        .disabled(isDeleting)
                }
            }
        }
        .task { await loadCount() }
    }

    // MARK: Usage

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            SectionHeader("Transactions")
            if let transactionCount {
                Text(usageMessage(transactionCount))
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textSecondary)
            } else {
                ProgressView()
                    .tint(theme.palette.accent)
            }
        }
        .themedCard()
    }

    private func usageMessage(_ count: Int) -> String {
        guard count > 0 else { return "No transactions use \(category.name)." }
        let plural = count == 1 ? "transaction uses" : "transactions use"
        return "\(count) \(plural) \(category.name). Choose where they go before deleting."
    }

    // MARK: Reassignment

    private var reassignCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Move them to")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                Text(targetDisplayName)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            Picker("", selection: $targetCategoryID) {
                Text("Leave uncategorized").tag("")
                ForEach(otherCategories) { other in
                    Text(other.name).tag(other.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(theme.palette.accent)
        }
        .frame(minHeight: 44)
        .themedCard()
    }

    private var targetDisplayName: String {
        guard !targetCategoryID.isEmpty,
              let match = otherCategories.first(where: { $0.id == targetCategoryID }) else {
            return "Leave uncategorized"
        }
        return match.name
    }

    // MARK: Loading & confirming

    private func loadCount() async {
        let query = TransactionQuery(categoryID: category.id, months: nil, limit: Self.countFetchLimit)
        let matches = await store.transactions(query)
        guard !Task.isCancelled else { return }
        transactionCount = matches.count
    }

    private func confirmDelete() async {
        guard !isDeleting else { return }
        isDeleting = true
        Haptics.warning()
        let target = targetCategoryID.isEmpty ? nil : targetCategoryID
        await store.deleteCategory(id: category.id, reassignTo: target)
        isDeleting = false
        dismiss()
    }
}
