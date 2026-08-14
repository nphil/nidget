import Foundation

// MARK: - Retiron profile DTOs
//
// The wire shape of a Retiron scenario profile, plus the mapper between it and
// `HouseholdPlanConfig` (Core/Retirement/HouseholdPlan.swift).
//
// Retiron saves whatever its web page holds: `{inputs, cardNames, debtState, budgetState,
// liveMap, ts}`, where every number inside `inputs` is a STRING because it comes straight off an
// HTML input. Nidget models the parts it edits and carries everything else through untouched, so
// saving a profile from the phone never drops a field the web app cares about (the budget tab,
// the live account mapping, and anything added later).
//
// "Untouched" is done with `RetironJSON`, a small Sendable JSON value type: unknown keys are
// decoded into it and re-encoded exactly as they arrived. The design sketch called for holding a
// raw `[String: Any]`, which cannot be Sendable; this keeps the same round-trip promise and
// crosses actor boundaries safely.

// MARK: - RetironJSON

/// Any JSON value, kept whole so unknown fields survive a round trip.
enum RetironJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RetironJSON])
    case object([String: RetironJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RetironJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RetironJSON].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// A number however it arrived: as a JSON number, as a numeric string (which is how the web
    /// app writes every input), or as a bool. Anything that isn't a real finite number reads as
    /// nil, so a junk profile can never put a NaN into the projection.
    var doubleValue: Double? {
        switch self {
        case .number(let value): return value.isFinite ? value : nil
        case .string(let value):
            guard let parsed = Double(value.trimmingCharacters(in: .whitespaces)),
                  parsed.isFinite else { return nil }
            return parsed
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    /// The same value as a whole number, or nil when it is missing, not a number, or too big to
    /// be one. Never traps.
    var intValue: Int? {
        guard let value = doubleValue, value >= -1e9, value <= 1e9 else { return nil }
        return Int(value.rounded())
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return RetironJSON.plainString(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return ["true", "1", "yes", "on"].contains(value.lowercased())
        default: return nil
        }
    }

    var objectValue: [String: RetironJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [RetironJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// "151000" rather than "151000.0" — whole numbers go back to the web app the way they came.
    static func plainString(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}

// MARK: - RetironInputValue

/// One sidebar field. Checkboxes arrive as JSON booleans, everything else as a string, including
/// numbers. Raw JSON numbers are accepted too (a hand-edited profile) and are written back as
/// strings so the web app's `parseFloat` keeps working.
enum RetironInputValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .string(RetironJSON.plainString(value))
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    init(number: Double) {
        self = .string(RetironJSON.plainString(number))
    }

    init(flag: Bool) {
        self = .bool(flag)
    }

    var doubleValue: Double? {
        switch self {
        case .string(let value):
            guard let parsed = Double(value.trimmingCharacters(in: .whitespaces)),
                  parsed.isFinite else { return nil }
            return parsed
        case .bool(let value): return value ? 1 : 0
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        }
    }

    var flagValue: Bool {
        switch self {
        case .bool(let value): return value
        case .string(let value): return ["true", "1", "yes", "on"].contains(value.lowercased())
        }
    }

    init?(json: RetironJSON) {
        switch json {
        case .bool(let value): self = .bool(value)
        case .string(let value): self = .string(value)
        case .number(let value): self = .string(RetironJSON.plainString(value))
        default: return nil
        }
    }

    var json: RetironJSON {
        switch self {
        case .string(let value): return .string(value)
        case .bool(let value): return .bool(value)
        }
    }
}

// MARK: - Debt state

/// Retiron's Debt Strategy tab, the part of it Nidget reads and writes. Anything else on a card
/// or loan (its colour today, whatever tomorrow) rides along in `extras`.
struct RetironDebtState: Codable, Sendable, Equatable {

    struct Card: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var balance: Double
        /// Rate today; 0 while a promo is running.
        var apr: Double
        /// Months from now until the promo ends. 0 means no promo.
        var promoEnd: Int
        var postPromoAPR: Double
        var minPay: Double
        var extras: [String: RetironJSON]

        init(json: [String: RetironJSON]) {
            id = json["id"]?.stringValue ?? UUID().uuidString
            name = json["name"]?.stringValue ?? "Card"
            balance = json["balance"]?.doubleValue ?? 0
            apr = json["apr"]?.doubleValue ?? 0
            promoEnd = json["promoEnd"]?.intValue ?? 0
            // Retiron renders this field as `postPromoAPR||24.99` and simulates the same way, so a
            // stored zero is a value the user never sees; treat it as the default, not as 0%.
            // Note: `RetironProfileMapper.apply(_:to:)` writes this back, so the first debt edit in
            // Nidget normalizes a stored 0 to 24.99, the rate Retiron was already using.
            let storedPostPromo = json["postPromoAPR"]?.doubleValue ?? 0
            postPromoAPR = storedPostPromo > 0 ? storedPostPromo : 24.99
            minPay = json["minPay"]?.doubleValue ?? 0
            extras = json.filter { !Card.knownKeys.contains($0.key) }
        }

        var json: [String: RetironJSON] {
            var object = extras
            object["id"] = RetironJSON.string(id)
            object["name"] = RetironJSON.string(name)
            object["balance"] = RetironJSON.number(balance)
            object["apr"] = RetironJSON.number(apr)
            object["promoEnd"] = RetironJSON.number(Double(promoEnd))
            object["postPromoAPR"] = RetironJSON.number(postPromoAPR)
            object["minPay"] = RetironJSON.number(minPay)
            return object
        }

        static let knownKeys: Set<String> = ["id", "name", "balance", "apr", "promoEnd",
                                             "postPromoAPR", "minPay"]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(json: (try? container.decode([String: RetironJSON].self)) ?? [:])
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(json)
        }
    }

    struct Loan: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var balance: Double
        var apr: Double
        var minPay: Double
        var extras: [String: RetironJSON]

        init(json: [String: RetironJSON]) {
            id = json["id"]?.stringValue ?? UUID().uuidString
            name = json["name"]?.stringValue ?? "Loan"
            balance = json["balance"]?.doubleValue ?? 0
            apr = json["apr"]?.doubleValue ?? 0
            minPay = json["minPay"]?.doubleValue ?? 0
            extras = json.filter { !Loan.knownKeys.contains($0.key) }
        }

        var json: [String: RetironJSON] {
            var object = extras
            object["id"] = RetironJSON.string(id)
            object["name"] = RetironJSON.string(name)
            object["balance"] = RetironJSON.number(balance)
            object["apr"] = RetironJSON.number(apr)
            object["minPay"] = RetironJSON.number(minPay)
            return object
        }

        static let knownKeys: Set<String> = ["id", "name", "balance", "apr", "minPay"]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(json: (try? container.decode([String: RetironJSON].self)) ?? [:])
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(json)
        }
    }

    var cards: [Card]
    var loans: [Loan]
    /// Custom payoff order. Retiron declares it but never reads it; carried through as is.
    var priority: [String]
    var extras: [String: RetironJSON]

    init(json: [String: RetironJSON]) {
        cards = (json["cards"]?.arrayValue ?? []).compactMap { $0.objectValue }.map { Card(json: $0) }
        loans = (json["loans"]?.arrayValue ?? []).compactMap { $0.objectValue }.map { Loan(json: $0) }
        priority = (json["priority"]?.arrayValue ?? []).compactMap { $0.stringValue }
        extras = json.filter { !["cards", "loans", "priority"].contains($0.key) }
    }

    var json: [String: RetironJSON] {
        var object = extras
        object["cards"] = RetironJSON.array(cards.map { .object($0.json) })
        object["loans"] = RetironJSON.array(loans.map { .object($0.json) })
        object["priority"] = RetironJSON.array(priority.map { .string($0) })
        return object
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(json: (try? container.decode([String: RetironJSON].self)) ?? [:])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(json)
    }
}

// MARK: - Profile

/// The `data` object of one saved scenario.
struct RetironProfileData: Codable, Sendable, Equatable {
    /// Sidebar field id → value, exactly as the web app stores it.
    var inputs: [String: RetironInputValue]
    /// The four renameable Overview tile labels, keyed "0" through "3".
    var cardNames: [String: String]
    var debtState: RetironDebtState?
    /// The Budget tab. Nidget never edits it, so it rides through untouched.
    var budgetState: RetironJSON?
    /// Mapping from a sidebar balance field to a pushed Nidget account, plus "_auto".
    var liveMap: [String: RetironInputValue]?
    /// Milliseconds since 1970, set by whichever app saved last.
    var timestamp: Double?
    /// Everything else in the object, kept so a save from the phone loses nothing.
    var extras: [String: RetironJSON]
    /// Entries of `inputs` / `liveMap` whose JSON shape `RetironInputValue` cannot hold (null,
    /// array, object). Kept so a value Retiron adds later survives a save from the phone.
    private var inputExtras: [String: RetironJSON] = [:]
    private var liveMapExtras: [String: RetironJSON] = [:]

    init(inputs: [String: RetironInputValue] = [:],
         cardNames: [String: String] = [:],
         debtState: RetironDebtState? = nil,
         budgetState: RetironJSON? = nil,
         liveMap: [String: RetironInputValue]? = nil,
         timestamp: Double? = nil,
         extras: [String: RetironJSON] = [:]) {
        self.inputs = inputs
        self.cardNames = cardNames
        self.debtState = debtState
        self.budgetState = budgetState
        self.liveMap = liveMap
        self.timestamp = timestamp
        self.extras = extras
    }

    private static let knownKeys: Set<String> = ["inputs", "cardNames", "debtState",
                                                 "budgetState", "liveMap", "ts"]

    init(json: [String: RetironJSON]) {
        var inputs: [String: RetironInputValue] = [:]
        var inputLeftovers: [String: RetironJSON] = [:]
        for (key, value) in json["inputs"]?.objectValue ?? [:] {
            if let input = RetironInputValue(json: value) { inputs[key] = input }
            else { inputLeftovers[key] = value }
        }
        self.inputs = inputs
        inputExtras = inputLeftovers

        var names: [String: String] = [:]
        for (key, value) in json["cardNames"]?.objectValue ?? [:] {
            if let name = value.stringValue { names[key] = name }
        }
        cardNames = names

        if let debt = json["debtState"]?.objectValue {
            debtState = RetironDebtState(json: debt)
        } else {
            debtState = nil
        }

        if let budget = json["budgetState"], budget != RetironJSON.null {
            budgetState = budget
        } else {
            budgetState = nil
        }

        if let map = json["liveMap"]?.objectValue {
            var live: [String: RetironInputValue] = [:]
            var liveLeftovers: [String: RetironJSON] = [:]
            for (key, value) in map {
                if let entry = RetironInputValue(json: value) { live[key] = entry }
                else { liveLeftovers[key] = value }
            }
            liveMap = live
            liveMapExtras = liveLeftovers
        } else {
            liveMap = nil
        }

        timestamp = json["ts"]?.doubleValue
        extras = json.filter { !RetironProfileData.knownKeys.contains($0.key) }
    }

    /// The object to send back: everything that arrived, with our edits written over the top.
    var json: [String: RetironJSON] {
        var object = extras
        // The leftovers go down first and the mapped values over the top, so an edit always wins.
        var inputObject = inputExtras
        for (key, value) in inputs { inputObject[key] = value.json }
        object["inputs"] = RetironJSON.object(inputObject)
        object["cardNames"] = RetironJSON.object(cardNames.mapValues { RetironJSON.string($0) })
        if let debtState {
            object["debtState"] = RetironJSON.object(debtState.json)
        }
        if let budgetState {
            object["budgetState"] = budgetState
        }
        if let liveMap {
            var mapObject = liveMapExtras
            for (key, value) in liveMap { mapObject[key] = value.json }
            object["liveMap"] = RetironJSON.object(mapObject)
        }
        if let timestamp {
            object["ts"] = RetironJSON.number(timestamp)
        }
        return object
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(json: (try? container.decode([String: RetironJSON].self)) ?? [:])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(json)
    }

    /// Round trip through a JSON string, for the offline cache in Preferences.
    init?(jsonString: String) {
        guard !jsonString.isEmpty, let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RetironProfileData.self, from: data) else {
            return nil
        }
        self = decoded
    }

    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// One saved scenario.
struct RetironProfile: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var data: RetironProfileData
    /// ISO timestamp of the last save, as the server reports it.
    var updated: String?
}

/// A row of `GET /api/profiles`.
struct RetironProfileSummary: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var updated: String?
}

/// The answer to `GET /api/profiles`: every scenario plus which one is active.
struct RetironProfileList: Codable, Sendable, Equatable {
    var profiles: [RetironProfileSummary]
    var active: String?
}

// MARK: - Snapshot push

/// What Nidget sends to Retiron: real balances and what the household actually spent. Keys are
/// snake_case because that is what the Retiron endpoint reads.
struct RetironSnapshotPush: Codable, Sendable, Equatable {

    struct AccountBalance: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var balanceCents: Int64
        var offBudget: Bool
        var closed: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case balanceCents = "balance_cents"
            case offBudget = "off_budget"
            case closed
        }
    }

    struct MonthSpend: Codable, Sendable, Equatable {
        /// "2026-08"
        var month: String
        /// Money out that month, as a positive number of cents.
        var outflowCents: Int64

        enum CodingKeys: String, CodingKey {
            case month
            case outflowCents = "outflow_cents"
        }
    }

    /// ISO 8601, e.g. "2026-08-14T21:00:00Z".
    var asOf: String
    var accounts: [AccountBalance]
    var monthlySpend: [MonthSpend]

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case accounts
        case monthlySpend = "monthly_spend"
    }
}

// MARK: - RetironProfileMapper
//
// Profile inputs ↔ HouseholdPlanConfig. Every key Retiron saves is listed below, either mapped or
// named as deliberately unmapped. Missing or unreadable keys keep the config default, so an old
// profile saved before a field existed still opens.
//
// Not in the profile at all, and therefore local to this app: both ages, the base calendar year,
// the horizon, the target retirement age, the tax table, the contribution caps, the RSU haircut,
// the cash yield on the down-payment pot, and the non-housing living factor. Retiron hardcodes
// those; `HouseholdPlanConfig` carries the same values as defaults.

enum RetironProfileMapper {

    // MARK: Profile → config

    /// Reads a profile into a plan config. `base` supplies every value the profile has no key
    /// for (ages, horizon, tax rules), so callers can start from an edited config if they want.
    /// Missing or unreadable keys keep the config default; a key present but blank reads as 0,
    /// the way Retiron's `gv()` does.
    static func config(from data: RetironProfileData,
                       base: HouseholdPlanConfig = HouseholdPlanConfig()) -> HouseholdPlanConfig {
        let inputs = data.inputs
        var config = base

        // Primary earner, "Nitin — Current Comp".
        config.personA.baseSalary = gvNumber(inputs, "nitinBase", config.personA.baseSalary)
        config.personA.bonusPct = gvNumber(inputs, "nitinBonus", config.personA.bonusPct)
        config.personA.k401Pct = gvNumber(inputs, "nitin401k", config.personA.k401Pct)
        config.personA.matchPct = gvNumber(inputs, "nitinMatch", config.personA.matchPct)
        config.personA.rsuPct = gvNumber(inputs, "nitinRSU", config.personA.rsuPct)
        config.personA.retirementBalance = gvNumber(inputs, "nitin401kBal",
                                                    config.personA.retirementBalance)
        config.rothBalance = gvNumber(inputs, "nitinRoth", config.rothBalance)
        config.hsaBalance = gvNumber(inputs, "hsaBal", config.hsaBalance)
        config.hsaRestart = flag(inputs, "hsaRestart", config.hsaRestart)
        config.hsaStartYear = gvInteger(inputs, "hsaStartYr", config.hsaStartYear)
        config.hsaAnnualContribution = gvNumber(inputs, "hsaAnnualContrib",
                                                config.hsaAnnualContribution)
        config.liquidCash = gvNumber(inputs, "liquidCash", config.liquidCash)

        // Primary earner, "Career Path". `dir*` is Retiron's name for the post-promotion job.
        config.colRaisePct = gvNumber(inputs, "nitinCoL", config.colRaisePct)
        config.promoInYears = gvInteger(inputs, "promoYrs", config.promoInYears)
        config.promoBaseSalary = gvNumber(inputs, "dirBase", config.promoBaseSalary)
        config.promoBonusPct = gvNumber(inputs, "dirBonus", config.promoBonusPct)
        config.promoRSUPct = gvNumber(inputs, "dirRSU", config.promoRSUPct)
        config.promoAnnualRaisePct = gvNumber(inputs, "dirRaise", config.promoAnnualRaisePct)

        // Second earner.
        config.personB.baseSalary = gvNumber(inputs, "isabelSal", config.personB.baseSalary)
        config.personBSalaryCap = gvNumber(inputs, "isabelCap", config.personBSalaryCap)
        config.personB.k401Pct = gvNumber(inputs, "isabel401k", config.personB.k401Pct)
        config.personB.retirementBalance = gvNumber(inputs, "isabelBal",
                                                    config.personB.retirementBalance)
        config.personBFullTime = flag(inputs, "isabelFT", config.personBFullTime)
        config.personBFullTimeYear = gvInteger(inputs, "isabelFTYr", config.personBFullTimeYear)
        config.personBFullTimeSalary = gvNumber(inputs, "isabelFTSal", config.personBFullTimeSalary)
        config.personBFullTimeCap = gvNumber(inputs, "isabelFTCap", config.personBFullTimeCap)

        // Goals and rates. `intlSpend` is deliberately unmapped: Retiron saves it but no formula
        // reads it, and the International section here works off each destination's own cost.
        config.annualSpend = gvNumber(inputs, "waSpend", config.annualSpend)
        config.investmentReturnPct = gvNumber(inputs, "invRet", config.investmentReturnPct)
        config.inflationPct = gvNumber(inputs, "inflation", config.inflationPct)

        // Current home, which becomes the rental.
        config.atlValue = gvNumber(inputs, "atlVal", config.atlValue)
        config.atlMortgage = gvNumber(inputs, "atlMort", config.atlMortgage)
        config.atlMortgagePaymentMonthly = gvNumber(inputs, "atlMortPay",
                                                    config.atlMortgagePaymentMonthly)
        config.atlTaxBumpYear = gvInteger(inputs, "atlTaxBumpYr", config.atlTaxBumpYear)
        config.atlTaxBumpMonthly = gvNumber(inputs, "atlTaxBump", config.atlTaxBumpMonthly)
        config.atlAppreciationPct = gvNumber(inputs, "atlAppr", config.atlAppreciationPct)
        config.atlRentYear1Monthly = gvNumber(inputs, "atlRentYr1", config.atlRentYear1Monthly)
        config.atlRentGrowthPct = gvNumber(inputs, "atlRentGrowth", config.atlRentGrowthPct)
        config.atlRentExpensesMonthly = gvNumber(inputs, "atlRentExp", config.atlRentExpensesMonthly)

        // Next home.
        config.tacPrice = gvNumber(inputs, "tacPrice", config.tacPrice)
        config.tacBuyYear = gvInteger(inputs, "tacBuyYr", config.tacBuyYear)
        config.tacDownPct = gvNumber(inputs, "tacDP", config.tacDownPct)
        config.tacRatePct = gvNumber(inputs, "tacRate", config.tacRatePct)
        config.tacAppreciationPct = gvNumber(inputs, "tacAppr", config.tacAppreciationPct)

        // Debt, the five hidden fields the Debt tab writes for the yearly projection to read.
        config.creditCardBalance = gvNumber(inputs, "ccDebt", config.creditCardBalance)
        config.studentLoanBalance = gvNumber(inputs, "slDebt", config.studentLoanBalance)
        config.creditCardAPRPct = gvNumber(inputs, "ccAPR", config.creditCardAPRPct)
        config.studentLoanAPRPct = gvNumber(inputs, "slAPR", config.studentLoanAPRPct)
        config.monthlyDebtPayment = gvNumber(inputs, "debtPay", config.monthlyDebtPayment)

        // Deliberately unmapped, and left untouched on save:
        //   intlSpend      dead input in Retiron, no formula reads it
        //   budgetLinked   the Budget tab drives waSpend on the web side only
        //   settingApiUrl  the web app's own server address
        //   heloc*, bt*, payoffStrategy, totalDebtPay  read by the debt helpers below, not the
        //                  yearly projection
        return config
    }

    /// Writes an edited config back over a profile, leaving every other key alone.
    static func apply(_ config: HouseholdPlanConfig,
                      to data: RetironProfileData) -> RetironProfileData {
        var updated = data
        var inputs = data.inputs

        inputs["nitinBase"] = RetironInputValue(number: config.personA.baseSalary)
        inputs["nitinBonus"] = RetironInputValue(number: config.personA.bonusPct)
        inputs["nitin401k"] = RetironInputValue(number: config.personA.k401Pct)
        inputs["nitinMatch"] = RetironInputValue(number: config.personA.matchPct)
        inputs["nitinRSU"] = RetironInputValue(number: config.personA.rsuPct)
        inputs["nitin401kBal"] = RetironInputValue(number: config.personA.retirementBalance)
        inputs["nitinRoth"] = RetironInputValue(number: config.rothBalance)
        inputs["hsaBal"] = RetironInputValue(number: config.hsaBalance)
        inputs["hsaRestart"] = RetironInputValue(flag: config.hsaRestart)
        inputs["hsaStartYr"] = RetironInputValue(number: Double(config.hsaStartYear))
        inputs["hsaAnnualContrib"] = RetironInputValue(number: config.hsaAnnualContribution)
        inputs["liquidCash"] = RetironInputValue(number: config.liquidCash)

        inputs["nitinCoL"] = RetironInputValue(number: config.colRaisePct)
        inputs["promoYrs"] = RetironInputValue(number: Double(config.promoInYears))
        inputs["dirBase"] = RetironInputValue(number: config.promoBaseSalary)
        inputs["dirBonus"] = RetironInputValue(number: config.promoBonusPct)
        inputs["dirRSU"] = RetironInputValue(number: config.promoRSUPct)
        inputs["dirRaise"] = RetironInputValue(number: config.promoAnnualRaisePct)

        inputs["isabelSal"] = RetironInputValue(number: config.personB.baseSalary)
        inputs["isabelCap"] = RetironInputValue(number: config.personBSalaryCap)
        inputs["isabel401k"] = RetironInputValue(number: config.personB.k401Pct)
        inputs["isabelBal"] = RetironInputValue(number: config.personB.retirementBalance)
        inputs["isabelFT"] = RetironInputValue(flag: config.personBFullTime)
        inputs["isabelFTYr"] = RetironInputValue(number: Double(config.personBFullTimeYear))
        inputs["isabelFTSal"] = RetironInputValue(number: config.personBFullTimeSalary)
        inputs["isabelFTCap"] = RetironInputValue(number: config.personBFullTimeCap)

        inputs["waSpend"] = RetironInputValue(number: config.annualSpend)
        inputs["invRet"] = RetironInputValue(number: config.investmentReturnPct)
        inputs["inflation"] = RetironInputValue(number: config.inflationPct)

        inputs["atlVal"] = RetironInputValue(number: config.atlValue)
        inputs["atlMort"] = RetironInputValue(number: config.atlMortgage)
        inputs["atlMortPay"] = RetironInputValue(number: config.atlMortgagePaymentMonthly)
        inputs["atlTaxBumpYr"] = RetironInputValue(number: Double(config.atlTaxBumpYear))
        inputs["atlTaxBump"] = RetironInputValue(number: config.atlTaxBumpMonthly)
        inputs["atlAppr"] = RetironInputValue(number: config.atlAppreciationPct)
        inputs["atlRentYr1"] = RetironInputValue(number: config.atlRentYear1Monthly)
        inputs["atlRentGrowth"] = RetironInputValue(number: config.atlRentGrowthPct)
        inputs["atlRentExp"] = RetironInputValue(number: config.atlRentExpensesMonthly)

        inputs["tacPrice"] = RetironInputValue(number: config.tacPrice)
        inputs["tacBuyYr"] = RetironInputValue(number: Double(config.tacBuyYear))
        // Retiron's tacDP is a range slider (min 5, max 25, step 1) and the browser silently
        // snaps and clamps whatever applyState assigns it. Match that here so a deposit saved
        // from the phone survives the web app's next autosave.
        inputs["tacDP"] = RetironInputValue(number: min(25, max(5, config.tacDownPct.rounded())))
        inputs["tacRate"] = RetironInputValue(number: config.tacRatePct)
        inputs["tacAppr"] = RetironInputValue(number: config.tacAppreciationPct)

        inputs["ccDebt"] = RetironInputValue(number: config.creditCardBalance)
        inputs["slDebt"] = RetironInputValue(number: config.studentLoanBalance)
        inputs["ccAPR"] = RetironInputValue(number: config.creditCardAPRPct)
        inputs["slAPR"] = RetironInputValue(number: config.studentLoanAPRPct)
        inputs["debtPay"] = RetironInputValue(number: config.monthlyDebtPayment)

        updated.inputs = inputs
        updated.timestamp = nowMilliseconds
        return updated
    }

    // MARK: Profile → debt simulation

    /// Every account the payoff simulation should run over: the cards, the loans, and the HELOC
    /// when it is switched on. Retiron keeps the HELOC in the sidebar rather than in `debtState`.
    static func debtAccounts(from data: RetironProfileData) -> [DebtAccount] {
        var accounts: [DebtAccount] = []
        for card in data.debtState?.cards ?? [] {
            accounts.append(DebtAccount(id: card.id, name: card.name, balance: card.balance,
                                        aprPct: card.apr, promoEndMonth: card.promoEnd,
                                        postPromoAPRPct: card.postPromoAPR, minPay: card.minPay,
                                        kind: .card))
        }
        for loan in data.debtState?.loans ?? [] {
            accounts.append(DebtAccount(id: loan.id, name: loan.name, balance: loan.balance,
                                        aprPct: loan.apr, promoEndMonth: 0,
                                        postPromoAPRPct: loan.apr, minPay: loan.minPay,
                                        kind: .loan))
        }
        let inputs = data.inputs
        if flag(inputs, "helocEnabled", false) {
            let balance = number(inputs, "helocBal", 0)
            if balance > 0 {
                accounts.append(DebtAccount(id: "heloc", name: "HELOC", balance: balance,
                                            aprPct: number(inputs, "helocAPR", 8.5),
                                            promoEndMonth: 0,
                                            postPromoAPRPct: number(inputs, "helocAPR", 8.5),
                                            minPay: number(inputs, "helocPay", 0),
                                            kind: .heloc))
            }
        }
        return accounts
    }

    /// The payoff order the profile asks for. Anything unrecognised falls back to avalanche,
    /// which is Retiron's default.
    static func strategy(from data: RetironProfileData) -> DebtStrategy {
        let raw = data.inputs["payoffStrategy"]?.stringValue ?? ""
        return DebtStrategy(rawValue: raw) ?? .avalanche
    }

    /// Money going to debt each month. `totalDebtPay` is the Debt tab's field; `debtPay` is the
    /// hidden mirror the yearly projection reads, and it is the fallback for older profiles.
    /// A zero or blank field is not "pay nothing": Retiron's `parseFloat(...)||2000` simulates
    /// and displays $2,000 in that case, so match it rather than running a 120-month schedule
    /// that never clears.
    static func monthlyDebtBudget(from data: RetironProfileData) -> Double {
        let inputs = data.inputs
        let total = number(inputs, "totalDebtPay", 0)
        if total > 0 { return total }
        let mirror = number(inputs, "debtPay", 0)
        return mirror > 0 ? mirror : 2000
    }

    /// The balance-transfer plan, or nil when the profile has it switched off.
    static func balanceTransfer(from data: RetironProfileData) -> BalanceTransfer? {
        let inputs = data.inputs
        guard flag(inputs, "btEnabled", false) else { return nil }
        let amount = number(inputs, "btAmount", 0)
        guard amount > 0 else { return nil }
        return BalanceTransfer(amount: amount,
                               feePct: number(inputs, "btFee", 3),
                               promoMonths: integer(inputs, "btPromo", 21),
                               postPromoAPRPct: number(inputs, "btPostAPR", 24.99),
                               monthlyPayment: number(inputs, "btMonthlyPay", 0))
    }

    /// Writes edited balances, rates and minimum payments back into `debtState` (and into the
    /// HELOC fields), then refreshes the five hidden mirrors the yearly projection reads, exactly
    /// the way Retiron's own debt tab does it: cards and the HELOC add up into the card bucket,
    /// loans into the loan bucket, and each bucket's rate is the plain average of its accounts.
    /// Accounts are matched by id, so adding or removing one on the phone is not possible here,
    /// which is deliberate: Retiron stays the place to add and remove accounts.
    static func apply(_ accounts: [DebtAccount],
                      to data: RetironProfileData) -> RetironProfileData {
        var updated = data
        var byID: [String: DebtAccount] = [:]
        for account in accounts { byID[account.id] = account }

        var debtState = data.debtState ?? RetironDebtState(json: [:])
        for index in debtState.cards.indices {
            guard let edited = byID[debtState.cards[index].id] else { continue }
            debtState.cards[index].balance = edited.balance
            debtState.cards[index].apr = edited.aprPct
            debtState.cards[index].promoEnd = edited.promoEndMonth
            debtState.cards[index].postPromoAPR = edited.postPromoAPRPct
            debtState.cards[index].minPay = edited.minPay
        }
        for index in debtState.loans.indices {
            guard let edited = byID[debtState.loans[index].id] else { continue }
            debtState.loans[index].balance = edited.balance
            debtState.loans[index].apr = edited.aprPct
            debtState.loans[index].minPay = edited.minPay
        }
        updated.debtState = debtState

        var inputs = data.inputs
        var helocBalance: Double = 0
        if let heloc = byID["heloc"] {
            helocBalance = heloc.balance
            inputs["helocBal"] = RetironInputValue(number: heloc.balance)
            inputs["helocAPR"] = RetironInputValue(number: heloc.aprPct)
            inputs["helocPay"] = RetironInputValue(number: heloc.minPay)
        } else if flag(inputs, "helocEnabled", false) {
            helocBalance = number(inputs, "helocBal", 0)
        }

        let cardTotal = debtState.cards.reduce(0) { $0 + $1.balance } + helocBalance
        let loanTotal = debtState.loans.reduce(0) { $0 + $1.balance }
        let cardRate = debtState.cards.isEmpty
            ? 0 : debtState.cards.reduce(0) { $0 + $1.apr } / Double(debtState.cards.count)
        let loanRate = debtState.loans.isEmpty
            ? 5 : debtState.loans.reduce(0) { $0 + $1.apr } / Double(debtState.loans.count)

        inputs["ccDebt"] = RetironInputValue(number: cardTotal)
        inputs["slDebt"] = RetironInputValue(number: loanTotal)
        inputs["ccAPR"] = RetironInputValue(number: (cardRate * 100).rounded() / 100)
        inputs["slAPR"] = RetironInputValue(number: (loanRate * 100).rounded() / 100)

        updated.inputs = inputs
        updated.timestamp = nowMilliseconds
        return updated
    }

    /// Sets the monthly debt budget on both fields Retiron keeps in step.
    static func apply(monthlyDebtBudget budget: Double,
                      to data: RetironProfileData) -> RetironProfileData {
        var updated = data
        updated.inputs["totalDebtPay"] = RetironInputValue(number: budget)
        updated.inputs["debtPay"] = RetironInputValue(number: budget)
        updated.timestamp = nowMilliseconds
        return updated
    }

    /// Sets the payoff order.
    static func apply(strategy: DebtStrategy, to data: RetironProfileData) -> RetironProfileData {
        var updated = data
        updated.inputs["payoffStrategy"] = RetironInputValue.string(strategy.rawValue)
        updated.timestamp = nowMilliseconds
        return updated
    }

    // MARK: Reading helpers

    private static func number(_ inputs: [String: RetironInputValue], _ key: String,
                               _ fallback: Double) -> Double {
        guard let value = inputs[key]?.doubleValue, value.isFinite else { return fallback }
        return value
    }

    private static func integer(_ inputs: [String: RetironInputValue], _ key: String,
                                _ fallback: Int) -> Int {
        guard let value = inputs[key]?.doubleValue, value.isFinite,
              value >= -1e9, value <= 1e9 else { return fallback }
        return Int(value.rounded())
    }

    private static func flag(_ inputs: [String: RetironInputValue], _ key: String,
                             _ fallback: Bool) -> Bool {
        guard let value = inputs[key] else { return fallback }
        return value.flagValue
    }

    /// A field the yearly projection reads through Retiron's `gv()` (`parseFloat(v)||0`): a field
    /// the user cleared is present as "" and must read as 0, not as the shipped default. An
    /// absent or unreadable key still keeps the config default. The debt-tab helpers above stay
    /// on `number`/`integer`, because Retiron's own debt code falls back to 3, 21, 24.99 and 8.5
    /// there rather than to 0.
    private static func gvNumber(_ inputs: [String: RetironInputValue], _ key: String,
                                 _ fallback: Double) -> Double {
        guard let raw = inputs[key] else { return fallback }
        if case .string(let text) = raw,
           text.trimmingCharacters(in: .whitespaces).isEmpty { return 0 }
        return raw.doubleValue ?? fallback
    }

    /// `Math.round(gv(id))` — same blank rule, rounded like the JS does.
    private static func gvInteger(_ inputs: [String: RetironInputValue], _ key: String,
                                  _ fallback: Int) -> Int {
        guard let raw = inputs[key] else { return fallback }
        if case .string(let text) = raw,
           text.trimmingCharacters(in: .whitespaces).isEmpty { return 0 }
        guard let value = raw.doubleValue, value >= -1e9, value <= 1e9 else { return fallback }
        return Int(value.rounded())
    }

    /// Milliseconds since 1970, whole, the way Retiron's own `Date.now()` records it.
    private static var nowMilliseconds: Double { (Date().timeIntervalSince1970 * 1000).rounded() }
}
