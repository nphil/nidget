import Foundation

// MARK: - RetirementConfig
//
// User assumptions for the retirement module. Persisted as JSON via
// `Preferences.retirementConfigJSON`. All projections run in REAL (inflation-adjusted) terms, so
// the expected return is reduced by inflation before any compounding — see `RetirementPlanner`.

struct RetirementConfig: Codable, Sendable {
    var currentAge: Int = 35
    var retireAge: Int = 60
    var lifeExpectancy: Int = 95
    /// Investment accounts (usually off-budget) whose balances count toward `invested`.
    var linkedAccountIDs: [String] = []
    /// Assets not tracked in Actual (e.g. an external brokerage).
    var extraAssets: Money = .zero
    var monthlyContribution: Money = .zero
    var expectedReturnPct: Double = 7.0
    var returnStdDevPct: Double = 15.0
    var inflationPct: Double = 3.0
    var withdrawalRatePct: Double = 4.0
    /// nil ⇒ derive annual spending from the last-12-months budget outflow (passed by the caller).
    var annualSpendingOverride: Money? = nil
}

// MARK: - Output types

/// Everything the Retirement screen renders, computed in one pass by `RetirementPlanner`.
struct RetirementSnapshot: Sendable {
    var invested: Money
    var fiNumber: Money
    /// invested ÷ fiNumber.
    var progress: Double
    var annualSpending: Money
    /// Interpolated age at which the deterministic path first reaches the FI number; nil if never.
    var projectedRetireAge: Double?
    /// Earliest age at which contributions could stop and growth alone still reaches FI by
    /// `retireAge`; nil if FI is unreachable even contributing until `retireAge`.
    var coastFIREAge: Double?
    /// Deterministic real-growth path, one point per year from `currentAge` to `lifeExpectancy`.
    var deterministic: [YearPoint]
    /// Monte Carlo percentile paths (p10/p25/p50/p75/p90) over the same years.
    var percentileBands: MonteCarloBands
    /// Fraction of Monte Carlo runs whose balance is still positive at `lifeExpectancy`.
    var successProbability: Double
}

/// One point of the deterministic projection. `year` is a calendar year (current year + offset),
/// `age` the age reached at that point.
struct YearPoint: Sendable, Identifiable {
    var id: Int { year }
    var year: Int
    var age: Double
    var value: Money
}

/// Percentile paths from the Monte Carlo simulation; all arrays share `years` as their axis.
struct MonteCarloBands: Sendable {
    var years: [Int]
    var p10: [Money]
    var p25: [Money]
    var p50: [Money]
    var p75: [Money]
    var p90: [Money]
}

// MARK: - RetirementPlanner
//
// Pure math, no UI, no I/O. All projections are in REAL terms:
//
//     µ = (expectedReturnPct − inflationPct) / 100        real expected annual return
//     σ = returnStdDevPct / 100                            annual return standard deviation
//
// so every projected value is in today's purchasing power and the FI number never needs
// inflating. The Monte Carlo seed is a fixed constant so recomputes are stable for the UI;
// callers run `snapshot` off-main (`Task.detached(priority: .userInitiated)`).

enum RetirementPlanner {

    /// Fixed SplitMix64 seed — identical inputs always produce identical bands (stable UI).
    private static let monteCarloSeed: UInt64 = 0xA11CE

    /// Cap on converted balances: 10¹⁵ cents ($10 trillion) keeps `Int64` far from overflow.
    private static let maxCents: Double = 1e15

    /// Builds the full retirement snapshot.
    ///
    /// - Parameters:
    ///   - config: User assumptions (ages, rates, contribution, spending override).
    ///   - investedNow: Sum of linked-account balances today; `config.extraAssets` is added on top.
    ///   - annualSpendingFromBudget: Last-12-months outflow, used when `annualSpendingOverride`
    ///     is nil. Expected to be positive.
    ///   - runs: Monte Carlo path count (callers pass 1000; floored to 1).
    static func snapshot(config: RetirementConfig, investedNow: Money,
                         annualSpendingFromBudget: Money, runs: Int) -> RetirementSnapshot {
        /// invested = linked balances + assets outside Actual.
        let invested = investedNow + config.extraAssets
        /// annualSpending = override ?? derived-from-budget.
        let annualSpending = config.annualSpendingOverride ?? annualSpendingFromBudget

        /// µ = (expectedReturnPct − inflationPct) / 100 — real expected annual return.
        let mu = (config.expectedReturnPct - config.inflationPct) / 100.0
        /// σ = returnStdDevPct / 100 (negative input floored to 0).
        let sigma = max(config.returnStdDevPct, 0) / 100.0

        let start = invested.doubleValue
        /// Annual contribution = monthlyContribution × 12, applied once per accumulation year.
        let contribution = config.monthlyContribution.doubleValue * 12.0
        let spending = annualSpending.doubleValue

        /// Horizon: one point per year of age from currentAge through lifeExpectancy.
        let totalYears = max(config.lifeExpectancy - config.currentAge, 0)
        /// Years that receive contributions (the year starting at age a contributes iff a < retireAge).
        let contributionYears = max(config.retireAge - config.currentAge, 0)

        /// fiNumber = annualSpending ÷ (withdrawalRatePct / 100). A non-positive withdrawal rate
        /// makes FI unreachable (∞); the Money conversion below caps it at 10¹⁵ cents.
        let withdrawalRate = config.withdrawalRatePct / 100.0
        let fiDouble: Double = withdrawalRate > 0 ? spending / withdrawalRate : .infinity

        /// progress = invested ÷ fiNumber. Degenerate cases: fiNumber 0 (no spending) counts as
        /// fully FI (1.0); an infinite fiNumber as no progress (0.0).
        let progress: Double
        if fiDouble.isFinite && fiDouble > 0 {
            progress = start / fiDouble
        } else if fiDouble == 0 {
            progress = 1.0
        } else {
            progress = 0.0
        }

        let path = deterministicPath(start: start, mu: mu, annualContribution: contribution,
                                     annualSpending: spending, contributionYears: contributionYears,
                                     totalYears: totalYears)
        let projected = projectedRetireAge(path: path, fiNumber: fiDouble,
                                           currentAge: config.currentAge)
        let coast = coastFIREAge(start: max(start, 0),
                                 monthlyContribution: config.monthlyContribution.doubleValue,
                                 mu: mu, currentAge: config.currentAge,
                                 retireAge: config.retireAge, fiNumber: fiDouble)

        let mc = MonteCarloSimulator.simulate(startBalance: start,
                                              annualContribution: contribution,
                                              annualWithdrawal: spending,
                                              mu: mu, sigma: sigma,
                                              contributionYears: contributionYears,
                                              totalYears: totalYears,
                                              runs: runs,
                                              seed: monteCarloSeed)

        // Chart axis: calendar years starting from the current year.
        let baseYear = Calendar.current.component(.year, from: Date())
        let years = (0...totalYears).map { baseYear + $0 }

        let deterministic = (0...totalYears).map { i in
            YearPoint(year: baseYear + i,
                      age: Double(config.currentAge + i),
                      value: money(fromDollars: path[i]))
        }

        let bands = MonteCarloBands(years: years,
                                    p10: mc.p10.map { money(fromDollars: $0) },
                                    p25: mc.p25.map { money(fromDollars: $0) },
                                    p50: mc.p50.map { money(fromDollars: $0) },
                                    p75: mc.p75.map { money(fromDollars: $0) },
                                    p90: mc.p90.map { money(fromDollars: $0) })

        return RetirementSnapshot(invested: invested,
                                  fiNumber: money(fromDollars: fiDouble),
                                  progress: progress,
                                  annualSpending: annualSpending,
                                  projectedRetireAge: projected,
                                  coastFIREAge: coast,
                                  deterministic: deterministic,
                                  percentileBands: bands,
                                  successProbability: mc.successProbability)
    }

    // MARK: Deterministic path

    /// Deterministic real-growth path with yearly compounding at µ:
    ///
    ///     v₀ = max(start, 0)
    ///     vᵢ = max(vᵢ₋₁ · max(1 + µ, 0) + flowᵢ, 0)
    ///
    /// where `flowᵢ = +annualContribution` while the year starts before `retireAge`
    /// (i ≤ contributionYears) and `−annualSpending` afterwards. Flows land at year end (after
    /// growth). The floor at 0 mirrors the Monte Carlo ruin clamp: a depleted balance stays 0.
    private static func deterministicPath(start: Double, mu: Double, annualContribution: Double,
                                          annualSpending: Double, contributionYears: Int,
                                          totalYears: Int) -> [Double] {
        var path = [Double](repeating: 0, count: totalYears + 1)
        var value = max(start, 0)
        path[0] = value
        let growth = max(1.0 + mu, 0.0)
        for i in 1..<(totalYears + 1) {
            value *= growth
            value += (i <= contributionYears) ? annualContribution : -annualSpending
            if value < 0 { value = 0 }
            path[i] = value
        }
        return path
    }

    /// Age at which the deterministic path first reaches the FI number, linearly interpolated
    /// between the two bracketing years:
    ///
    ///     age = (currentAge + i − 1) + (fi − vᵢ₋₁) / (vᵢ − vᵢ₋₁)
    ///
    /// Returns `currentAge` when already at/above FI today, nil when the path never crosses
    /// within the horizon.
    private static func projectedRetireAge(path: [Double], fiNumber: Double,
                                           currentAge: Int) -> Double? {
        guard fiNumber.isFinite, let first = path.first else { return nil }
        if first >= fiNumber { return Double(currentAge) }
        for i in 1..<path.count where path[i] >= fiNumber {
            let previous = path[i - 1]
            let delta = path[i] - previous
            let fraction = delta > 0 ? (fiNumber - previous) / delta : 0
            return Double(currentAge + i - 1) + fraction
        }
        return nil
    }

    // MARK: Coast FIRE

    /// Earliest age (searched in monthly steps) at which contributions could STOP and pure
    /// growth at µ would still reach the FI number by `retireAge`.
    ///
    /// While still contributing, the balance advances monthly:
    ///
    ///     bₘ₊₁ = bₘ · (1 + µ)^(1/12) + monthlyContribution
    ///
    /// and at each month m the coast condition is checked:
    ///
    ///     bₘ · (1 + µ)^(yearsRemaining) ≥ fiNumber,   yearsRemaining = (totalMonths − m) / 12
    ///
    /// Returns `currentAge` as a Double when the condition already holds today, and nil when it
    /// fails even at m = totalMonths (i.e. contributing until `retireAge` never reaches FI).
    private static func coastFIREAge(start: Double, monthlyContribution: Double, mu: Double,
                                     currentAge: Int, retireAge: Int,
                                     fiNumber: Double) -> Double? {
        guard fiNumber.isFinite else { return nil }
        let annualGrowth = max(1.0 + mu, 0.0)
        let monthlyGrowth = pow(annualGrowth, 1.0 / 12.0)
        let totalMonths = max((retireAge - currentAge) * 12, 0)
        var balance = start
        for month in 0..<(totalMonths + 1) {
            let yearsRemaining = Double(totalMonths - month) / 12.0
            let coastValue = balance * pow(annualGrowth, yearsRemaining)
            if coastValue >= fiNumber {
                return Double(currentAge) + Double(month) / 12.0
            }
            balance = balance * monthlyGrowth + monthlyContribution
        }
        return nil
    }

    // MARK: Money conversion

    /// Converts a projected balance in whole currency units to `Money`:
    /// `cents = round(dollars · 100)` clamped to [0, 10¹⁵] to keep far from `Int64` overflow.
    /// Non-finite values map to the cap (+∞) or 0 (anything else).
    private static func money(fromDollars dollars: Double) -> Money {
        let cents = dollars * 100.0
        guard cents.isFinite else {
            return Money(cents: cents > 0 ? Int64(maxCents) : 0)
        }
        let clamped = min(max(cents.rounded(), 0), maxCents)
        return Money(cents: Int64(clamped))
    }

    // MARK: Debug invariants

    #if DEBUG
    /// Verifies three engine invariants. Returns human-readable failure descriptions;
    /// an empty array means all checks passed.
    static func sanityChecks() -> [String] {
        var failures: [String] = []

        // 1. Zero-return arithmetic: with µ = 0 (return == inflation) the deterministic path is
        //    plain addition/subtraction: value(retireAge) = start + years·contribution·12, then
        //    value(lifeExpectancy) = that − years·spending.
        var zeroConfig = RetirementConfig()
        zeroConfig.currentAge = 30
        zeroConfig.retireAge = 35
        zeroConfig.lifeExpectancy = 40
        zeroConfig.expectedReturnPct = 3.0
        zeroConfig.inflationPct = 3.0
        zeroConfig.returnStdDevPct = 0.0
        zeroConfig.monthlyContribution = Money(cents: 10_000)        // $100/mo → $1,200/yr
        zeroConfig.annualSpendingOverride = Money(cents: 200_000)    // $2,000/yr
        zeroConfig.withdrawalRatePct = 4.0
        let zeroSnap = snapshot(config: zeroConfig,
                                investedNow: Money(cents: 1_000_000), // $10,000
                                annualSpendingFromBudget: .zero, runs: 8)
        if zeroSnap.deterministic.count != 11 {
            failures.append("zero-return: expected 11 year points, got \(zeroSnap.deterministic.count)")
        } else {
            // $10,000 + 5 × $1,200 = $16,000 at retireAge (index 5).
            if zeroSnap.deterministic[5].value.cents != 1_600_000 {
                failures.append("zero-return: value at retireAge is \(zeroSnap.deterministic[5].value.cents) cents, expected 1600000")
            }
            // $16,000 − 5 × $2,000 = $6,000 at lifeExpectancy (index 10).
            if zeroSnap.deterministic[10].value.cents != 600_000 {
                failures.append("zero-return: value at lifeExpectancy is \(zeroSnap.deterministic[10].value.cents) cents, expected 600000")
            }
        }
        // fiNumber = $2,000 / 0.04 = $50,000.
        if zeroSnap.fiNumber.cents != 5_000_000 {
            failures.append("zero-return: fiNumber is \(zeroSnap.fiNumber.cents) cents, expected 5000000")
        }

        // 2. Success probability is monotonic in contribution: same seed ⇒ identical return
        //    draws, and a pathwise-larger balance can only survive at least as often.
        var base = RetirementConfig()
        base.currentAge = 40
        base.retireAge = 60
        base.lifeExpectancy = 90
        base.expectedReturnPct = 7.0
        base.inflationPct = 3.0
        base.returnStdDevPct = 15.0
        base.withdrawalRatePct = 4.0
        base.annualSpendingOverride = Money(cents: 4_000_000)        // $40,000/yr
        var lowConfig = base
        lowConfig.monthlyContribution = .zero
        var highConfig = base
        highConfig.monthlyContribution = Money(cents: 200_000)       // $2,000/mo
        let investedNow = Money(cents: 5_000_000)                    // $50,000
        let lowSnap = snapshot(config: lowConfig, investedNow: investedNow,
                               annualSpendingFromBudget: .zero, runs: 400)
        let highSnap = snapshot(config: highConfig, investedNow: investedNow,
                                annualSpendingFromBudget: .zero, runs: 400)
        if highSnap.successProbability < lowSnap.successProbability {
            failures.append("monotonic: success \(highSnap.successProbability) with higher contribution < \(lowSnap.successProbability) with lower")
        }

        // 3. Percentile ordering: p25 ≤ p50 ≤ p75 at every year (nearest-rank picks from the
        //    same sorted cross-section, so this must hold exactly).
        let bands = highSnap.percentileBands
        for i in 0..<bands.years.count {
            guard i < bands.p25.count, i < bands.p50.count, i < bands.p75.count else {
                failures.append("percentiles: band arrays shorter than years axis")
                break
            }
            if bands.p25[i].cents > bands.p50[i].cents || bands.p50[i].cents > bands.p75[i].cents {
                failures.append("percentiles: ordering violated at year index \(i): p25=\(bands.p25[i].cents) p50=\(bands.p50[i].cents) p75=\(bands.p75[i].cents)")
                break
            }
        }

        return failures
    }
    #endif
}
