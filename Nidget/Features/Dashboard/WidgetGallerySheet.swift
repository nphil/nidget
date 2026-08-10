import SwiftUI

// MARK: - WidgetGallerySheet
//
// Sheet of widgets not yet on the dashboard, shown from the grid's "+" tile (and the empty
// state). Each card shows the kind's icon, name, two-line description, and available sizes;
// tapping adds it with a success haptic. Cards that no longer fit the 8-cell capacity dim out
// instead of disappearing, so the constraint is visible rather than mysterious. The sheet
// stays open for adding several widgets in one visit.

struct WidgetGallerySheet: View {
    private let model: DashboardModel

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    init(model: DashboardModel) {
        self.model = model
    }

    var body: some View {
        NavigationStack {
            content
                .themedScreen()
                .navigationTitle("Add Widgets")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.unusedKinds.isEmpty {
            EmptyStateView(systemImage: "checkmark.seal",
                           title: "Full house",
                           message: "Every widget is already living on your dashboard.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.layout.spacing) {
                    capacityHeader
                    LazyVGrid(columns: columns, spacing: theme.layout.cardSpacing) {
                        ForEach(model.unusedKinds) { kind in
                            WidgetGalleryCard(kind: kind, canAdd: model.canAdd(kind)) {
                                add(kind)
                            }
                        }
                    }
                }
                .padding(theme.layout.cardPadding)
                .animation(reduceMotion ? nil : theme.motion.spring, value: model.items)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: theme.layout.cardSpacing),
         GridItem(.flexible(), spacing: theme.layout.cardSpacing)]
    }

    private var capacityHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.accent)
            Text(capacityText)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: capacityText)
        }
        .accessibilityElement(children: .combine)
    }

    private var capacityText: String {
        let free = model.remainingCells
        if free == 0 { return "Dashboard is full — remove something to make room" }
        return free == 1 ? "1 cell free of 8" : "\(free) cells free of 8"
    }

    private func add(_ kind: WidgetKind) {
        withAnimation(reduceMotion ? nil : theme.motion.spring) {
            model.add(kind)
        }
        Haptics.success()
    }
}

// MARK: - WidgetGalleryCard

private struct WidgetGalleryCard: View {
    let kind: WidgetKind
    let canAdd: Bool
    let onAdd: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onAdd) {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.6) {
                iconTile
                Text(kind.displayName)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(kind.galleryDescription)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(spanList)
                    .font(theme.font(.label))
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .themedCard()
            .contentShape(theme.cardShape)
        }
        .buttonStyle(PressableButtonStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
        .disabled(!canAdd)
        .opacity(canAdd ? 1 : 0.45)
        .accessibilityLabel("Add \(kind.displayName)")
        .accessibilityHint(canAdd ? kind.galleryDescription : "Not enough room on the dashboard")
    }

    private var iconTile: some View {
        Image(systemName: kind.systemImage)
            .font(theme.font(.title))
            .fontWeight(theme.icons.weight)
            .symbolVariant(theme.icons.fill ? .fill : .none)
            .foregroundStyle(theme.palette.accent)
            .frame(width: 44, height: 44)
            .background {
                theme.controlShape.fill(theme.palette.fill)
            }
            .accessibilityHidden(true)
    }

    private var spanList: String {
        kind.allowedSpans.map(\.displayName).joined(separator: " · ")
    }
}
