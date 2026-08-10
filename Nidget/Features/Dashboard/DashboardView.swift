import SwiftUI

// MARK: - DashboardView
//
// The Dashboard tab root: a custom header (greeting, month, tiny sync-status dot, pencil edit
// toggle) over the one-screen widget grid. No ScrollView anywhere — the grid fills whatever
// height remains (ARCHITECTURE §12). Owns the tab's NavigationStack so widget deep links
// (accounts, reports) push within this tab.

struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let model = DashboardModel.shared

    @State private var showGallery = false

    init() {}

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.dashboardPath) {
            screenContent
                .withRouteDestinations()
        }
    }

    // MARK: Screen

    private var screenContent: some View {
        VStack(spacing: theme.layout.spacing) {
            header
            if model.items.isEmpty {
                emptyState
            } else {
                DashboardGrid(model: model) { showGallery = true }
            }
        }
        .padding(.horizontal, theme.layout.cardPadding)
        .padding(.bottom, theme.layout.spacing * 0.5)
        .themedScreen()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showGallery) {
            WidgetGallerySheet(model: model)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: theme.layout.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                HStack(spacing: 8) {
                    Text(BudgetMonth.current.displayName)
                        .font(theme.font(.title))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    syncDot
                }
            }
            Spacer(minLength: theme.layout.spacing)
            editButton
        }
        .padding(.top, theme.layout.spacing * 0.5)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Burning the midnight oil"
        }
    }

    // MARK: Sync dot

    private var syncDot: some View {
        Image(systemName: "circle.fill")
            .font(theme.font(.caption))
            .imageScale(.small)
            .foregroundStyle(syncDotColor)
            .symbolEffect(.pulse, options: .repeat(.continuous),
                          isActive: isSyncing && !reduceMotion)
            .animation(reduceMotion ? nil : theme.motion.snappy, value: store.syncStatus)
            .accessibilityLabel(syncAccessibilityLabel)
    }

    private var isSyncing: Bool {
        store.syncStatus == .syncing
    }

    private var syncDotColor: Color {
        switch store.syncStatus {
        case .idle: return theme.palette.positive
        case .syncing: return theme.palette.accent
        case .offline: return theme.palette.warning
        case .error: return theme.palette.negative
        }
    }

    private var syncAccessibilityLabel: String {
        switch store.syncStatus {
        case .idle: return "Synced"
        case .syncing: return "Syncing"
        case .offline(let pending):
            return pending > 0 ? "Offline, \(pending) changes pending" : "Offline"
        case .error: return "Sync error"
        }
    }

    // MARK: Edit button

    private var editButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : theme.motion.spring) {
                model.isEditing.toggle()
            }
        } label: {
            Image(systemName: model.isEditing ? "checkmark" : "pencil")
                .font(theme.font(.headline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(model.isEditing ? theme.palette.onAccent : theme.palette.accent)
                .frame(width: 44, height: 44)
                .background {
                    Circle().fill(model.isEditing
                                  ? AnyShapeStyle(theme.palette.accent)
                                  : AnyShapeStyle(theme.palette.fill))
                }
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableButtonStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
        .accessibilityLabel(model.isEditing ? "Done editing" : "Edit dashboard")
    }

    // MARK: Empty state

    private var emptyState: some View {
        EmptyStateView(systemImage: "square.grid.2x2",
                       title: "A blank slate",
                       message: "This screen is all yours. Add widgets to make it feel like home.",
                       actionTitle: "Add Widgets",
                       action: { showGallery = true })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
