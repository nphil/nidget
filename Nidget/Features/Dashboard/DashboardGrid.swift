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

struct DashboardGrid: View {
    let model: DashboardModel
    let onAddWidget: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var gridSpace
    @State private var draggingID: UUID?

    init(model: DashboardModel, onAddWidget: @escaping () -> Void) {
        self.model = model
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
        }
        .onDrop(of: [.text], delegate: DashboardClearDropDelegate(draggingID: $draggingID))
        .onChange(of: model.isEditing) { _, editing in
            if !editing { draggingID = nil }
        }
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

/// A whole-card tap target with the theme's card treatment and pressed-state feedback.
/// Content expands to fill the tile so the card always matches its grid frame.
struct WidgetCardButton<Content: View>: View {
    private let alignment: Alignment
    private let action: () -> Void
    private let content: () -> Content

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(alignment: Alignment = .topLeading,
         action: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                .themedCard()
                .contentShape(theme.cardShape)
        }
        .buttonStyle(PressableButtonStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
    }
}
