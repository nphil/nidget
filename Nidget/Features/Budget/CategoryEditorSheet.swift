import SwiftUI

// Naming sheet for creating a category (optionally choosing its group) or a category group, and
// for renaming either. Kept deliberately small: one text field, one optional group picker, save.

enum CategoryEditorMode: Equatable, Identifiable {
    /// Stable identity so the sheet can be routed with `.sheet(item:)`.
    var id: String {
        switch self {
        case .newCategory(let groupID): return "new-category-\(groupID ?? "any")"
        case .newGroup(let isIncome): return "new-group-\(isIncome)"
        case .rename(let id, _, _): return "rename-\(id)"
        }
    }

    /// Create a category. When `groupID` is nil the sheet shows a group picker.
    case newCategory(groupID: String?)
    /// Create a spending or income group.
    case newGroup(isIncome: Bool)
    /// Rename an existing category or group.
    case rename(id: String, currentName: String, isGroup: Bool)

    var title: String {
        switch self {
        case .newCategory: return "New Category"
        case .newGroup(let isIncome): return isIncome ? "New Income Group" : "New Group"
        case .rename(_, _, let isGroup): return isGroup ? "Rename Group" : "Rename Category"
        }
    }

    var actionTitle: String {
        if case .rename = self { return "Save" }
        return "Create"
    }
}

struct CategoryEditorSheet: View {
    let mode: CategoryEditorMode
    /// Seeds the name field — lets the category picker carry over whatever the user already typed.
    var initialName: String = ""
    /// Called with the resulting category id when a category was created (nil otherwise), so a
    /// caller like the picker can immediately select what the user just made.
    var onCreated: ((String?) -> Void)? = nil

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var name: String = ""
    @State private var selectedGroupID: String = ""
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    private var spendingGroups: [CategoryGroup] {
        store.categoryGroups.filter { !$0.isIncome && !$0.hidden }
    }

    private var needsGroupPicker: Bool {
        if case .newCategory(let groupID) = mode { return groupID == nil }
        return false
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return false }
        return !needsGroupPicker || !selectedGroupID.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
                    SectionHeader("Name")
                    TextField("e.g. Groceries", text: $name)
                        .font(theme.font(.title))
                        .foregroundStyle(theme.palette.textPrimary)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit { if canSave { Task { await save() } } }
                }
                .themedCard()

                if needsGroupPicker {
                    VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
                        SectionHeader("Group")
                        if spendingGroups.isEmpty {
                            Text("Create a group first — categories live inside groups.")
                                .font(theme.font(.caption))
                                .foregroundStyle(theme.palette.textSecondary)
                        } else {
                            ChipPicker(items: spendingGroups.map(\.id),
                                       selection: $selectedGroupID,
                                       label: { id in
                                           spendingGroups.first(where: { $0.id == id })?.name ?? ""
                                       })
                        }
                    }
                    .themedCard()
                }

                NidgetButton(mode.actionTitle, systemImage: isSaving ? nil : "checkmark") {
                    Task { await save() }
                }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
                .animation(reduceMotion ? nil : theme.motion.snappy, value: canSave)

                Spacer(minLength: 0)
            }
            .padding(theme.layout.spacing)
            .themedScreen()
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .presentationDetents([.height(needsGroupPicker ? 420 : 300)])
        .onAppear {
            if case .rename(_, let currentName, _) = mode {
                name = currentName
            } else if name.isEmpty {
                name = initialName
            }
            if case .newCategory(let groupID) = mode, let groupID { selectedGroupID = groupID }
            if selectedGroupID.isEmpty { selectedGroupID = spendingGroups.first?.id ?? "" }
            nameFocused = true
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }

        switch mode {
        case .newCategory(let groupID):
            let target = groupID ?? selectedGroupID
            guard !target.isEmpty else { return }
            let id = await store.createCategory(name: name, groupID: target)
            guard id != nil else { return }   // failure surfaced via the global error toast
            Haptics.success()
            onCreated?(id)
        case .newGroup(let isIncome):
            guard await store.createCategoryGroup(name: name, isIncome: isIncome) != nil else { return }
            Haptics.success()
            onCreated?(nil)
        case .rename(let id, _, let isGroup):
            await store.renameCategory(id: id, to: name, isGroup: isGroup)
            Haptics.success()
            onCreated?(nil)
        }
        dismiss()
    }
}
