import SwiftUI

// MARK: - ManageCategoriesView
//
// Pushed via `Route.manageCategories` (ARCHITECTURE §16) — no NavigationStack of its own; it
// lives inside whichever tab's stack pushed it (Budget today, via the toolbar "Manage" button).
// The full category-management surface: unlike BudgetView (which filters hidden groups/
// categories out of the everyday budgeting list), this screen lists EVERYTHING —
// `BudgetDatabase.categoryGroups()` already returns hidden rows with `hidden: true` — so hidden
// items can be found and un-hidden again. One `List` `Section` per group (non-income groups
// first, then income groups, matching `store.categoryGroups`' own sort order), each section
// header carrying the group's own context menu and each row carrying the category's. Native
// `EditMode` drag-to-reorder (via `.onMove`) is scoped per-section — SwiftUI keeps reordering
// gestures confined to the `ForEach` that owns them, so dragging a category never crosses into
// another group's rows; reordering GROUPS themselves isn't wired into this screen (only
// `AppStore.reorderGroups` exists, for a future affordance) to keep this drag surface to the one
// pattern that's unambiguously supported (per-`ForEach` `.onMove`, not `Section`-level).
//
// Edit mode (the toolbar's Edit button) is where naming lives. The long-press context menus are
// still here and still useful, but nobody finds a long press: with Edit on, every group and
// category row taps straight into its rename sheet, each group grows an "Add category" row, and
// the list ends with "New group". Everything in this screen's job is then visible at once.

struct ManageCategoriesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.editMode) private var editMode

    @State private var categoryEditor: CategoryEditorMode?
    @State private var deleteTarget: Category?

    init() {}

    /// True while the toolbar's Edit button has the list in edit mode.
    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing ?? false
    }

    var body: some View {
        content
            .themedScreen()
            .navigationTitle("Manage Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            .sheet(item: $categoryEditor) { mode in
                CategoryEditorSheet(mode: mode)
            }
            .sheet(item: $deleteTarget) { category in
                DeleteCategorySheet(category: category)
                    .presentationDetents([.height(420), .large])
                    .presentationDragIndicator(.visible)
            }
    }

    // MARK: Screen

    @ViewBuilder
    private var content: some View {
        if store.categoryGroups.isEmpty {
            EmptyStateView(systemImage: "folder.badge.questionmark",
                           title: "No categories yet",
                           message: "Groups hold your categories. Start one here, then fill it with the things you spend on.",
                           actionTitle: "New Group",
                           action: {
                               Haptics.tap()
                               categoryEditor = .newGroup(isIncome: false)
                           })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            categoryList
        }
    }

    private var categoryList: some View {
        List {
            ForEach(nonIncomeGroups) { group in
                groupSection(group)
            }
            ForEach(incomeGroups) { group in
                groupSection(group)
            }
            if isEditing {
                newGroupRow
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await store.syncNow()
        }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 6, leading: theme.layout.cardPadding, bottom: 6, trailing: theme.layout.cardPadding)
    }

    // MARK: Grouping

    private var nonIncomeGroups: [CategoryGroup] {
        store.categoryGroups.filter { !$0.isIncome }
    }

    private var incomeGroups: [CategoryGroup] {
        store.categoryGroups.filter { $0.isIncome }
    }

    /// Groups (other than `group` itself) that share its income-ness — the only legal move
    /// targets, mirroring `AppStore.moveCategory`'s own guard.
    private func otherGroups(for group: CategoryGroup) -> [CategoryGroup] {
        store.categoryGroups.filter { $0.isIncome == group.isIncome && $0.id != group.id }
    }

    // MARK: Section

    @ViewBuilder
    private func groupSection(_ group: CategoryGroup) -> some View {
        Section {
            ForEach(group.categories) { category in
                categoryRow(category, in: group)
            }
            .onMove { source, destination in
                moveCategories(in: group, from: source, to: destination)
            }
            if isEditing {
                addCategoryRow(in: group)
            }
        } header: {
            groupHeader(group)
        }
    }

    /// While editing, the whole header is the rename target. The context menu rides along in both
    /// modes, so nothing anyone already learned stops working.
    private func groupHeader(_ group: CategoryGroup) -> some View {
        Group {
            if isEditing {
                Button {
                    Haptics.tap()
                    categoryEditor = .rename(id: group.id, currentName: group.name, isGroup: true)
                } label: {
                    groupHeaderLabel(group)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Double-tap to rename this group")
            } else {
                groupHeaderLabel(group)
            }
        }
        .contextMenu {
            groupContextMenu(group)
        }
    }

    private func groupHeaderLabel(_ group: CategoryGroup) -> some View {
        SectionHeader(group.name, trailing: { AnyView(groupHeaderTrailing(group)) })
            .padding(.top, theme.layout.spacing * 0.5)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func groupContextMenu(_ group: CategoryGroup) -> some View {
        Button {
            Haptics.tap()
            categoryEditor = .rename(id: group.id, currentName: group.name, isGroup: true)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            Task { await toggleHidden(group) }
        } label: {
            Label(group.hidden ? "Unhide" : "Hide",
                  systemImage: group.hidden ? "eye" : "eye.slash")
        }
        Button(role: .destructive) {
            Task { await deleteGroup(group) }
        } label: {
            Label(group.categories.isEmpty ? "Delete" : "Delete (move categories first)",
                  systemImage: "trash")
        }
        .disabled(!group.categories.isEmpty)
    }

    /// Same story as the header: a tap renames while editing, and outside edit mode the row is
    /// exactly what it was — a plain label with its context menu.
    private func categoryRow(_ category: Category, in group: CategoryGroup) -> some View {
        Group {
            if isEditing {
                Button {
                    Haptics.tap()
                    categoryEditor = .rename(id: category.id,
                                             currentName: category.name,
                                             isGroup: false)
                } label: {
                    categoryRowLabel(category)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Double-tap to rename")
            } else {
                categoryRowLabel(category)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.palette.separator)
        .listRowInsets(rowInsets)
        .contextMenu {
            categoryContextMenu(category, in: group)
        }
    }

    private func categoryRowLabel(_ category: Category) -> some View {
        HStack(spacing: 6) {
            Text(category.name)
                .font(theme.font(.body))
                .foregroundStyle(category.hidden ? theme.palette.textTertiary : theme.palette.textPrimary)
                .lineLimit(1)
            if category.hidden {
                hiddenBadge
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    // MARK: Edit-mode add rows

    /// Inline "Add category" at the bottom of each group while editing. Sits outside the `ForEach`
    /// so it never joins the reorder set.
    private func addCategoryRow(in group: CategoryGroup) -> some View {
        Button {
            Haptics.tap()
            categoryEditor = .newCategory(groupID: group.id)
        } label: {
            editActionLabel("Add category", systemImage: "plus.circle")
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets)
        .accessibilityLabel("Add a category to \(group.name)")
    }

    /// Tail of the list while editing: categories live inside groups, so this is where a new
    /// group comes from.
    private var newGroupRow: some View {
        Button {
            Haptics.tap()
            categoryEditor = .newGroup(isIncome: false)
        } label: {
            editActionLabel("New group", systemImage: "folder.badge.plus")
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets)
        .padding(.top, theme.layout.spacing)
    }

    private func editActionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: theme.layout.spacing * 0.75) {
            Image(systemName: systemImage)
                .font(theme.font(.body))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
            Text(title)
                .font(theme.font(.body))
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.palette.accent)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func categoryContextMenu(_ category: Category, in group: CategoryGroup) -> some View {
        Button {
            Haptics.tap()
            categoryEditor = .rename(id: category.id, currentName: category.name, isGroup: false)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            Task { await toggleHidden(category) }
        } label: {
            Label(category.hidden ? "Unhide" : "Hide",
                  systemImage: category.hidden ? "eye" : "eye.slash")
        }
        let targets = otherGroups(for: group)
        if !targets.isEmpty {
            Menu {
                ForEach(targets) { target in
                    Button(target.name) {
                        Task { await move(category, to: target) }
                    }
                }
            } label: {
                Label("Move to Group…", systemImage: "folder")
            }
        }
        Button(role: .destructive) {
            Haptics.tap()
            deleteTarget = category
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func groupHeaderTrailing(_ group: CategoryGroup) -> some View {
        if group.hidden {
            hiddenBadge
        }
    }

    private var hiddenBadge: some View {
        Image(systemName: "eye.slash")
            .font(theme.font(.caption))
            .fontWeight(theme.icons.weight)
            .symbolVariant(theme.icons.fill ? .fill : .none)
            .foregroundStyle(theme.palette.textTertiary)
            .accessibilityLabel("Hidden")
    }

    // MARK: Mutations (Haptics on every mutation — ARCHITECTURE §15)

    private func toggleHidden(_ category: Category) async {
        Haptics.tick()
        await store.setCategoryHidden(id: category.id, hidden: !category.hidden, isGroup: false)
    }

    private func toggleHidden(_ group: CategoryGroup) async {
        Haptics.tick()
        await store.setCategoryHidden(id: group.id, hidden: !group.hidden, isGroup: true)
    }

    private func move(_ category: Category, to group: CategoryGroup) async {
        Haptics.tick()
        await store.moveCategory(id: category.id, toGroup: group.id)
    }

    private func deleteGroup(_ group: CategoryGroup) async {
        guard group.categories.isEmpty else {
            Haptics.warning()
            return
        }
        Haptics.tick()
        await store.deleteCategoryGroup(id: group.id)
    }

    private func moveCategories(in group: CategoryGroup, from source: IndexSet, to destination: Int) {
        var orderedIDs = group.categories.map(\.id)
        orderedIDs.move(fromOffsets: source, toOffset: destination)
        Haptics.tick()
        Task { await store.reorderCategories(inGroup: group.id, orderedIDs: orderedIDs) }
    }
}
