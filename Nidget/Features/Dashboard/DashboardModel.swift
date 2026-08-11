import Foundation
import Observation
import os

// MARK: - WidgetKind
//
// Every widget the dashboard can host (ARCHITECTURE §12). The raw value is the persistence
// key, so cases must never be renamed once shipped.

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case toBudget, netWorth, spendingRing, accountsList, recentActivity, cashFlow,
         savingsRate, fiProgress, monthProgress, spendHeatmap, quickAdd, topCategories,
         needsReview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toBudget: return "To Budget"
        case .netWorth: return "Net Worth"
        case .spendingRing: return "Spending Ring"
        case .accountsList: return "Accounts"
        case .recentActivity: return "Recent Activity"
        case .cashFlow: return "Cash Flow"
        case .savingsRate: return "Savings Rate"
        case .fiProgress: return "FI Progress"
        case .monthProgress: return "Month Progress"
        case .spendHeatmap: return "Spend Heatmap"
        case .quickAdd: return "Quick Add"
        case .topCategories: return "Top Categories"
        case .needsReview: return "Needs Review"
        }
    }

    var systemImage: String {
        switch self {
        case .toBudget: return "envelope.open"
        case .netWorth: return "chart.line.uptrend.xyaxis"
        case .spendingRing: return "chart.pie"
        case .accountsList: return "building.columns"
        case .recentActivity: return "clock"
        case .cashFlow: return "arrow.up.arrow.down"
        case .savingsRate: return "percent"
        case .fiProgress: return "flag"
        case .monthProgress: return "calendar.badge.clock"
        case .spendHeatmap: return "square.grid.3x3"
        case .quickAdd: return "plus.circle"
        case .topCategories: return "chart.bar"
        case .needsReview: return "tray.full"
        }
    }

    /// Spans this widget can be cycled through, smallest first.
    var allowedSpans: [WidgetSpan] {
        switch self {
        case .toBudget: return [.s1x1, .s2x1]
        case .netWorth: return [.s1x1, .s2x1, .s2x2]
        case .spendingRing: return [.s1x1, .s2x1]
        case .accountsList: return [.s1x1, .s2x1, .s2x2]
        case .recentActivity: return [.s2x1, .s2x2]
        case .cashFlow: return [.s1x1, .s2x1]
        case .savingsRate: return [.s1x1, .s2x1]
        case .fiProgress: return [.s1x1, .s2x1]
        case .monthProgress: return [.s1x1, .s2x1]
        case .spendHeatmap: return [.s2x1, .s2x2]
        case .quickAdd: return [.s1x1]
        case .topCategories: return [.s1x1, .s2x1, .s2x2]
        case .needsReview: return [.s1x1, .s2x1]
        }
    }

    var defaultSpan: WidgetSpan {
        switch self {
        case .toBudget: return .s1x1
        case .netWorth: return .s2x1
        case .spendingRing: return .s1x1
        case .accountsList: return .s2x1
        case .recentActivity: return .s2x2
        case .cashFlow: return .s2x1
        case .savingsRate: return .s1x1
        case .fiProgress: return .s1x1
        case .monthProgress: return .s1x1
        case .spendHeatmap: return .s2x1
        case .quickAdd: return .s1x1
        case .topCategories: return .s2x1
        case .needsReview: return .s1x1
        }
    }

    /// Two-line personality blurb shown on the widget gallery card.
    var galleryDescription: String {
        switch self {
        case .toBudget:
            return "The money still waiting for a job this month. Green means breathing room."
        case .netWorth:
            return "A year of net worth in one sparkline, with the swing since last year."
        case .spendingRing:
            return "How much of this month's budget you've already spent, at a glance."
        case .accountsList:
            return "Your biggest balances, ready to tap straight into any account."
        case .recentActivity:
            return "The last few transactions as they happen — your ledger's pulse."
        case .cashFlow:
            return "Money in versus money out for the last three months, side by side."
        case .savingsRate:
            return "The slice of this month's income you kept instead of spent."
        case .fiProgress:
            return "How far along the road to financial independence you've traveled."
        case .monthProgress:
            return "Where you are in the month, and whether spending is keeping pace."
        case .spendHeatmap:
            return "A dot for every day this month, glowing brighter where money moved."
        case .quickAdd:
            return "A big friendly button that drops you straight into the amount keypad."
        case .topCategories:
            return "Your hungriest categories this month, ranked with little bars."
        case .needsReview:
            return "How many transactions your bank sent over that still need a category."
        }
    }
}

// MARK: - WidgetSpan
//
// Grid footprint of a widget in the 2-column dashboard.

enum WidgetSpan: String, Codable, CaseIterable {
    case s1x1, s2x1, s2x2

    var cols: Int {
        switch self {
        case .s1x1: return 1
        case .s2x1, .s2x2: return 2
        }
    }

    var rows: Int {
        switch self {
        case .s1x1, .s2x1: return 1
        case .s2x2: return 2
        }
    }

    /// Grid cells this span occupies (cols × rows).
    var cellCount: Int { cols * rows }

    var displayName: String {
        switch self {
        case .s1x1: return "1×1"
        case .s2x1: return "2×1"
        case .s2x2: return "2×2"
        }
    }
}

// MARK: - DashboardItem

struct DashboardItem: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: WidgetKind
    var span: WidgetSpan
}

/// Element wrapper that swallows a single item's decode failure (e.g. a widget kind added in a
/// newer app version) so one unrecognized entry doesn't wipe the whole stored layout.
private struct LenientDashboardItem: Decodable {
    let item: DashboardItem?
    init(from decoder: Decoder) {
        item = try? DashboardItem(from: decoder)
    }
}

// MARK: - DashboardModel
//
// Owns the widget layout: ordering, spans, edit mode, and persistence to
// `Preferences.dashboardLayoutJSON` (ARCHITECTURE §12). Capacity is 8 grid cells — 2 columns
// × max 4 rows — enforced on every add/cycle so the one-screen, no-scroll promise holds.
// Shared so Settings can deep-link into edit mode (`DashboardModel.shared.isEditing = true`).

@MainActor @Observable
final class DashboardModel {

    static let shared = DashboardModel()

    /// 2 columns × 4 rows.
    static let capacity = 8

    private static let log = Logger(subsystem: "app.nidget", category: "dashboard")

    /// The layout, in packing order. Every change persists immediately.
    var items: [DashboardItem] {
        didSet { persist() }
    }

    var isEditing: Bool = false

    /// The out-of-the-box dashboard: exactly 8 cells / 4 rows.
    static let defaultLayout: [DashboardItem] = [
        DashboardItem(id: UUID(), kind: .toBudget, span: .s1x1),
        DashboardItem(id: UUID(), kind: .spendingRing, span: .s1x1),
        DashboardItem(id: UUID(), kind: .netWorth, span: .s2x1),
        DashboardItem(id: UUID(), kind: .recentActivity, span: .s2x1),
        DashboardItem(id: UUID(), kind: .quickAdd, span: .s1x1),
        DashboardItem(id: UUID(), kind: .savingsRate, span: .s1x1),
    ]

    init() {
        items = Self.loadStoredItems()
    }

    // MARK: Capacity

    var usedCells: Int {
        items.reduce(0) { $0 + $1.span.cellCount }
    }

    var remainingCells: Int {
        max(Self.capacity - usedCells, 0)
    }

    /// True when the kind fits in the remaining cells at its default span, or failing that at
    /// any of its allowed spans.
    func canAdd(_ kind: WidgetKind) -> Bool {
        bestSpan(for: kind) != nil
    }

    private func bestSpan(for kind: WidgetKind) -> WidgetSpan? {
        let free = remainingCells
        if kind.defaultSpan.cellCount <= free { return kind.defaultSpan }
        return kind.allowedSpans
            .filter { $0.cellCount <= free }
            .max { $0.cellCount < $1.cellCount }
    }

    // MARK: Mutations

    /// Widgets not currently on the dashboard, in canonical order (gallery source).
    var unusedKinds: [WidgetKind] {
        let used = Set(items.map(\.kind))
        return WidgetKind.allCases.filter { !used.contains($0) }
    }

    func add(_ kind: WidgetKind) {
        guard !items.contains(where: { $0.kind == kind }),
              let span = bestSpan(for: kind) else { return }
        items.append(DashboardItem(id: UUID(), kind: kind, span: span))
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if items.isEmpty {
            isEditing = false
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// Drag-reorder helper: moves the dragged item to the position of the tile it hovers over.
    func moveItem(id draggedID: UUID, over targetID: UUID) {
        guard draggedID != targetID,
              let from = items.firstIndex(where: { $0.id == draggedID }),
              let to = items.firstIndex(where: { $0.id == targetID }) else { return }
        move(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }

    /// Advances the item to its kind's next allowed span that still fits the 8-cell capacity.
    func cycleSpan(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        let spans = item.kind.allowedSpans
        guard spans.count > 1, let current = spans.firstIndex(of: item.span) else { return }
        let otherCells = usedCells - item.span.cellCount
        for step in 1..<spans.count {
            let candidate = spans[(current + step) % spans.count]
            if candidate != item.span, otherCells + candidate.cellCount <= Self.capacity {
                items[index].span = candidate
                return
            }
        }
    }

    // MARK: Persistence

    private static func loadStoredItems() -> [DashboardItem] {
        let json = Preferences.shared.dashboardLayoutJSON
        guard !json.isEmpty, let data = json.data(using: .utf8) else {
            return defaultLayout
        }
        do {
            let decoded = try JSONDecoder().decode([LenientDashboardItem].self, from: data)
            let items = decoded.compactMap(\.item)
            if items.count < decoded.count {
                log.notice("Dropped \(decoded.count - items.count) unrecognized stored dashboard item(s)")
            }
            if items.isEmpty, !decoded.isEmpty {
                // Every stored item was unrecognized — treat it like a failed decode, not an
                // intentionally empty layout.
                return defaultLayout
            }
            return sanitized(items)
        } catch {
            log.notice("Stored dashboard layout failed to decode; using the default layout")
            return defaultLayout
        }
    }

    /// Repairs a stored layout: one widget per kind, spans clamped to the kind's allowed set,
    /// items beyond the 8-cell capacity dropped. An intentionally empty layout stays empty.
    private static func sanitized(_ raw: [DashboardItem]) -> [DashboardItem] {
        var seen = Set<WidgetKind>()
        var used = 0
        var result: [DashboardItem] = []
        for item in raw {
            guard !seen.contains(item.kind) else { continue }
            var repaired = item
            if !item.kind.allowedSpans.contains(repaired.span) {
                repaired.span = item.kind.defaultSpan
            }
            guard used + repaired.span.cellCount <= capacity else { continue }
            seen.insert(item.kind)
            used += repaired.span.cellCount
            result.append(repaired)
        }
        return result
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(items),
              let json = String(data: data, encoding: .utf8) else {
            Self.log.error("Dashboard layout failed to encode; layout not persisted")
            return
        }
        Preferences.shared.dashboardLayoutJSON = json
    }
}
