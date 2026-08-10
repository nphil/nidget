import SwiftUI
import UniformTypeIdentifiers

// MARK: - DashboardGrid
//
// The signature one-screen widget grid (ARCHITECTURE §12). NO ScrollView: a GeometryReader
// measures the available space, spans are first-fit packed into 2 columns, and rows are sized
// to fill the height exactly. Edit mode adds the jiggle wobble, remove / span-cycle badges,
// drag-to-reorder (onDrag + DropDelegate reordering live), and a dashed "+" tile while
// capacity remains. Layout math is pure (computed per body pass, never written to @State on a
// geometry path — LESSONS §1).
//
// Non-edit mode interaction (UX_ROUND2 §5): tiles route their tap-vs-swipe gating and their
// long-press-to-edit gesture through `WidgetCardButton` (bottom of this file, shared by every
// widget) rather than here, since that's the one place that already owns each widget's
// navigation `action`. This grid only supplies the two things WidgetCardButton can't know on
// its own — "enter edit mode" and "how hard the finger is pulling" — via the small environment
// hooks declared below, and separately catches drags that land on the grid background (the gaps
// between tiles, or empty rows) with its own drag gesture. The existing onDrag/onDrop
// reorder-in-edit-mode machinery on `tile(_:staggerIndex:)` is untouched: once `model.isEditing`
// flips true, `.allowsHitTesting(!model.isEditing)` below turns off WidgetCardButton's gestures
// entirely, so the two interaction models never compete for the same touch.
//
// The pull is REPORTED here and RENDERED elsewhere: `pullState` is a small observable box owned
// by DashboardView, written on every drag frame, and read only by `DashboardEdgeGlow` (bottom of
// this file), which DashboardView overlays as a sibling of this grid. Nothing in the grid ever
// reads `pullState.pull`, so a drag never re-evaluates the grid body, a tile, or a widget.

struct DashboardGrid: View {
    let model: DashboardModel
    /// Write-only from this view's side: drags report into it, the glow overlay renders from it.
    let pullState: DashboardPullState
    let onAddWidget: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var gridSpace
    @State private var draggingID: UUID?

    init(model: DashboardModel, pullState: DashboardPullState, onAddWidget: @escaping () -> Void) {
        self.model = model
        self.pullState = pullState
        self.onAddWidget = onAddWidget
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = DashboardGridLayout(
                items: model.items,
                includeAddTile: model.isEditing && model.remainingCells > 0,
                size: proxy.size,
                spacing: theme.layout.cardSpacing)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(backgroundPullGesture)
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    let frame = layout.frames[item.id] ?? .zero
                    tile(item, staggerIndex: index)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                if let addFrame = layout.addTileFrame {
                    addTile
                        .frame(width: addFrame.width, height: addFrame.height)
                        .offset(x: addFrame.minX, y: addFrame.minY)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(reduceMotion ? nil : theme.motion.spring, value: model.items)
            .animation(reduceMotion ? nil : theme.motion.spring, value: model.isEditing)
            .environment(\.dashboardEnterEdit, enterEditMode)
            .environment(\.dashboardPull, reportPull)
        }
        .onDrop(of: [.text], delegate: DashboardClearDropDelegate(draggingID: $draggingID))
        .onChange(of: model.isEditing) { _, editing in
            if !editing { draggingID = nil }
        }
    }

    // MARK: Non-edit-mode interaction

    /// Catches drags that land on the grid background — the gaps between tiles and any empty
    /// rows — rather than on a tile itself. Tiles report their own drags through
    /// `dashboardPull` (WidgetCardButton), so this only needs the "falls on nothing" case.
    private var backgroundPullGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !model.isEditing else { return }
                reportPull(value.translation.height)
            }
            .onEnded { _ in
                reportPull(nil)
            }
    }

    private func enterEditMode() {
        guard !model.isEditing else { return }
        withAnimation(reduceMotion ? nil : theme.motion.spring) {
            model.isEditing = true
        }
    }

    /// The one place a drag turns into glow. `height` is the live vertical translation of a drag
    /// anywhere on the dashboard; `nil` means the finger lifted, which eases the glow back out.
    /// Only `pullState` is touched, so this runs at drag rate without redrawing a single tile.
    private func reportPull(_ height: CGFloat?) {
        guard let height else {
            guard pullState.pull != 0 else { return }
            withAnimation(reduceMotion ? .linear(duration: 0.15) : theme.motion.spring) {
                pullState.pull = 0
            }
            return
        }
        let next = DashboardPullState.resistance(height)
        guard pullState.pull != next else { return }
        pullState.pull = next
    }

    // MARK: Tile

    private func tile(_ item: DashboardItem, staggerIndex: Int) -> some View {
        WidgetTileContent(item: item)
            .allowsHitTesting(!model.isEditing)
            .overlay(alignment: .topLeading) { removeBadge(item) }
            .overlay(alignment: .topTrailing) { spanBadge(item) }
            .modifier(JiggleEffect(isActive: model.isEditing,
                                   phase: Double(staggerIndex % 4) * 0.04))
            .matchedGeometryEffect(id: item.id, in: gridSpace)
            .opacity(draggingID == item.id ? 0.85 : 1)
            .onDrag {
                if !model.isEditing {
                    withAnimation(reduceMotion ? nil : theme.motion.spring) {
                        model.isEditing = true
                    }
                }
                draggingID = item.id
                return NSItemProvider(object: item.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: WidgetTileDropDelegate(
                item: item,
                model: model,
                draggingID: $draggingID,
                animation: reduceMotion ? nil : theme.motion.spring))
    }

    // MARK: Edit badges

    @ViewBuilder
    private func removeBadge(_ item: DashboardItem) -> some View {
        ZStack {
            if model.isEditing {
                Button {
                    Haptics.tap()
                    withAnimation(reduceMotion ? nil : theme.motion.spring) {
                        model.remove(item.id)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(theme.font(.title))
                        .fontWeight(theme.icons.weight)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(theme.palette.onAccent, theme.palette.negative)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.kind.displayName)")
                .offset(x: -8, y: -8)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func spanBadge(_ item: DashboardItem) -> some View {
        ZStack {
            if model.isEditing && item.kind.allowedSpans.count > 1 {
                Button {
                    Haptics.tick()
                    withAnimation(reduceMotion ? nil : theme.motion.spring) {
                        model.cycleSpan(item.id)
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.textPrimary)
                        .padding(7)
                        .background {
                            Circle()
                                .fill(theme.palette.surfaceElevated)
                                .overlay(Circle().strokeBorder(theme.palette.surfaceBorder,
                                                               lineWidth: 1))
                        }
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Resize \(item.kind.displayName), now \(item.span.displayName)")
                .offset(x: 8, y: -8)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
    }

    // MARK: Add tile

    private var addTile: some View {
        Button {
            onAddWidget()
        } label: {
            VStack(spacing: theme.layout.spacing * 0.5) {
                Image(systemName: "plus")
                    .font(theme.font(.title))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.accent)
                Text("Add Widget")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                theme.cardShape
                    .fill(theme.palette.fill)
                    .overlay {
                        theme.cardShape
                            .strokeBorder(theme.palette.surfaceBorder,
                                          style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    }
            }
            .contentShape(theme.cardShape)
        }
        .buttonStyle(PressableButtonStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
        .accessibilityLabel("Add a widget")
    }
}

// MARK: - Layout math
//
// First-fit packing of spans into a 2-column grid. Pass 1 assigns (row, col) origins by
// scanning row-major from the top for every item (so 1x1 widgets backfill holes left by wide
// spans); pass 2 converts to concrete frames with rows sized to divide the available height
// exactly. Pure value math — recomputed per body evaluation, cheap at ≤ 8 items.

private struct DashboardGridLayout {
    private(set) var frames: [UUID: CGRect] = [:]
    private(set) var addTileFrame: CGRect?
    private(set) var rowCount: Int = 0

    private static let columns = 2
    private static let maxSearchRows = 16

    init(items: [DashboardItem], includeAddTile: Bool, size: CGSize, spacing: CGFloat) {
        var occupied: [[Bool]] = []

        func ensureRows(_ count: Int) {
            while occupied.count < count {
                occupied.append([false, false])
            }
        }

        func firstFit(cols: Int, rows: Int) -> (row: Int, col: Int) {
            let width = min(max(cols, 1), Self.columns)
            let height = max(rows, 1)
            for row in 0..<Self.maxSearchRows {
                ensureRows(row + height)
                for col in 0...(Self.columns - width) {
                    var free = true
                    for r in row..<(row + height) where free {
                        for c in col..<(col + width) where occupied[r][c] {
                            free = false
                        }
                    }
                    if free { return (row, col) }
                }
            }
            return (Self.maxSearchRows, 0)
        }

        func place(cols: Int, rows: Int) -> (row: Int, col: Int) {
            let slot = firstFit(cols: cols, rows: rows)
            ensureRows(slot.row + max(rows, 1))
            for r in slot.row..<(slot.row + max(rows, 1)) {
                for c in slot.col..<(slot.col + min(max(cols, 1), Self.columns)) {
                    occupied[r][c] = true
                }
            }
            return slot
        }

        var origins: [(item: DashboardItem, row: Int, col: Int)] = []
        for item in items {
            let slot = place(cols: item.span.cols, rows: item.span.rows)
            origins.append((item, slot.row, slot.col))
        }
        var addOrigin: (row: Int, col: Int)?
        if includeAddTile {
            addOrigin = place(cols: 1, rows: 1)
        }

        var lastOccupiedRow = -1
        for (index, row) in occupied.enumerated() where row[0] || row[1] {
            lastOccupiedRow = index
        }
        rowCount = lastOccupiedRow + 1
        guard rowCount > 0, size.width > 0, size.height > 0 else { return }

        let cellWidth = (size.width - spacing) / CGFloat(Self.columns)
        let rows = CGFloat(rowCount)
        let cellHeight = max((size.height - spacing * (rows - 1)) / rows, 1)

        func frame(row: Int, col: Int, span: WidgetSpan) -> CGRect {
            CGRect(x: CGFloat(col) * (cellWidth + spacing),
                   y: CGFloat(row) * (cellHeight + spacing),
                   width: CGFloat(span.cols) * cellWidth + CGFloat(span.cols - 1) * spacing,
                   height: CGFloat(span.rows) * cellHeight + CGFloat(span.rows - 1) * spacing)
        }

        for entry in origins {
            frames[entry.item.id] = frame(row: entry.row, col: entry.col, span: entry.item.span)
        }
        if let addOrigin {
            addTileFrame = frame(row: addOrigin.row, col: addOrigin.col, span: .s1x1)
        }
    }
}

// MARK: - Jiggle
//
// The edit-mode wobble: ±0.6° alternating every 0.15s (spec'd timing, so not a theme.motion
// curve), staggered slightly per tile, and fully disabled under Reduce Motion.

private struct JiggleEffect: ViewModifier {
    let isActive: Bool
    let phase: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wobble = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onChange(of: isActive) { _, active in
                update(active)
            }
            .onAppear {
                update(isActive)
            }
    }

    private var angle: Double {
        guard isActive, !reduceMotion else { return 0 }
        return wobble ? 0.6 : -0.6
    }

    private func update(_ active: Bool) {
        if active && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.15).repeatForever(autoreverses: true).delay(phase)) {
                wobble = true
            }
        } else {
            // SwiftUI.Transaction spelled out — `Transaction` alone resolves to the domain model.
            var transaction = SwiftUI.Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                wobble = false
            }
        }
    }
}

// MARK: - Drop delegates

/// Per-tile delegate: reorders the model live as the dragged tile hovers over siblings.
private struct WidgetTileDropDelegate: DropDelegate {
    let item: DashboardItem
    let model: DashboardModel
    @Binding var draggingID: UUID?
    let animation: Animation?

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let draggingID, draggingID != item.id else { return }
            withAnimation(animation) {
                model.moveItem(id: draggingID, over: item.id)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            draggingID = nil
        }
        return true
    }
}

/// Grid-level fallback: a drop that lands between tiles still ends the drag session cleanly.
private struct DashboardClearDropDelegate: DropDelegate {
    @Binding var draggingID: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            draggingID = nil
        }
        return true
    }
}

// MARK: - WidgetTileContent
//
// The single WidgetKind → widget-view mapping used by the grid.

struct WidgetTileContent: View {
    let item: DashboardItem

    var body: some View {
        switch item.kind {
        case .toBudget: ToBudgetWidget(span: item.span)
        case .netWorth: NetWorthWidget(span: item.span)
        case .spendingRing: SpendingRingWidget(span: item.span)
        case .accountsList: AccountsListWidget(span: item.span)
        case .recentActivity: RecentActivityWidget(span: item.span)
        case .cashFlow: CashFlowWidget(span: item.span)
        case .savingsRate: SavingsRateWidget(span: item.span)
        case .fiProgress: FIProgressWidget(span: item.span)
        case .monthProgress: MonthProgressWidget(span: item.span)
        case .spendHeatmap: SpendHeatmapWidget(span: item.span)
        case .quickAdd: QuickAddWidget(span: item.span)
        case .topCategories: TopCategoriesWidget(span: item.span)
        }
    }
}

// MARK: - Shared widget scaffolding

/// Small themed label used as the title of every widget card.
struct WidgetLabel: View {
    private let text: String

    @Environment(\.theme) private var theme

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - Dashboard interaction environment hooks
//
// WidgetCardButton (below) needs two things it doesn't own: a way to enter edit mode on a long
// press, and a way to report how far the finger has travelled so the edge glow can follow it.
// Every widget file keeps calling `WidgetCardButton(action:) { … }` exactly as before —
// DashboardGrid injects the real closures on the grid; anywhere else (there is nowhere else
// today) they're harmlessly nil and WidgetCardButton just does nothing extra.

private struct DashboardEnterEditKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
private struct DashboardPullKey: EnvironmentKey {
    /// Live vertical drag translation in points; `nil` when the finger lifts.
    static let defaultValue: ((CGFloat?) -> Void)? = nil
}
private extension EnvironmentValues {
    var dashboardEnterEdit: (() -> Void)? {
        get { self[DashboardEnterEditKey.self] }
        set { self[DashboardEnterEditKey.self] = newValue }
    }
    var dashboardPull: ((CGFloat?) -> Void)? {
        get { self[DashboardPullKey.self] }
        set { self[DashboardPullKey.self] = newValue }
    }
}

// MARK: - Edge glow
//
// The dashboard doesn't scroll, by design. Rather than ignore a drag, it answers one: a soft
// accent bloom swells at whichever edge you're pulling away from, follows the finger while it
// moves, and eases back out when you let go. Ported from the owner's kobold app, which reads the
// pressure through UIKit's own rubber-band curve so the resistance feels like the platform.
//
// Two deliberate differences from kobold: the pressure lives in this small observable box instead
// of on the dashboard view itself (there, every drag frame re-evaluates the whole dashboard body;
// here only `DashboardEdgeGlow` reads `pull`, so the widget grid never sees a drag), and
// DashboardGrid skips writes that wouldn't change the value, so a plain tap costs nothing.

/// Signed overscroll pressure, −1…1. Positive means pulling down.
@MainActor @Observable
final class DashboardPullState {
    var pull: CGFloat = 0

    /// Maps raw drag distance onto glow intensity with UIKit's rubber-band curve,
    /// `b(x) = (x·d·c) / (d + c·x)`. `b/d` is already normalised to 0…1 and saturates, so pulling
    /// harder always gives a little more and never runs away. UIScrollView uses c = 0.55 over a
    /// whole screen height; a short travel budget wants a stiffer constant or the glow barely
    /// registers before the gesture ends.
    static func resistance(_ translation: CGFloat) -> CGFloat {
        let distance = abs(Double(translation))
        let travel: Double = 110      // d — how far a full-strength pull is
        let stiffness: Double = 0.32  // c
        let banded = (distance * travel * stiffness) / (travel + stiffness * distance)
        let intensity = banded / travel
        return CGFloat(translation < 0 ? -intensity : intensity)
    }
}

/// The bands themselves. Overlaid on the whole dashboard screen (a sibling of the grid, never an
/// ancestor of it) so they sit at the true top and bottom edges, over the themed backdrop.
///
/// Shown under Reduce Motion too: this is feedback for a gesture the finger is making, not
/// decoration that moves on its own. Only the release easing changes (DashboardGrid.reportPull).
struct DashboardEdgeGlow: View {
    let state: DashboardPullState

    @Environment(\.theme) private var theme

    var body: some View {
        let pull = state.pull
        VStack(spacing: 0) {
            LinearGradient(colors: [theme.palette.accent.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .opacity(Double(max(0, pull)))

            Spacer(minLength: 0)

            LinearGradient(colors: [.clear, theme.palette.accent.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .opacity(Double(max(0, -pull)))
        }
        // Flattened to a single composited layer, and only its opacity animates. A `.shadow`
        // would re-rasterise a blurred alpha mask on every change instead.
        .drawingGroup()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // Decorative: it says nothing VoiceOver users need, and announcing it would interrupt
        // the values they're actually there for.
        .accessibilityHidden(true)
    }
}

// MARK: - Shared edit/swipe gestures for multi-target widgets
//
// AccountsListWidget's larger spans (s2x1/s2x2) list several independently-navigable account
// rows rather than the single whole-card `action` every other widget hands to WidgetCardButton,
// so it can't just wrap itself in one WidgetCardButton. This pulls WidgetCardButton's long-
// press-to-edit and pull-reporting halves (not its tap gating, which assumes exactly one action)
// into a reusable modifier so a widget like that still participates in the same long-press/drag
// language as every WidgetCardButton-backed tile.

extension View {
    /// Long-press-to-edit + edge-glow pull reporting, without a whole-card tap action. Attach to
    /// a widget's own outer container when it hosts multiple internal tap targets of its own
    /// instead of routing through `WidgetCardButton`.
    func widgetCardEditGestures() -> some View {
        modifier(WidgetCardEditGestureModifier())
    }
}

private struct WidgetCardEditGestureModifier: ViewModifier {
    @Environment(\.dashboardEnterEdit) private var enterEdit
    @Environment(\.dashboardPull) private var reportPull

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(pullGesture)
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 10) {
                Haptics.tap()
                enterEdit?()
            }
    }

    /// Simultaneous, so the account rows underneath keep their own taps.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                reportPull?(value.translation.height)
            }
            .onEnded { _ in
                reportPull?(nil)
            }
    }
}

/// A whole-card tap target with the theme's card treatment and pressed-state feedback.
/// Content expands to fill the tile so the card always matches its grid frame.
///
/// Non-edit-mode interaction (UX_ROUND2 §5) lives here rather than in DashboardGrid because this
/// is the one place that already owns each widget's navigation `action`. A plain `Button` would
/// fire on release-within-bounds no matter how far the finger travelled first, so this replaces
/// that with a `DragGesture(minimumDistance: 0)`: navigation only fires for a quick, nearly-still
/// touch (< 10pt movement, < 0.4s), the press-down scale only appears after an ~80ms hold (so a
/// fast swipe never flashes the tile), and the drag's vertical travel is reported upward the
/// whole time so the edge glow can follow a finger that started on a tile. A
/// `.onLongPressGesture` runs alongside it (`.simultaneousGesture` keeps the two from blocking
/// each other) to enter edit mode. Once edit mode is on, DashboardGrid disables hit testing on
/// this view entirely, so none of this can fire during a drag-to-reorder.
struct WidgetCardButton<Content: View>: View {
    private let alignment: Alignment
    private let action: () -> Void
    private let content: () -> Content

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dashboardEnterEdit) private var enterEdit
    @Environment(\.dashboardPull) private var reportPull

    @State private var isPressed = false
    @State private var pressStart: Date?
    @State private var pressToken = UUID()

    init(alignment: Alignment = .topLeading,
         action: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment
        self.action = action
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .themedCard()
            .contentShape(theme.cardShape)
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : theme.motion.snappy, value: isPressed)
            .simultaneousGesture(tapSwipeGesture)
            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 10) {
                Haptics.tap()
                enterEdit?()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    // MARK: Tap vs swipe

    private var tapSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStart == nil {
                    pressStart = Date()
                    schedulePressVisual()
                }
                reportPull?(value.translation.height)
            }
            .onEnded { value in
                let duration = pressStart.map { Date().timeIntervalSince($0) } ?? 0
                pressStart = nil
                isPressed = false
                reportPull?(nil)
                let translation = value.translation
                let magnitude = (translation.width * translation.width
                                  + translation.height * translation.height).squareRoot()
                if magnitude < 10, duration < 0.4 {
                    Haptics.tap()
                    action()
                }
            }
    }

    /// Delays the press-down scale by ~80ms so a fast swipe passes straight through without a
    /// flash; guarded by a fresh token each press so a swipe that ends before the delay elapses
    /// (`pressStart` already back to nil) can't have the visual land late.
    private func schedulePressVisual() {
        let token = UUID()
        pressToken = token
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, pressToken == token, pressStart != nil else { return }
            isPressed = true
        }
    }
}
