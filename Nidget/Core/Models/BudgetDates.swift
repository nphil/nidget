import Foundation

// MARK: - BudgetDay
//
// Actual stores transaction dates as integer yyyymmdd (e.g. 20260809). Calendar math goes through
// the Gregorian calendar in the current time zone.

struct BudgetDay: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    /// yyyymmdd
    var raw: Int

    init(raw: Int) { self.raw = raw }

    init(year: Int, month: Int, day: Int) {
        self.raw = year * 10000 + month * 100 + day
    }

    init(date: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)
    }

    static var today: BudgetDay { BudgetDay(date: Date()) }

    var year: Int { raw / 10000 }
    var monthComponent: Int { (raw / 100) % 100 }
    var dayComponent: Int { raw % 100 }
    var month: BudgetMonth { BudgetMonth(raw: raw / 100) }

    var date: Date {
        var c = DateComponents()
        c.year = year; c.month = monthComponent; c.day = dayComponent
        return Calendar.current.date(from: c) ?? Date()
    }

    func addingDays(_ n: Int) -> BudgetDay {
        let d = Calendar.current.date(byAdding: .day, value: n, to: date) ?? date
        return BudgetDay(date: d)
    }

    /// "Today", "Yesterday", or a medium formatted date.
    var relativeDisplay: String {
        if self == .today { return "Today" }
        if self == BudgetDay.today.addingDays(-1) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var shortDisplay: String { date.formatted(.dateTime.month(.abbreviated).day()) }

    static func < (lhs: BudgetDay, rhs: BudgetDay) -> Bool { lhs.raw < rhs.raw }
    var description: String { String(raw) }
}

// MARK: - BudgetMonth
//
// Actual stores budget months as integer yyyymm (e.g. 202608).

struct BudgetMonth: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    /// yyyymm
    var raw: Int

    init(raw: Int) { self.raw = raw }
    init(year: Int, month: Int) { self.raw = year * 100 + month }

    init(date: Date) {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        self.init(year: c.year ?? 2000, month: c.month ?? 1)
    }

    static var current: BudgetMonth { BudgetMonth(date: Date()) }

    var year: Int { raw / 100 }
    var monthComponent: Int { raw % 100 }

    var next: BudgetMonth {
        monthComponent == 12 ? BudgetMonth(year: year + 1, month: 1)
                             : BudgetMonth(year: year, month: monthComponent + 1)
    }

    var previous: BudgetMonth {
        monthComponent == 1 ? BudgetMonth(year: year - 1, month: 12)
                            : BudgetMonth(year: year, month: monthComponent - 1)
    }

    func advanced(by n: Int) -> BudgetMonth {
        let total = year * 12 + (monthComponent - 1) + n
        return BudgetMonth(year: total / 12, month: total % 12 + 1)
    }

    /// Number of months from `other` to self (self − other).
    func months(since other: BudgetMonth) -> Int {
        (year * 12 + monthComponent) - (other.year * 12 + other.monthComponent)
    }

    /// Months ending at (and including) `end`, oldest first.
    static func lastMonths(_ count: Int, endingAt end: BudgetMonth = .current) -> [BudgetMonth] {
        (0..<max(count, 1)).map { end.advanced(by: -$0) }.reversed()
    }

    var firstDay: BudgetDay { BudgetDay(year: year, month: monthComponent, day: 1) }
    var lastDay: BudgetDay {
        let range = Calendar.current.range(of: .day, in: .month, for: firstDay.date)
        return BudgetDay(year: year, month: monthComponent, day: range?.count ?? 28)
    }
    var dayCount: Int { lastDay.dayComponent }

    var date: Date { firstDay.date }

    /// "August 2026"
    var displayName: String { date.formatted(.dateTime.month(.wide).year()) }
    /// "Aug"
    var shortName: String { date.formatted(.dateTime.month(.abbreviated)) }
    /// "Aug ’26"
    var compactName: String { date.formatted(.dateTime.month(.abbreviated).year(.twoDigits)) }

    /// "2026-08" — the string form Actual uses in some CRDT row ids.
    var dashString: String { String(format: "%04d-%02d", year, monthComponent) }

    static func < (lhs: BudgetMonth, rhs: BudgetMonth) -> Bool { lhs.raw < rhs.raw }
    var description: String { String(raw) }
}
