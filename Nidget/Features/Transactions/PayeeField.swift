import SwiftUI

// MARK: - PayeeField
//
// Reusable payee entry shared by Quick Add and the transaction editor: a themed text field plus
// a horizontal row of live suggestion chips from `AppStore.suggestions` (top recents when the
// field is empty). Picking a chip binds the payee id; free-typed text leaves `payeeID` nil so
// the caller routes it through `TransactionDraft.newPayeeName`. `onSuggestionPicked` lets Quick
// Add auto-fill the category from the payee's usual one.

struct PayeeField: View {
    @Binding private var text: String
    @Binding private var payeeID: String?
    private let onSuggestionPicked: ((PayeeSuggestion) -> Void)?

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var suggestions: [PayeeSuggestion] = []
    @FocusState private var isFocused: Bool

    init(text: Binding<String>, payeeID: Binding<String?>,
         onSuggestionPicked: ((PayeeSuggestion) -> Void)? = nil) {
        self._text = text
        self._payeeID = payeeID
        self.onSuggestionPicked = onSuggestionPicked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
            field
            if !suggestions.isEmpty {
                chipsHeader
                chipsRow
            }
        }
        .task(id: text) {
            // Small debounce while typing; instant for the initial recents load.
            if !text.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            let result = await store.suggestions(for: PayeeSuggestionQuery(prefix: text, limit: 8))
            guard !Task.isCancelled else { return }
            suggestions = result
        }
        .onChange(of: text) { _, newValue in
            // Typing over a picked payee reverts to "new payee" mode.
            if let id = payeeID, store.payeeName(id) != newValue {
                payeeID = nil
            }
        }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(theme.font(.body))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.textTertiary)
            TextField("Payee", text: $text)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .focused($isFocused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
            if !text.isEmpty {
                Button {
                    text = ""
                    payeeID = nil
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
                .accessibilityLabel("Clear payee")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(theme.controlShape.fill(theme.palette.fill))
    }

    // MARK: Suggestion chips

    // The chips used to sit bare under the field, which read as a mystery row of names and
    // numbers rather than as something to tap. The label says what they are and changes with the
    // field so it stays honest: recents when nothing is typed, matches once you start.
    private var chipsHeader: some View {
        Text(text.isEmpty ? "Recent payees" : "Matching payees")
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textTertiary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    chip(suggestion)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ suggestion: PayeeSuggestion) -> some View {
        let isSelected = payeeID != nil && payeeID == suggestion.payeeID
        return Button {
            pick(suggestion)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.name)
                    .font(theme.font(.subheadline))
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let last = suggestion.lastAmount {
                        AmountText(last, style: .caption, colorized: false)
                    }
                    if let autoCategory = suggestion.categoryID {
                        let name = store.categoryName(autoCategory)
                        if !name.isEmpty {
                            Text(name)
                                .font(theme.font(.caption))
                                .foregroundStyle(theme.palette.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 44)
            .background {
                theme.controlShape.fill(theme.palette.fill)
                    .overlay {
                        if isSelected {
                            theme.controlShape.strokeBorder(theme.palette.accent, lineWidth: 1.5)
                        }
                    }
            }
            .contentShape(theme.controlShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Payee \(suggestion.name)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func pick(_ suggestion: PayeeSuggestion) {
        Haptics.tick()
        isFocused = false
        if reduceMotion {
            text = suggestion.name
            payeeID = suggestion.payeeID
        } else {
            withAnimation(theme.motion.snappy) {
                text = suggestion.name
                payeeID = suggestion.payeeID
            }
        }
        onSuggestionPicked?(suggestion)
    }
}
