import SwiftUI

// MARK: - CategoryPickerSheet
//
// Grouped category chooser presented as a sheet by Quick Add and the transaction editor.
// Non-income groups list first, a search field filters across every group, and a "Recent"
// chip row (derived from the latest transactions) puts the likely picks one tap away.
// The selection returns through the `categoryID` binding; picking dismisses.

struct CategoryPickerSheet: View {
    @Binding private var categoryID: String?

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var recentIDs: [String] = []

    init(categoryID: Binding<String?>) {
        self._categoryID = categoryID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            header
            searchField
            content
        }
        .padding(.top, theme.layout.spacing)
        .themedScreen()
        .task { await loadRecents() }
    }

    // MARK: Header & search

    private var header: some View {
        HStack {
            Text("Pick a Category")
                .font(theme.font(.title))
                .foregroundStyle(theme.palette.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(theme.font(.title))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.palette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, theme.layout.cardPadding)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(theme.font(.body))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.textTertiary)
            TextField("Search categories", text: $searchText)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(theme.font(.subheadline))
                        .fontWeight(theme.icons.weight)
                        .symbolVariant(theme.icons.fill ? .fill : .none)
                        .foregroundStyle(theme.palette.textTertiary)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(theme.controlShape.fill(theme.palette.fill))
        .padding(.horizontal, theme.layout.cardPadding)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if allVisibleCategories.isEmpty {
            EmptyStateView(systemImage: "tag",
                           title: "No categories yet",
                           message: "This budget has no categories to pick from. Add some in Actual and they'll appear here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
                    if trimmedSearch.isEmpty {
                        browseList
                    } else {
                        searchResultsList
                    }
                }
                .padding(.horizontal, theme.layout.cardPadding)
                .padding(.bottom, theme.layout.cardPadding)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    @ViewBuilder
    private var browseList: some View {
        if !recentIDs.isEmpty {
            SectionHeader("Recent")
            recentChipsRow
        }
        noCategoryRow
        ForEach(orderedGroups) { group in
            let visible = group.categories.filter { !$0.hidden }
            if !visible.isEmpty {
                SectionHeader(group.name)
                    .padding(.top, theme.layout.spacing * 0.5)
                ForEach(visible) { category in
                    categoryRow(category)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultsList: some View {
        let matches = searchMatches
        if matches.isEmpty {
            EmptyStateView(systemImage: "magnifyingglass",
                           title: "No category found",
                           message: "Nothing named anything like that. Try fewer letters.")
                .padding(.top, theme.layout.spacing * 2)
        } else {
            ForEach(matches, id: \.category.id) { match in
                categoryRow(match.category, groupName: match.groupName)
            }
        }
    }

    private var recentChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recentIDs, id: \.self) { id in
                    recentChip(id)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func recentChip(_ id: String) -> some View {
        let isSelected = categoryID == id
        return Button {
            select(id)
        } label: {
            Text(store.categoryName(id))
                .font(theme.font(.subheadline))
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? theme.palette.onAccent : theme.palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? theme.palette.accent : theme.palette.fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Rows

    private var noCategoryRow: some View {
        Button {
            select(nil)
        } label: {
            HStack {
                Image(systemName: "circle.dashed")
                    .font(theme.font(.subheadline))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.textTertiary)
                    .frame(width: 22)
                Text("No Category")
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer()
                if categoryID == nil {
                    checkmark
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(categoryID == nil ? [.isSelected] : [])
    }

    private func categoryRow(_ category: Category, groupName: String? = nil) -> some View {
        Button {
            select(category.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.name)
                        .font(theme.font(.body))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    if let groupName {
                        Text(groupName)
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if categoryID == category.id {
                    checkmark
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(categoryID == category.id ? [.isSelected] : [])
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(theme.font(.headline))
            .fontWeight(theme.icons.weight)
            .foregroundStyle(theme.palette.accent)
    }

    // MARK: Data

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// Visible groups, non-income first (income last mirrors Actual's budget ordering).
    private var orderedGroups: [CategoryGroup] {
        let visible = store.categoryGroups.filter { !$0.hidden }
        return visible.filter { !$0.isIncome } + visible.filter { $0.isIncome }
    }

    private var allVisibleCategories: [Category] {
        orderedGroups.flatMap { $0.categories.filter { !$0.hidden } }
    }

    private var searchMatches: [(category: Category, groupName: String)] {
        let query = trimmedSearch
        guard !query.isEmpty else { return [] }
        var matches: [(category: Category, groupName: String)] = []
        for group in orderedGroups {
            for category in group.categories where !category.hidden {
                if category.name.range(of: query,
                                       options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    matches.append((category: category, groupName: group.name))
                }
            }
        }
        return matches
    }

    private func loadRecents() async {
        guard recentIDs.isEmpty else { return }
        let recents = await store.recentTransactions(limit: 80)
        guard !Task.isCancelled else { return }
        let valid = Set(allVisibleCategories.map(\.id))
        var seen = Set<String>()
        var ids: [String] = []
        for transaction in recents {
            guard let id = transaction.categoryID, valid.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            ids.append(id)
            if ids.count == 8 { break }
        }
        recentIDs = ids
    }

    private func select(_ id: String?) {
        Haptics.tick()
        categoryID = id
        dismiss()
    }
}
