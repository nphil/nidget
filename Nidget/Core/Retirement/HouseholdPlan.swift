import Foundation

// MARK: - Household plan engine
//
// A deterministic, single-path household projection: two earners, two homes, consumer debt, a
// down-payment goal, and a target retirement age. This is the Swift port of Retiron's `project()`
// and `simulateDebt()` (the self-hosted planner this app syncs with), cleaned up where the web
// version hardcoded a constant or spent the same money twice.
//
// MONEY: this engine works in Double DOLLARS from end to end. It mirrors the JavaScript it came
// from, and it is projection-grade rather than ledger-grade: nothing here is a recorded amount,
// every figure is a forecast decades out. Convert to `Money` only at the UI boundary, with
// `Money(clampedDollars:)` at the bottom of this file, so AmountText formats plan numbers exactly
// like the rest of the app. Every Double → Int64 conversion in that initializer is clamped.
//
// Pure math: no UI imports, no I/O, no shared state, everything Sendable. Callers run
// `HouseholdPlanner.project` off the main actor (Task.detached), the same way RetirementView runs
// RetirementPlanner.
//
// Deliberate differences from the web app (it keeps its quirks for now, this port is the clean
// reference):
//  1. Ages, the base calendar year, and the horizon are config fields, not constants.
//  2. The mid-career bonus uses the person's own bonus percent instead of a hardcoded 15%.
//  3. The cost-of-living raise compounds every year up to the promotion.
//  4. Debt payments are allocated sequentially: cards first, whatever is left goes to loans. The
//     web app applies the whole annual budget to cards AND 40% of it again to loans.
//  5. The down-payment pot earns `cashYieldPct` (0 by default, which matches the web app).
//  6. The second earner's raise rates are config instead of hardcoded 2.5% and 3.5%.
//  7. Every remaining constant (RSU haircut, tax table, contribution caps, living factor, and so
//     on) is a config field carrying the web app's current value as its default.
//  8. Free cash is charged only for the debt payments that actually go out. The web app charges
//     the whole annual budget for as long as any balance is open, including the final year when
//     only a few hundred dollars remain, so the two apps' `freeCash` and down-payment pot diverge
//     in the payoff tail years.

// MARK: - Config types

/// One marginal federal bracket: everything up to `upTo` (above the previous bracket's ceiling)
/// is taxed at `ratePct`. The top bracket uses `Double.greatestFiniteMagnitude` rather than
/// infinity so the table stays JSON-encodable.
struct TaxBracket: Codable, Sendable, Equatable {
    var upTo: Double
    var ratePct: Double

    /// The 2025 table the planner ships with, in the same shape the web app uses.
    static let federalDefaults: [TaxBracket] = [
        TaxBracket(upTo: 23_850, ratePct: 10),
        TaxBracket(upTo: 96_950, ratePct: 12),
        TaxBracket(upTo: 206_700, ratePct: 22),
        TaxBracket(upTo: 394_600, ratePct: 24),
        TaxBracket(upTo: 501_050, ratePct: 32),
        TaxBracket(upTo: 751_600, ratePct: 35),
        TaxBracket(upTo: .greatestFiniteMagnitude, ratePct: 37),
    ]
}

/// One earner. `personA` is the primary career track (the one with the promotion path);
/// `personB` is the second earner, who may switch from part time to full time.
///
/// All percents are whole percents (10 means 10%), all balances are dollars. `bonusPct`,
/// `matchPct` and `rsuPct` apply to both people the same way, so a second earner with a bonus is
/// modelled correctly; the Retiron profile simply has no fields for them, so they map to 0.
struct HouseholdPerson: Codable, Sendable, Equatable {
    var name: String
    var age: Int
    var baseSalary: Double
    var bonusPct: Double
    var k401Pct: Double
    var matchPct: Double
    var rsuPct: Double
    var retirementBalance: Double

    /// The primary earner's starting point, matching Retiron's shipped defaults.
    static let defaultPrimary = HouseholdPerson(name: "Nitin", age: 37, baseSalary: 151_000,
                                                bonusPct: 18, k401Pct: 10, matchPct: 10,
                                                rsuPct: 10, retirementBalance: 170_000)

    /// The second earner's starting point, matching Retiron's shipped defaults.
    static let defaultPartner = HouseholdPerson(name: "Isabel", age: 35, baseSalary: 50_000,
                                                bonusPct: 0, k401Pct: 5, matchPct: 0,
                                                rsuPct: 0, retirementBalance: 17_000)
}

/// Every input the projection needs. Defaults are Retiron's shipped defaults, so
/// `HouseholdPlanConfig()` alone produces the same plan the web app shows on a fresh install.
///
/// Naming follows the Retiron input ids one for one (`atl*` = the current Atlanta home,
/// `tac*` = the Tacoma home being bought), which keeps `RetironProfileMapper` easy to audit.
struct HouseholdPlanConfig: Codable, Sendable, Equatable {

    // MARK: People

    var personA: HouseholdPerson = .defaultPrimary
    var personB: HouseholdPerson = .defaultPartner

    // MARK: Horizon

    /// Calendar year of row 0. The Retiron profile has no field for this, so it stays local.
    var baseYear: Int = 2025
    /// Number of projected years (rows).
    var years: Int = 25
    /// The age (of `personA`) the summary reports against.
    var targetRetirementAge: Int = 55

    // MARK: Primary earner's career

    /// Cost-of-living raise, compounded every year until the promotion.
    var colRaisePct: Double = 2.75
    /// Year index of the promotion. Years before it use the base salary plus raises.
    var promoInYears: Int = 2
    var promoBaseSalary: Double = 200_000
    var promoBonusPct: Double = 25
    var promoRSUPct: Double = 20
    /// Annual raise applied to the post-promotion base.
    var promoAnnualRaisePct: Double = 4
    /// Share of granted RSU value left after withholding.
    var rsuNetFactor: Double = 0.72

    // MARK: Second earner

    /// Ceiling on the part-time salary.
    var personBSalaryCap: Double = 70_000
    /// Yearly raise while part time.
    var personBGrowthPct: Double = 2.5
    var personBFullTime: Bool = false
    /// Year index the switch to full time happens.
    var personBFullTimeYear: Int = 4
    var personBFullTimeSalary: Double = 75_000
    var personBFullTimeCap: Double = 100_000
    /// Yearly raise once full time.
    var personBFullTimeGrowthPct: Double = 3.5

    // MARK: Other balances

    var rothBalance: Double = 5_000
    var hsaBalance: Double = 16_000
    /// HSA contributions restart (a future high-deductible plan).
    var hsaRestart: Bool = false
    var hsaStartYear: Int = 3
    var hsaAnnualContribution: Double = 4_150
    /// Cash on hand today; seeds the down-payment pot.
    var liquidCash: Double = 3_000

    // MARK: Goals and rates

    /// Target yearly spending in today's dollars.
    var annualSpend: Double = 100_000
    var investmentReturnPct: Double = 7
    var inflationPct: Double = 3
    /// What the down-payment pot earns while it waits. 0 matches the web app.
    var cashYieldPct: Double = 0
    /// Share of `annualSpend` treated as non-housing living cost (housing is modelled separately).
    var nonHousingLivingFactor: Double = 0.80

    // MARK: Current home (becomes a rental after the move)

    var atlValue: Double = 350_000
    var atlMortgage: Double = 247_000
    /// Monthly payment including taxes and insurance.
    var atlMortgagePaymentMonthly: Double = 1_900
    var atlTaxBumpYear: Int = 2
    var atlTaxBumpMonthly: Double = 150
    var atlAppreciationPct: Double = 4
    /// Principal paid down each year on the existing note.
    var atlPrincipalPerYear: Double = 7_200
    var atlRentYear1Monthly: Double = 2_500
    var atlRentGrowthPct: Double = 3
    /// Management, maintenance and vacancy, per month.
    var atlRentExpensesMonthly: Double = 500

    // MARK: Next home

    var tacPrice: Double = 600_000
    var tacBuyYear: Int = 3
    var tacDownPct: Double = 20
    var tacRatePct: Double = 6.5
    var tacAppreciationPct: Double = 3.5
    var mortgageTermYears: Int = 30

    // MARK: Debt (the coarse annual mirror of the debt simulator)

    var creditCardBalance: Double = 25_000
    var studentLoanBalance: Double = 20_000
    var creditCardAPRPct: Double = 0
    var studentLoanAPRPct: Double = 5
    var monthlyDebtPayment: Double = 2_000

    // MARK: Tax and contribution rules

    var federalBrackets: [TaxBracket] = TaxBracket.federalDefaults
    var standardDeduction: Double = 29_200
    /// State income tax before the move. After it the rate is 0.
    var stateTaxPct: Double = 5.5
    var ficaWageBase: Double = 168_600
    /// Yearly employee cap on the primary earner's 401k contribution.
    var k401Cap: Double = 23_500
    /// Yearly cap on the second earner's contribution (the web app uses the IRA limit here).
    var iraCap: Double = 7_000
}

// MARK: - Output types

/// One projected year. `id` is the year index so SwiftUI lists stay stable while inputs change.
struct HouseholdYear: Sendable, Identifiable, Equatable {
    var id: Int { yearIndex }

    var yearIndex: Int
    var calendarYear: Int
    var ageA: Int
    var ageB: Int

    /// Primary earner's pay, split so the income chart can stack it.
    var baseA: Double
    var bonusA: Double
    var rsuA: Double
    /// Second earner's pay, split the same way (bonus and RSU are 0 in the shipped profile).
    var baseB: Double
    var bonusB: Double
    var rsuB: Double

    var grossIncome: Double
    var takeHome: Double
    var totalTax: Double

    /// Retirement accounts only: 401k + partner's retirement + Roth + HSA.
    var portfolio: Double
    /// Taxable brokerage, which only starts growing once the new home is bought.
    var brokerage: Double
    var netWorth: Double

    var k401A: Double
    var retirementB: Double
    var roth: Double
    var hsa: Double

    var atlValue: Double
    var atlMortgage: Double
    var atlEquity: Double
    var tacValue: Double
    var tacMortgage: Double
    var tacEquity: Double

    var ccBalance: Double
    var slBalance: Double

    var dpSaved: Double
    var dpTarget: Double

    /// Net rent per month once the current home becomes a rental. Can be negative.
    var netRentMonthly: Double
    /// Mortgage (and taxes) actually paid this year, whichever home the household lives in.
    var housingCost: Double
    /// Exact percent, unrounded; the web app rounds to whole percents for display.
    var savingsRatePct: Double
    var freeCash: Double

    var events: [String]
    var inWashington: Bool
    var boughtHome: Bool

    var totalCompA: Double { baseA + bonusA + rsuA }
    var totalCompB: Double { baseB + bonusB + rsuB }
    var totalDebt: Double { ccBalance + slBalance }
    var realEstateEquity: Double { atlEquity + tacEquity }
    /// Everything invested: retirement accounts plus brokerage.
    var liquidPortfolio: Double { portfolio + brokerage }
}

// MARK: - HouseholdPlanner

enum HouseholdPlanner {

    /// The 4% rule: the portfolio needed is 25 times a year of spending.
    static let fiMultiple: Double = 25

    /// Runs the whole projection. One row per year, oldest first, `config.years` rows.
    ///
    /// Order inside a year, kept from the web app so both apps agree:
    /// pay is set, contributions are worked out, accounts grow and then take the contribution
    /// (so a contribution earns nothing in the year it is made), tax is charged, real estate
    /// moves, debt is paid, and whatever is left becomes savings.
    static func project(_ config: HouseholdPlanConfig) -> [HouseholdYear] {
        let rowCount = max(0, config.years)
        guard rowCount > 0 else { return [] }

        let returnRate = config.investmentReturnPct / 100
        let inflationRate = config.inflationPct / 100
        let cashYield = config.cashYieldPct / 100

        // Down payment and the new mortgage are fixed the day the purchase happens.
        let dpTarget = config.tacPrice * config.tacDownPct / 100
        let tacLoan = config.tacPrice - dpTarget
        let tacMortgageMonthly = mortgagePayment(principal: tacLoan,
                                                 annualRatePct: config.tacRatePct,
                                                 years: config.mortgageTermYears)

        var k401A = config.personA.retirementBalance
        var retirementB = config.personB.retirementBalance
        var roth = config.rothBalance
        var hsa = config.hsaBalance
        var brokerage: Double = 0
        var cc = config.creditCardBalance
        var sl = config.studentLoanBalance
        var dpSaved = config.liquidCash
        var atlValue = config.atlValue
        var atlMortgage = config.atlMortgage
        var tacValue: Double = 0
        var tacMortgage: Double = 0
        var boughtHome = false

        var rows: [HouseholdYear] = []
        rows.reserveCapacity(rowCount)

        for yearIndex in 0..<rowCount {
            let ageA = config.personA.age + yearIndex
            let ageB = config.personB.age + yearIndex
            let inWashington = yearIndex >= config.tacBuyYear

            // 1. Primary earner's pay.
            let baseA: Double
            let bonusA: Double
            let rsuA: Double
            if yearIndex == 0 {
                baseA = config.personA.baseSalary
                bonusA = baseA * config.personA.bonusPct / 100
                rsuA = baseA * config.personA.rsuPct / 100 * config.rsuNetFactor
            } else if yearIndex < config.promoInYears {
                // Fix 3: the cost-of-living raise compounds instead of being applied once.
                baseA = config.personA.baseSalary * pow(1 + config.colRaisePct / 100, Double(yearIndex))
                // Fix 2: the person's own bonus percent, not a hardcoded 15%.
                bonusA = baseA * config.personA.bonusPct / 100
                rsuA = baseA * config.personA.rsuPct / 100 * config.rsuNetFactor
            } else {
                let sincePromo = Double(yearIndex - config.promoInYears)
                baseA = config.promoBaseSalary * pow(1 + config.promoAnnualRaisePct / 100, sincePromo)
                bonusA = baseA * config.promoBonusPct / 100
                rsuA = baseA * config.promoRSUPct / 100 * config.rsuNetFactor
            }

            // 2. Second earner's pay. Full time restarts the salary at the full-time figure.
            let baseB: Double
            if config.personBFullTime && yearIndex >= config.personBFullTimeYear {
                let sinceSwitch = Double(yearIndex - config.personBFullTimeYear)
                let grown = config.personBFullTimeSalary
                    * pow(1 + config.personBFullTimeGrowthPct / 100, sinceSwitch)
                baseB = min(grown, config.personBFullTimeCap)
            } else {
                let grown = config.personB.baseSalary
                    * pow(1 + config.personBGrowthPct / 100, Double(yearIndex))
                baseB = min(grown, config.personBSalaryCap)
            }
            let bonusB = baseB * config.personB.bonusPct / 100
            let rsuB = baseB * config.personB.rsuPct / 100 * config.rsuNetFactor

            // 3. Contributions. The second earner is capped by `iraCap`, which is what the web
            //    app does; both apps have to agree, so the quirk is kept and named.
            let contributionA = min(baseA * config.personA.k401Pct / 100, config.k401Cap)
            let matchA = baseA * config.personA.matchPct / 100
            let contributionB = min(baseB * config.personB.k401Pct / 100, config.iraCap)
            let matchB = baseB * config.personB.matchPct / 100
            let hsaContribution = (config.hsaRestart && yearIndex >= config.hsaStartYear)
                ? config.hsaAnnualContribution : 0

            // 4. Growth first, then this year's contribution lands.
            k401A = k401A * (1 + returnRate) + contributionA + matchA
            retirementB = retirementB * (1 + returnRate) + contributionB + matchB
            roth *= (1 + returnRate)
            hsa = hsa * (1 + returnRate) + hsaContribution

            // 5. Tax. RSU income sits outside the taxable estimate, as it does in the web app.
            let wagesA = baseA + bonusA
            let wagesB = baseB + bonusB
            let taxable = max(0, wagesA - contributionA - hsaContribution + wagesB
                              - config.standardDeduction)
            let federal = federalTax(taxableIncome: taxable, brackets: config.federalBrackets)
            let state = inWashington ? 0 : (wagesA + wagesB) * config.stateTaxPct / 100
            let fica = min(wagesA, config.ficaWageBase) * Self.socialSecurityRate
                + wagesA * Self.medicareRate
                + min(wagesB, config.ficaWageBase) * Self.socialSecurityRate
                + wagesB * Self.medicareRate
            let totalTax = federal + state + fica

            // 6. The current home.
            atlValue *= (1 + config.atlAppreciationPct / 100)
            atlMortgage = max(0, atlMortgage - config.atlPrincipalPerYear)
            let atlEquity = atlValue - atlMortgage
            let taxBumpMonthly = yearIndex >= config.atlTaxBumpYear ? config.atlTaxBumpMonthly : 0
            let atlPaymentThisYear = (config.atlMortgagePaymentMonthly + taxBumpMonthly) * 12

            // 7. Rent, once the household has moved out of it.
            var netRentMonthly: Double = 0
            if inWashington {
                let rentYear = Double(yearIndex - config.tacBuyYear)
                let grossRent = config.atlRentYear1Monthly
                    * pow(1 + config.atlRentGrowthPct / 100, rentYear)
                netRentMonthly = grossRent - config.atlRentExpensesMonthly
                    - (config.atlMortgagePaymentMonthly + taxBumpMonthly)
            }
            let netRentAnnual = netRentMonthly * 12

            // 8. The new home: bought once, then appreciating and paying itself down.
            if yearIndex == config.tacBuyYear && !boughtHome {
                boughtHome = true
                tacValue = config.tacPrice
                tacMortgage = tacLoan
            }
            if boughtHome {
                tacValue *= (1 + config.tacAppreciationPct / 100)
                // Interest is approximated off the original loan, so principal is flat.
                let principal = tacMortgageMonthly * 12 - tacLoan * (config.tacRatePct / 100) * 0.95
                tacMortgage = max(0, tacMortgage - max(0, principal))
            }
            let tacEquity = max(0, tacValue - tacMortgage)

            // 9. Debt. Fix 4: one budget, spent in order, cards first.
            let debtBudget = (cc > 0 || sl > 0) ? config.monthlyDebtPayment * 12 : 0
            var debtRemaining = debtBudget
            let ccWasOpen = cc > 0
            let slWasOpen = sl > 0
            if cc > 0 {
                let payment = min(cc, debtRemaining)
                cc = max(0, cc * (1 + config.creditCardAPRPct / 100) - payment)
                if cc < 1 { cc = 0 }
                debtRemaining -= payment
            }
            if sl > 0 {
                let payment = min(sl, debtRemaining)
                sl = max(0, sl * (1 + config.studentLoanAPRPct / 100) - payment)
                if sl < 1 { sl = 0 }
                debtRemaining -= payment
            }
            // Only the money that actually went out counts against cash flow.
            let debtPaid = debtBudget - max(0, debtRemaining)

            // 10. Cash flow.
            let grossIncome = baseA + bonusA + rsuA + baseB + bonusB + rsuB
            let takeHome = grossIncome - totalTax - contributionA - contributionB - hsaContribution
            let housingCost = boughtHome ? tacMortgageMonthly * 12 : atlPaymentThisYear
            let living = config.annualSpend * pow(1 + inflationRate, Double(yearIndex))
                * config.nonHousingLivingFactor
            let freeCash = takeHome - housingCost - living - debtPaid + netRentAnnual
            if boughtHome {
                brokerage = brokerage * (1 + returnRate) + max(0, freeCash)
            } else {
                // Fix 5: the pot earns whatever the cash account pays while it waits.
                dpSaved = dpSaved * (1 + cashYield) + max(0, freeCash)
            }

            // 11. Totals.
            let portfolio = k401A + retirementB + roth + hsa
            let netWorth = portfolio + brokerage + atlEquity + tacEquity - cc - sl
            let saved = contributionA + contributionB + hsaContribution + max(0, freeCash)
            let savingsRatePct = grossIncome > 0 ? saved / grossIncome * 100 : 0

            // 12. Events worth marking on the timeline.
            var events: [String] = []
            if yearIndex == 0 { events.append("Start") }
            if yearIndex == config.promoInYears { events.append("Promotion") }
            if yearIndex == config.tacBuyYear { events.append("New home") }
            if yearIndex == config.atlTaxBumpYear { events.append("Property tax up") }
            if config.personBFullTime && yearIndex == config.personBFullTimeYear {
                events.append("\(config.personB.name) full time")
            }
            if config.hsaRestart && yearIndex == config.hsaStartYear { events.append("HSA restarts") }
            if ccWasOpen && cc == 0 { events.append("Cards clear") }
            if slWasOpen && sl == 0 { events.append("Loans clear") }
            if ageA == config.targetRetirementAge {
                events.append("\(config.personA.name) turns \(config.targetRetirementAge)")
            }
            if ageB == config.targetRetirementAge {
                events.append("\(config.personB.name) turns \(config.targetRetirementAge)")
            }

            rows.append(HouseholdYear(yearIndex: yearIndex,
                                      calendarYear: config.baseYear + yearIndex,
                                      ageA: ageA, ageB: ageB,
                                      baseA: baseA, bonusA: bonusA, rsuA: rsuA,
                                      baseB: baseB, bonusB: bonusB, rsuB: rsuB,
                                      grossIncome: grossIncome, takeHome: takeHome,
                                      totalTax: totalTax,
                                      portfolio: portfolio, brokerage: brokerage,
                                      netWorth: netWorth,
                                      k401A: k401A, retirementB: retirementB,
                                      roth: roth, hsa: hsa,
                                      atlValue: atlValue, atlMortgage: atlMortgage,
                                      atlEquity: atlEquity,
                                      tacValue: tacValue, tacMortgage: tacMortgage,
                                      tacEquity: tacEquity,
                                      ccBalance: cc, slBalance: sl,
                                      dpSaved: dpSaved, dpTarget: dpTarget,
                                      netRentMonthly: netRentMonthly,
                                      housingCost: housingCost,
                                      savingsRatePct: savingsRatePct,
                                      freeCash: freeCash,
                                      events: events,
                                      inWashington: inWashington,
                                      boughtHome: boughtHome))
        }
        return rows
    }

    /// The headline numbers the Overview reads.
    ///
    /// - `fiTarget`: a year of spending, inflated to the target age, times `fiMultiple`
    ///   (25 by default, the 4% rule; callers with a personal withdrawal rate pass
    ///   `100 / withdrawalRatePct` so both engines agree on what "enough" means).
    /// - `portfolioAtTarget`: retirement accounts plus brokerage in the target year.
    /// - `fiPct`: portfolio as a percent of the target (exact, the UI rounds).
    /// - `netWorthAtTarget`: everything, including home equity, minus debt.
    /// - `debtFreeYearIndex`: first year with no cards and no loans left, nil if there is none.
    /// - `dpHitYearIndex`: first year the down-payment pot covers the target, nil if it never does.
    ///
    /// Falls back to the last row when the target age sits past the horizon.
    static func fiSummary(rows: [HouseholdYear], config: HouseholdPlanConfig,
                          fiMultiple: Double = 25)
    -> (fiTarget: Double, portfolioAtTarget: Double, fiPct: Double, netWorthAtTarget: Double,
        debtFreeYearIndex: Int?, dpHitYearIndex: Int?) {
        let yearsToTarget = max(0, config.targetRetirementAge - config.personA.age)
        let fiTarget = config.annualSpend
            * pow(1 + config.inflationPct / 100, Double(yearsToTarget))
            * fiMultiple

        let targetRow = rows.first { $0.ageA == config.targetRetirementAge } ?? rows.last
        let portfolioAtTarget = targetRow?.liquidPortfolio ?? 0
        let netWorthAtTarget = targetRow?.netWorth ?? 0
        let fiPct = fiTarget > 0 ? portfolioAtTarget / fiTarget * 100 : 0

        let debtFreeYearIndex = rows.first { $0.totalDebt <= 0 }?.yearIndex
        let dpHitYearIndex = rows.first { $0.dpSaved >= $0.dpTarget && $0.dpTarget > 0 }?.yearIndex

        return (fiTarget: fiTarget, portfolioAtTarget: portfolioAtTarget, fiPct: fiPct,
                netWorthAtTarget: netWorthAtTarget, debtFreeYearIndex: debtFreeYearIndex,
                dpHitYearIndex: dpHitYearIndex)
    }

    // MARK: Shared math

    /// Level monthly payment on an amortizing loan:
    ///
    ///     r = annualRatePct / 12 / 100,  n = years · 12
    ///     payment = P · r · (1 + r)ⁿ / ((1 + r)ⁿ − 1)
    ///
    /// A zero rate divides the principal evenly; a zero term returns 0.
    static func mortgagePayment(principal: Double, annualRatePct: Double, years: Int) -> Double {
        let months = Double(max(0, years) * 12)
        guard months > 0, principal > 0 else { return 0 }
        let rate = annualRatePct / 12 / 100
        guard rate != 0 else { return principal / months }
        let growth = pow(1 + rate, months)
        guard growth > 1 else { return principal / months }
        return principal * rate * growth / (growth - 1)
    }

    /// Marginal federal tax over `brackets`, each bracket taxing the slice between the previous
    /// ceiling and its own. Negative income is treated as zero.
    static func federalTax(taxableIncome: Double, brackets: [TaxBracket]) -> Double {
        let income = max(0, taxableIncome)
        var tax: Double = 0
        var previousCeiling: Double = 0
        for bracket in brackets {
            if income <= previousCeiling { break }
            tax += (min(income, bracket.upTo) - previousCeiling) * bracket.ratePct / 100
            previousCeiling = bracket.upTo
        }
        return tax
    }

    /// Employee share of Social Security, charged up to `ficaWageBase`.
    private static let socialSecurityRate: Double = 0.062
    /// Employee share of Medicare, charged on every dollar.
    private static let medicareRate: Double = 0.0145

    // MARK: Debug invariants

    #if DEBUG
    /// Checks a handful of engine invariants by hand-computable arithmetic. Returns readable
    /// failures; an empty array means everything held.
    static func sanityChecks() -> [String] {
        var failures: [String] = []

        // 1. Shape: one row per year, the calendar and the ages both marching by one.
        let config = HouseholdPlanConfig()
        let rows = project(config)
        if rows.count != config.years {
            failures.append("shape: expected \(config.years) rows, got \(rows.count)")
        } else {
            if rows[0].calendarYear != config.baseYear {
                failures.append("shape: first row is \(rows[0].calendarYear), expected \(config.baseYear)")
            }
            let lastAge = config.personA.age + config.years - 1
            if rows[config.years - 1].ageA != lastAge {
                failures.append("shape: last age is \(rows[config.years - 1].ageA), expected \(lastAge)")
            }
            // 20% of $600,000.
            if rows[0].dpTarget != 120_000 {
                failures.append("down payment: target is \(rows[0].dpTarget), expected 120000")
            }
        }

        // 2. Brackets: the first bracket taxes its whole slice at 10%, the second picks up at 12%.
        let brackets = TaxBracket.federalDefaults
        if abs(federalTax(taxableIncome: 23_850, brackets: brackets) - 2_385) > 0.01 {
            failures.append("tax: 23850 taxed as \(federalTax(taxableIncome: 23_850, brackets: brackets)), expected 2385")
        }
        if abs(federalTax(taxableIncome: 30_000, brackets: brackets) - 3_123) > 0.01 {
            failures.append("tax: 30000 taxed as \(federalTax(taxableIncome: 30_000, brackets: brackets)), expected 3123")
        }

        // 3. Debt: $1,000 at 0% with $100 a month clears in ten months and costs no interest.
        let loan = DebtAccount(id: "loan", name: "Loan", balance: 1_000, aprPct: 0,
                               minPay: 0, kind: .loan)
        let result = DebtSimulator.simulate(accounts: [loan], monthlyBudget: 100,
                                            strategy: .avalanche, balanceTransfer: nil)
        if result.payoffMonths != 10 {
            failures.append("debt: paid off in \(result.payoffMonths) months, expected 10")
        }
        if result.totalInterest != 0 {
            failures.append("debt: charged \(result.totalInterest) interest at 0%, expected 0")
        }

        return failures
    }
    #endif
}

// MARK: - Debt types

/// One account in the monthly debt simulation. Balances and payments are dollars, rates are
/// whole annual percents.
struct DebtAccount: Codable, Sendable, Equatable, Identifiable {

    /// What kind of account this is. Only labelling and grouping depend on it; the simulation
    /// treats all three the same way.
    enum Kind: String, Codable, Sendable {
        case card
        case loan
        case heloc
    }

    var id: String
    var name: String
    var balance: Double
    /// Rate charged today. A card inside a 0% promo carries 0 here.
    var aprPct: Double
    /// Months from now until a promo rate ends. 0 means there is no promo.
    var promoEndMonth: Int
    /// Rate that takes over when the promo ends.
    var postPromoAPRPct: Double
    var minPay: Double
    var kind: Kind

    init(id: String, name: String, balance: Double, aprPct: Double, promoEndMonth: Int = 0,
         postPromoAPRPct: Double = 0, minPay: Double, kind: Kind) {
        self.id = id
        self.name = name
        self.balance = balance
        self.aprPct = aprPct
        self.promoEndMonth = promoEndMonth
        self.postPromoAPRPct = postPromoAPRPct
        self.minPay = minPay
        self.kind = kind
    }
}

/// Payoff order. `custom` keeps the order the accounts were handed over in.
enum DebtStrategy: String, Codable, Sendable {
    case avalanche
    case snowball
    case custom
}

/// A 0% balance-transfer card taking on part of the card debt. The fee is added to the balance
/// the day the transfer happens.
struct BalanceTransfer: Codable, Sendable, Equatable {
    var amount: Double
    var feePct: Double
    var promoMonths: Int
    var postPromoAPRPct: Double
    var monthlyPayment: Double
}

/// One month of the payoff schedule. Balances are read at the START of the month, before that
/// month's interest and payment, so row 0 shows today's balances and the last row shows zero.
struct DebtMonth: Sendable, Identifiable, Equatable {
    var id: Int { monthIndex }

    var monthIndex: Int
    /// First day of the calendar month this row covers, for the UI to format.
    var date: Date
    /// Account id to balance at the start of the month.
    var balances: [String: Double]
    var transferBalance: Double
    /// Every balance above, added up.
    var totalBalance: Double
    /// Interest charged during this month alone.
    var interest: Double
    /// Money actually paid during this month.
    var payment: Double
}

struct DebtSimResult: Sendable, Equatable {
    var schedule: [DebtMonth]
    /// Months until everything is paid off, capped at the simulation limit.
    var payoffMonths: Int
    /// Interest charged over the whole run. Each month is counted once. (The web app sums a
    /// running total every month, which counts early interest again and again.)
    var totalInterest: Double
}

// MARK: - DebtSimulator

enum DebtSimulator {

    /// Ten years is as far as the schedule runs.
    static let maxMonths = 120

    /// Month-by-month payoff simulation.
    ///
    /// Each month, in order: promo rates that have expired switch to their post-promo rate,
    /// balances are recorded, interest is charged, every account takes its minimum payment, the
    /// transfer card takes its own payment, and whatever budget is left is poured onto the front
    /// of the payoff queue. Minimums are always paid even when they add up to more than the
    /// budget, which is what really happens.
    static func simulate(accounts: [DebtAccount], monthlyBudget: Double, strategy: DebtStrategy,
                         balanceTransfer: BalanceTransfer?) -> DebtSimResult {
        var debts = accounts.map { Working(account: $0) }

        // A transfer takes balance off the highest-rate cards first, then carries its fee.
        var transferBalance: Double = 0
        if let transfer = balanceTransfer, transfer.amount > 0 {
            var moving = transfer.amount
            let order = debts.indices
                .filter { debts[$0].kind == .card && debts[$0].balance > 0 }
                .sorted { left, right in
                    let leftRate = max(debts[left].postPromoAPRPct, debts[left].aprPct)
                    let rightRate = max(debts[right].postPromoAPRPct, debts[right].aprPct)
                    if leftRate == rightRate { return debts[left].id < debts[right].id }
                    return leftRate > rightRate
                }
            for index in order where moving > 0 {
                let moved = min(debts[index].balance, moving)
                debts[index].balance -= moved
                moving -= moved
            }
            transferBalance = transfer.amount * (1 + transfer.feePct / 100)
        }

        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month],
                                                                                    from: Date()))
            ?? Date()
        var schedule: [DebtMonth] = []
        var totalInterest: Double = 0

        for monthIndex in 0..<maxMonths {
            // Promo rates that have run out.
            for index in debts.indices where debts[index].promoEndMonth > 0
                && monthIndex >= debts[index].promoEndMonth {
                debts[index].aprPct = debts[index].postPromoAPRPct
            }

            var balances: [String: Double] = [:]
            var openTotal: Double = 0
            for debt in debts {
                let balance = max(0, debt.balance)
                balances[debt.id] = balance
                openTotal += balance
            }
            let startTotal = openTotal + max(0, transferBalance)
            let date = Calendar.current.date(byAdding: .month, value: monthIndex, to: monthStart)
                ?? monthStart

            // Under a dollar left is paid off. The zero row closes out the chart.
            if startTotal < 1 {
                schedule.append(DebtMonth(monthIndex: monthIndex, date: date, balances: balances,
                                          transferBalance: max(0, transferBalance),
                                          totalBalance: startTotal, interest: 0, payment: 0))
                break
            }

            // Interest for this month only.
            var monthInterest: Double = 0
            for index in debts.indices where debts[index].balance > 0 {
                let interest = debts[index].balance * debts[index].aprPct / 100 / 12
                debts[index].balance += interest
                monthInterest += interest
            }
            if let transfer = balanceTransfer, transferBalance > 0 {
                let inPromo = monthIndex < transfer.promoMonths
                let interest = inPromo ? 0 : transferBalance * transfer.postPromoAPRPct / 100 / 12
                transferBalance += interest
                monthInterest += interest
            }
            totalInterest += monthInterest

            // Retiron fixes the payoff queue right after interest is charged, before minimums
            // are deducted, so snowball ranks on the post-interest balance.
            let order = payoffOrder(debts, strategy: strategy, monthIndex: monthIndex)

            // Minimums first, then the transfer card, then everything left over.
            var budget = monthlyBudget
            var paid: Double = 0
            for index in debts.indices where debts[index].balance > 0 {
                let payment = min(debts[index].balance, max(0, debts[index].minPay))
                debts[index].balance -= payment
                budget -= payment
                paid += payment
            }
            if let transfer = balanceTransfer, transferBalance > 0 {
                let payment = min(transferBalance, max(0, transfer.monthlyPayment))
                transferBalance -= payment
                budget -= payment
                paid += payment
            }
            if budget > 0 {
                for index in order {
                    guard budget > 0 else { break }
                    guard debts[index].balance > 0 else { continue }
                    let payment = min(debts[index].balance, budget)
                    debts[index].balance -= payment
                    budget -= payment
                    paid += payment
                }
            }
            for index in debts.indices where debts[index].balance < 0 {
                debts[index].balance = 0
            }
            if transferBalance < 0 { transferBalance = 0 }

            schedule.append(DebtMonth(monthIndex: monthIndex, date: date, balances: balances,
                                      transferBalance: max(0, transferBalance),
                                      totalBalance: startTotal, interest: monthInterest,
                                      payment: paid))
        }

        return DebtSimResult(schedule: schedule,
                             payoffMonths: schedule.last?.monthIndex ?? 0,
                             totalInterest: totalInterest)
    }

    /// Indices of the open debts in the order the extra money should hit them. Avalanche looks
    /// ahead: a card still inside its promo is ranked by the rate it is about to jump to. Ties
    /// break on id so the same inputs always give the same schedule.
    private static func payoffOrder(_ debts: [Working], strategy: DebtStrategy,
                                    monthIndex: Int) -> [Int] {
        let open = debts.indices.filter { debts[$0].balance > 0 }
        switch strategy {
        case .avalanche:
            return open.sorted { left, right in
                let leftRate = debts[left].promoEndMonth > monthIndex
                    ? debts[left].postPromoAPRPct : debts[left].aprPct
                let rightRate = debts[right].promoEndMonth > monthIndex
                    ? debts[right].postPromoAPRPct : debts[right].aprPct
                if leftRate == rightRate { return debts[left].id < debts[right].id }
                return leftRate > rightRate
            }
        case .snowball:
            return open.sorted { left, right in
                if debts[left].balance == debts[right].balance {
                    return debts[left].id < debts[right].id
                }
                return debts[left].balance < debts[right].balance
            }
        case .custom:
            return open
        }
    }

    /// Mutable copy of a `DebtAccount` for the run.
    private struct Working {
        var id: String
        var balance: Double
        var aprPct: Double
        var promoEndMonth: Int
        var postPromoAPRPct: Double
        var minPay: Double
        var kind: DebtAccount.Kind

        init(account: DebtAccount) {
            id = account.id
            balance = max(0, account.balance)
            aprPct = account.aprPct
            promoEndMonth = max(0, account.promoEndMonth)
            postPromoAPRPct = account.postPromoAPRPct
            minPay = account.minPay
            kind = account.kind
        }
    }
}

// MARK: - Destinations

/// A place the household could retire to, with what a year there costs in today's dollars.
struct Destination: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }

    var name: String
    var flag: String
    var city: String
    /// A year of living costs in today's dollars.
    var annualCost: Double
    var blurb: String

    /// The six places Retiron ships with.
    static let defaults: [Destination] = [
        Destination(name: "Portugal", flag: "🇵🇹", city: "Lisbon or Porto", annualCost: 60_000,
                    blurb: "The old tax break has ended, but the numbers still work. Around 2,500 to 3,000 euros a month buys a comfortable life, and the healthcare is excellent."),
        Destination(name: "Mexico", flag: "🇲🇽", city: "Mexico City or Oaxaca", annualCost: 42_000,
                    blurb: "About $3,500 a month goes a long way here, and it is a short flight home. No long stay visa needed."),
        Destination(name: "Thailand", flag: "🇹🇭", city: "Chiang Mai or Phuket", annualCost: 36_000,
                    blurb: "About $3,000 a month covers a good life, and the long term residence visa is open to savers."),
        Destination(name: "Spain", flag: "🇪🇸", city: "Valencia or Malaga", annualCost: 55_000,
                    blurb: "Around 4,500 euros a month. The non lucrative visa is the usual way in for people living off savings."),
        Destination(name: "Colombia", flag: "🇨🇴", city: "Medellin", annualCost: 38_000,
                    blurb: "Spring weather all year and about $3,200 a month. The pensionado visa opens up after 55."),
        Destination(name: "Washington", flag: "🇺🇸", city: "Tacoma and the Puget Sound",
                    annualCost: 100_000,
                    blurb: "No state income tax, familiar systems, and the Tacoma house stays. Rent from Atlanta covers part of the year."),
    ]
}

/// What one destination costs and how long the portfolio lasts there.
struct DestinationRunway: Sendable, Equatable {
    /// Yearly cost inflated to the target age.
    var adjustedCost: Double
    /// What is left for the portfolio to cover after rental income.
    var netNeed: Double
    /// Years the portfolio covers that need, capped at `DestinationMath.maxRunwayYears`.
    var runwayYears: Double
    /// Portfolio as a percent of 25 times the net need.
    var coveragePct: Double
}

enum DestinationMath {

    /// Runway stops being a useful number past 60 years.
    static let maxRunwayYears: Double = 60

    /// Costs and runway for one destination:
    ///
    ///     adjustedCost = annualCost · (1 + inflation)^yearsToTarget
    ///     netNeed      = max(0, adjustedCost − rental income at the target age)
    ///     runway       = min(60, portfolio ÷ netNeed)
    ///     coverage     = portfolio ÷ (netNeed · 25) · 100
    ///
    /// A need of zero (rent covers everything) reads as full coverage and the maximum runway.
    /// Runway here is plain division: no growth, no inflation during the drawdown.
    static func runway(destination: Destination, portfolioAtTarget: Double,
                       netRentAnnualAtTarget: Double, inflationPct: Double,
                       yearsToTarget: Int) -> DestinationRunway {
        let inflation = pow(1 + inflationPct / 100, Double(max(0, yearsToTarget)))
        let adjustedCost = destination.annualCost * inflation
        let netNeed = max(0, adjustedCost - netRentAnnualAtTarget)
        guard netNeed > 0 else {
            return DestinationRunway(adjustedCost: adjustedCost, netNeed: 0,
                                     runwayYears: maxRunwayYears, coveragePct: 100)
        }
        let portfolio = max(0, portfolioAtTarget)
        return DestinationRunway(adjustedCost: adjustedCost,
                                 netNeed: netNeed,
                                 runwayYears: min(maxRunwayYears, portfolio / netNeed),
                                 coveragePct: portfolio / (netNeed * HouseholdPlanner.fiMultiple) * 100)
    }
}

// MARK: - Money at the UI boundary

extension Money {
    /// Plan dollars → `Money`, for AmountText. `cents = round(dollars · 100)` clamped to
    /// ±10¹⁵ cents so a runaway projection can never overflow `Int64`; anything not finite
    /// becomes the cap or zero.
    init(clampedDollars dollars: Double) {
        let limit: Double = 1e15
        let cents = dollars * 100
        guard cents.isFinite else {
            self.init(cents: cents > 0 ? Int64(limit) : 0)
            return
        }
        self.init(cents: Int64(min(max(cents.rounded(), -limit), limit)))
    }
}
