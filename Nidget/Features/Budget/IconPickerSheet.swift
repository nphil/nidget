import SwiftUI

// MARK: - IconPickerSheet
//
// The grid a category's icon is chosen from (CategoryIconCatalog). Search at the top, a "No icon"
// row under it so a choice can always be taken back, then either the catalog's named sections or
// one flat list of results. Picking ticks, writes the binding, and closes: choosing an icon is a
// one-tap job, not a form to fill in.
//
// LazyVStack of LazyVGrids on purpose — a couple of hundred tiles only get built as they scroll
// into view — and nothing here reads geometry or watches scroll position (LESSONS_FROM_STASHY §1:
// never touch the scroll hot path). Symbols are drawn exactly as the catalog names them, with no
// `.symbolVariant` applied, so what the grid shows is precisely what gets stored.

struct IconPickerSheet: View {
    @Binding var symbol: String?
    /// Shown as the title so it's obvious which envelope is being decorated.
    var categoryName: String = ""

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [String] {
        CategoryIconCatalog.search(trimmedQuery)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
                searchField
                clearRow
                content
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .themedScreen()
            .navigationTitle(categoryName.isEmpty ? "Icon" : categoryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(theme.font(.body))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(theme.palette.textTertiary)
            TextField("Search icons", text: $query)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
            if !query.isEmpty {
                Button {
                    query = ""
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
    }

    private var clearRow: some View {
        Button {
            pick(nil)
        } label: {
            HStack(spacing: theme.layout.spacing * 0.75) {
                Image(systemName: "slash.circle")
                    .font(theme.font(.body))
                    .fontWeight(theme.icons.weight)
                    .frame(width: 28)
                Text("No icon")
                    .font(theme.font(.body))
                Spacer(minLength: 0)
                if symbol == nil {
                    Image(systemName: "checkmark")
                        .font(theme.font(.subheadline))
                        .fontWeight(theme.icons.weight)
                }
            }
            .foregroundStyle(symbol == nil ? theme.palette.accent : theme.palette.textSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("No icon")
        .accessibilityAddTraits(symbol == nil ? [.isSelected] : [])
    }

    // MARK: Grid

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if trimmedQuery.isEmpty {
                    ForEach(CategoryIconCatalog.sections) { section in
                        header(section.title)
                        gridRows(section.symbols)
                    }
                } else if results.isEmpty {
                    emptyResults
                } else {
                    header("Results")
                    gridRows(results)
                }
            }
            .padding(.bottom, theme.layout.spacing * 2)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    private func gridRows(_ symbols: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(symbols, id: \.self) { candidate in
                tile(candidate)
            }
        }
    }

    private func header(_ title: String) -> some View {
        SectionHeader(title)
            .padding(.top, theme.layout.spacing * 0.75)
            .padding(.bottom, theme.layout.spacing * 0.5)
    }

    private var emptyResults: some View {
        Text("Nothing matches that. Try a plainer word, like food or car.")
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, theme.layout.spacing)
    }

    // MARK: Tiles

    private func tile(_ candidate: String) -> some View {
        let isSelected = candidate == symbol
        return Button {
            pick(candidate)
        } label: {
            Image(systemName: candidate)
                .font(theme.font(.title))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(isSelected ? theme.palette.accent : theme.palette.textSecondary)
                .frame(width: 52, height: 52)
                .background {
                    theme.controlShape
                        .fill(isSelected ? theme.palette.accent.opacity(0.16) : theme.palette.fill)
                        .overlay {
                            if isSelected {
                                theme.controlShape
                                    .strokeBorder(theme.palette.accent, lineWidth: 1.5)
                            }
                        }
                }
                .contentShape(theme.controlShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CategoryIconCatalog.label(for: candidate))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func pick(_ candidate: String?) {
        Haptics.tick()
        symbol = candidate
        dismiss()
    }
}
