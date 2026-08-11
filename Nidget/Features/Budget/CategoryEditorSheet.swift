import SwiftUI

// Naming sheet for creating a category (optionally choosing its group) or a category group, and
// for renaming either. Kept deliberately small: one text field, one optional group picker, save.
//
// Categories also carry an icon, chosen from the circular button beside the name field
// (`IconPickerSheet`). Groups don't: a group is a heading, not an envelope. While a NEW category
// is being named the icon follows what's being typed (`CategoryIconCatalog.suggested`), so
// "Groceries" lights up a shopping cart on its own — but the moment the user picks one by hand
// that guessing stops for good, because a deliberate choice must never be overwritten.
// Icons are local-only and are written through `Preferences`, never through a store mutation:
// Actual's server has no icon column to sync them to.

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
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var name: String = ""
    @State private var selectedGroupID: String = ""
    @State private var isSaving = false
    @State private var icon: String?
    @State private var hasManuallyPickedIcon = false
    @State private var showingIconPicker = false
    @FocusState private var nameFocused: Bool

    private var spendingGroups: [CategoryGroup] {
        store.categoryGroups.filter { !$0.isIncome && !$0.hidden }
    }

    private var needsGroupPicker: Bool {
        if case .newCategory(let groupID) = mode { return groupID == nil }
        return false
    }

    /// Groups are headings, not envelopes, so only categories get an icon.
    private var isCategory: Bool {
        switch mode {
        case .newCategory: return true
        case .newGroup: return false
        case .rename(_, _, let isGroup): return !isGroup
        }
    }

    /// Only a brand-new category guesses its icon from what's being typed.
    private var seedsIconFromName: Bool {
        if case .newCategory = mode { return true }
        return false
    }

    /// Picking (or clearing) an icon by hand also stops the name from guessing again.
    private var iconBinding: Binding<String?> {
        Binding(get: { icon },
                set: { newValue in
                    icon = newValue
                    hasManuallyPickedIcon = true
                })
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return false }
        return !needsGroupPicker || !selectedGroupID.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                HStack(alignment: .center, spacing: theme.layout.spacing * 0.75) {
                    if isCategory {
                        iconButton
                    }
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
                }
                .themedCard()

                if needsGroupPicker {
                    VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
                        SectionHeader("Group")
                        if spendingGroups.isEmpty {
                            Text("Make a group first. Categories live inside groups.")
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
        .presentationDetents([.height(detentHeight)])
        .sheet(isPresented: $showingIconPicker) {
            IconPickerSheet(symbol: iconBinding, categoryName: trimmedName)
        }
        .onChange(of: name) { _, newValue in
            guard seedsIconFromName, !hasManuallyPickedIcon else { return }
            icon = CategoryIconCatalog.suggested(forCategoryName: newValue)
        }
        .onAppear {
            if case .rename(let id, let currentName, let isGroup) = mode {
                name = currentName
                if !isGroup {
                    icon = preferences.icon(forCategory: id)
                    // An icon already chosen for this category is a deliberate one; renaming
                    // must not quietly swap it for a guess.
                    hasManuallyPickedIcon = true
                }
            } else if name.isEmpty {
                name = initialName
            }
            if seedsIconFromName, !hasManuallyPickedIcon, !name.isEmpty {
                icon = CategoryIconCatalog.suggested(forCategoryName: name)
            }
            if case .newCategory(let groupID) = mode, let groupID { selectedGroupID = groupID }
            if selectedGroupID.isEmpty { selectedGroupID = spendingGroups.first?.id ?? "" }
            nameFocused = true
        }
    }

    /// Snug heights: the icon button makes the name card a touch taller, and only categories
    /// have one.
    private var detentHeight: CGFloat {
        if needsGroupPicker { return 460 }
        return isCategory ? 340 : 300
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Icon

    private var iconButton: some View {
        Button {
            Haptics.tap()
            nameFocused = false
            showingIconPicker = true
        } label: {
            Image(systemName: icon ?? CategoryIconCatalog.fallback)
                .font(theme.font(.title))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(icon == nil ? theme.palette.textTertiary : theme.palette.accent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56, height: 56)
                .background {
                    Circle()
                        .fill(theme.palette.fill)
                        .overlay {
                            if icon != nil {
                                Circle().strokeBorder(theme.palette.accent, lineWidth: 1.5)
                            }
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : theme.motion.snappy, value: icon)
        .accessibilityLabel(iconAccessibilityLabel)
        .accessibilityHint("Double-tap to choose an icon")
    }

    private var iconAccessibilityLabel: String {
        guard let icon else { return "No icon" }
        return "Icon: \(CategoryIconCatalog.label(for: icon))"
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
            guard let id else { return }   // failure surfaced via the global error toast
            // Icons are keyed by category id, so this can only happen once the id exists.
            preferences.setIcon(icon, forCategory: id)
            Haptics.success()
            onCreated?(id)
        case .newGroup(let isIncome):
            guard await store.createCategoryGroup(name: name, isIncome: isIncome) != nil else { return }
            Haptics.success()
            onCreated?(nil)
        case .rename(let id, _, let isGroup):
            await store.renameCategory(id: id, to: name, isGroup: isGroup)
            if !isGroup { preferences.setIcon(icon, forCategory: id) }
            Haptics.success()
            onCreated?(nil)
        }
        dismiss()
    }
}
