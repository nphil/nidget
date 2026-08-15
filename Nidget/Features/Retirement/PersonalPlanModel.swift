import Foundation
import Observation
import os

// MARK: - PersonalPlanResult
//
// The planner result plus the exact config it was computed with, so chart adornments always
// agree with the plotted data even mid-debounce. Lifted out of RetirementView so the glance,
// the What If playground, and the lever rows all read the one computed plan.

struct PersonalPlanResult: Sendable {
    var snapshot: RetirementSnapshot
    /// The EFFECTIVE config the planner ran (draft + spending delta folded in).
    var config: RetirementConfig
    /// Last-12-months outflow the spending average and delta baseline derive from.
    var derivedAnnualSpending: Money
    /// The spending delta (currency units/month) this result reflects.
    var spendDelta: Double
    /// Projected crossing age with the spending delta zeroed (equal to the snapshot's own when
    /// the delta is zero). Drives the computed spending sentence.
    var baselineProjectedAge: Double?
    var levers: RetirementLeverOutcomes
}

// MARK: - PersonalPlanModel
//
// The personal planner's state and pipeline, lifted verbatim from RetirementView so the glance
// and every drill-in share one plan without any binding plumbing.
//
// Data flow is unchanged: the SAVED config comes from `Preferences.retirementConfigJSON`; the
// sliders edit a DRAFT (retire age / monthly contribution / expected return / spending delta)
// layered on top. Any change to the draft, the saved config, or account balances re-runs the
// planner on ONE detached task, the main snapshot (1,000 Monte Carlo runs) plus the delta-zero
// baseline and the three lever variants (300 runs each; the projected age is deterministic-path
// math, so run count does not change it), debounced 250 ms once a first plan exists
// (LESSONS_FROM_STASHY, part 1: debounce query changes; dedupe with cancellation guards so a
// stale task never clobbers a newer result). `saveDraft` persists the draft (folding a nonzero
// spending delta into the override and contribution) back to Preferences, whose change reseeds
// the draft.
//
// Wiring contract for the owning view (the model stays passive so nothing new runs on the main
// actor):
//   .task(id: model.computeKey) { await model.recompute() }
//   .onChange(of: preferences.retirementConfigJSON) { _, _ in model.reloadSavedConfig() }
//   .task(id: model.savedConfig.linkedAccountIDs) { await model.refreshDetectedContribution() }
//   .task { await model.refreshActualMonthlySpend() }   // available even when unconfigured
// Animations moved to the view layer: the model sets state plainly and views attach
// `.animation(_:value:)` where they want motion.

@MainActor @Observable
final class PersonalPlanModel {

    private static let log = Logger(subsystem: "app.nidget", category: "retire")

    private let store: AppStore
    private let preferences: Preferences

    /// Decoded mirror of `Preferences.retirementConfigJSON`, kept current via `reloadSavedConfig`.
    private(set) var savedConfig: RetirementConfig
    /// What-if draft values (the slider-editable fields). Views bind straight to them.
    var draftRetireAge: Double
    var draftContribution: Double   // whole currency units per month
    var draftReturn: Double
    /// Spending delta in whole currency units per month; negative = spend less. It moves BOTH
    /// the retirement-spending assumption and the contribution (money not spent is money saved).
    var draftSpendDelta: Double = 0

    private(set) var plan: PersonalPlanResult?
    private(set) var isRecomputing = false
    /// A lever was just tapped, so the What If sheet should open on the seeded draft. Cleared
    /// once the draft is saved or reset.
    var pendingLeverSeed = false
    @ObservationIgnored private var lastComputedKey: ComputeKey?

    /// Monthly contribution detected from transfers into the linked accounts; nil = none found.
    private(set) var detectedContribution: Money?

    /// What the household actually spends: last-12-months outflow divided by 12. Refreshed on
    /// every recompute and loadable on its own, so the Spending tile works even unconfigured.
    private(set) var actualMonthlySpend: Money?

    /// On-device plan narrative ("In plain words"); nil until requested.
    private(set) var planSummary: String?
    private(set) var isExplaining = false
    /// Bumped to abandon any in-flight explanation (stale plan or a newer request).
    @ObservationIgnored private var explainToken = 0

    init(store: AppStore = .shared, preferences: Preferences = .shared) {
        self.store = store
        self.preferences = preferences
        let config = RetirementConfigCodec.decode(preferences.retirementConfigJSON)
        savedConfig = config
        draftRetireAge = Double(config.retireAge)
        draftContribution = max(Double(config.monthlyContribution.cents) / 100.0, 0)
        draftReturn = config.expectedReturnPct
    }

    // MARK: Derived state

    /// Everything a recompute depends on; used as the owning view's `.task(id:)` key.
    struct ComputeKey: Equatable {
        var configJSON: String
        var accounts: [Account]
        var retireAge: Double
        var contribution: Double
        var expectedReturn: Double
        var spendDelta: Double
    }

    /// What the single detached compute task hands back.
    private struct DetachedPlan: Sendable {
        var snapshot: RetirementSnapshot
        var levers: RetirementLeverOutcomes
        var baselineProjectedAge: Double?
    }

    var computeKey: ComputeKey {
        ComputeKey(configJSON: preferences.retirementConfigJSON,
                   accounts: store.accounts,
                   retireAge: draftRetireAge,
                   contribution: draftContribution,
                   expectedReturn: draftReturn,
                   spendDelta: draftSpendDelta)
    }

    /// Saved config with the three plain slider fields layered on top. The spending delta is
    /// folded in later (in `recompute`/`saveDraft`) because it needs the derived annual spend.
    private var draftConfig: RetirementConfig {
        var config = savedConfig
        config.retireAge = Self.clampedInt(draftRetireAge, min: 0, max: 150)
        config.monthlyContribution = Self.money(fromDollars: draftContribution)
        config.expectedReturnPct = draftReturn
        return config
    }

    var hasSpendDelta: Bool { abs(draftSpendDelta) > 0.5 }

    var draftDiffers: Bool {
        let draft = draftConfig
        return draft.retireAge != savedConfig.retireAge
            || draft.monthlyContribution != savedConfig.monthlyContribution
            || abs(draft.expectedReturnPct - savedConfig.expectedReturnPct) > 0.0001
            || hasSpendDelta
    }

    /// Nothing to plan with: no linked accounts AND no outside assets.
    var isUnconfigured: Bool {
        savedConfig.linkedAccountIDs.isEmpty && savedConfig.extraAssets == .zero
    }

    /// The three lever outcomes the "What would help" rows render; nil until a plan exists.
    var leverOutcomes: RetirementLeverOutcomes? { plan?.levers }

    /// Something can write the explanation: either the phone's Apple model or a downloaded one.
    /// The "In plain words" card exists only then.
    var canExplainPlan: Bool {
        AIModelManager.shared.generationReady
    }

    // MARK: Saved config

    /// Re-reads the saved config after `preferences.retirementConfigJSON` changes and reseeds
    /// the drafts, exactly as RetirementView's onChange did (its own save included).
    func reloadSavedConfig() {
        let config = RetirementConfigCodec.decode(preferences.retirementConfigJSON)
        savedConfig = config
        seedDrafts(from: config)
    }

    /// Reseeds every draft from the saved config, discarding all what-if changes.
    func resetDrafts() {
        seedDrafts(from: savedConfig)
        pendingLeverSeed = false
    }

    private func seedDrafts(from config: RetirementConfig) {
        draftRetireAge = Double(config.retireAge)
        draftContribution = max(Double(config.monthlyContribution.cents) / 100.0, 0)
        draftReturn = config.expectedReturnPct
        draftSpendDelta = 0
    }

    // MARK: Lever application

    func applySaveMoreLever() {
        draftContribution = min(draftContribution + RetirementLeverMath.leverDollars.doubleValue, 10_000)
        pendingLeverSeed = true
    }

    func applySpendLessLever() {
        draftSpendDelta = max(draftSpendDelta - RetirementLeverMath.leverDollars.doubleValue, -1_000)
        pendingLeverSeed = true
    }

    func applyEarnMoreLever() {
        draftReturn = min(draftReturn + RetirementLeverMath.leverReturnStep, 12)
        pendingLeverSeed = true
    }

    // MARK: Draft persistence

    func saveDraft() {
        var config = draftConfig
        if hasSpendDelta, let plan {
            // Fold the spending delta into the persistent fields, both ways it acts: the
            // retirement-spending override moves by delta x 12, and the freed (or consumed)
            // money moves the contribution the opposite way.
            let delta = Self.signedMoney(fromDollars: draftSpendDelta)
            let baseAnnual = savedConfig.annualSpendingOverride ?? plan.derivedAnnualSpending
            config.annualSpendingOverride = Money(cents: max(baseAnnual.cents + delta.cents * 12, 0))
            config.monthlyContribution = Money(cents: max(config.monthlyContribution.cents - delta.cents, 0))
        }
        guard let json = RetirementConfigCodec.encode(config) else {
            Haptics.warning()
            return
        }
        preferences.retirementConfigJSON = json
        pendingLeverSeed = false
        Haptics.success()
    }

    // MARK: Recompute

    func recompute() async {
        guard !isUnconfigured else { return }
        let key = computeKey
        // Reappearing with an up-to-date plan (tab switch) shouldn't burn another simulation.
        if plan != nil, lastComputedKey == key { return }

        if plan != nil {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            isRecomputing = true
        }

        let baseConfig = draftConfig
        let linked = Set(baseConfig.linkedAccountIDs)
        let investedNow = store.accounts
            .filter { linked.contains($0.id) }
            .reduce(Money.zero) { $0 + $1.balance }

        let series = await store.monthlySpendSeries(monthsBack: 12)
        guard !Task.isCancelled else { return }
        let annualSpending = series.reduce(Money.zero) { $0 + $1.1.magnitude }
        actualMonthlySpend = Money(cents: annualSpending.cents / 12)

        // Fold the spending delta into the effective config: the retirement-spending target
        // moves by delta x 12, and the freed (or consumed) money moves the contribution.
        let spendDelta = draftSpendDelta
        let hasDelta = abs(spendDelta) > 0.5
        var config = baseConfig
        if hasDelta {
            let delta = Self.signedMoney(fromDollars: spendDelta)
            let baseAnnual = baseConfig.annualSpendingOverride ?? annualSpending
            config.annualSpendingOverride = Money(cents: max(baseAnnual.cents + delta.cents * 12, 0))
            config.monthlyContribution = Money(cents: max(baseConfig.monthlyContribution.cents - delta.cents, 0))
        }
        let zeroDeltaConfig = baseConfig

        // ONE detached task computes everything off the main actor: the main snapshot
        // (1,000 runs), the delta-zero baseline, and the three levers (300 runs each).
        // Cancelling the owning view's task does NOT propagate into the detached task; it just
        // finishes and the guards below keep its stale result from landing.
        let result = await Task.detached(priority: .userInitiated) { () -> DetachedPlan in
            let snapshot = RetirementPlanner.snapshot(config: config,
                                                      investedNow: investedNow,
                                                      annualSpendingFromBudget: annualSpending,
                                                      runs: 1000)
            let levers = RetirementLeverMath.outcomes(config: config,
                                                      investedNow: investedNow,
                                                      annualSpendingFromBudget: annualSpending,
                                                      baseProjectedAge: snapshot.projectedRetireAge)
            var baselineProjected = snapshot.projectedRetireAge
            if hasDelta {
                baselineProjected = RetirementPlanner.snapshot(config: zeroDeltaConfig,
                                                               investedNow: investedNow,
                                                               annualSpendingFromBudget: annualSpending,
                                                               runs: RetirementLeverMath.leverRuns).projectedRetireAge
            }
            return DetachedPlan(snapshot: snapshot, levers: levers,
                                baselineProjectedAge: baselineProjected)
        }.value
        guard !Task.isCancelled else { return }

        plan = PersonalPlanResult(snapshot: result.snapshot,
                                  config: config,
                                  derivedAnnualSpending: annualSpending,
                                  spendDelta: spendDelta,
                                  baselineProjectedAge: result.baselineProjectedAge,
                                  levers: result.levers)
        // A narrative about the old numbers would now be wrong; drop it.
        if planSummary != nil { planSummary = nil }
        if isExplaining {
            explainToken += 1
            isExplaining = false
        }
        lastComputedKey = key
        isRecomputing = false
    }

    // MARK: Side loads

    /// Contribution detected from real transfers into the linked accounts.
    func refreshDetectedContribution() async {
        let detected = await ContributionDetector.detectedMonthlyContribution(
            store: store, linkedAccountIDs: savedConfig.linkedAccountIDs)
        guard !Task.isCancelled else { return }
        detectedContribution = detected
    }

    /// Loads `actualMonthlySpend` on its own, for the states where `recompute` never runs. A
    /// recompute (or an earlier call) that already worked it out is left alone, so mounting this
    /// alongside the plan does not run a second twelve-month scan.
    func refreshActualMonthlySpend() async {
        guard actualMonthlySpend == nil else { return }
        let series = await store.monthlySpendSeries(monthsBack: 12)
        guard !Task.isCancelled else { return }
        let annual = series.reduce(Money.zero) { $0 + $1.1.magnitude }
        actualMonthlySpend = Money(cents: annual.cents / 12)
    }

    // MARK: Explain (on-device AI)

    /// `extraFacts` lets the glance fold household readings (FI percent at target, debt-free
    /// year) into the narrative when Retiron is connected; empty keeps the personal story. With
    /// no personal plan yet, the household facts alone are enough to write from, which is the
    /// case for an owner who plans in Retiron and never filled in the personal numbers.
    func explain(extraFacts: [String] = []) {
        guard plan != nil || !extraFacts.isEmpty else { return }
        explainToken += 1
        let token = explainToken
        isExplaining = true
        planSummary = nil
        let system = Self.explainSystemPrompt
        let facts = Self.explainFacts(plan, extraFacts: extraFacts)
        Task { [self] in
            let reply = await AIModelManager.shared.generate(
                system: system, user: facts,
                maxTokens: 220, temperature: 0.3, topK: 20)
            guard token == explainToken else { return }   // a newer request or plan took over
            isExplaining = false
            let cleaned = Self.clippedSentences(Self.strippedDashes(reply ?? ""), limit: 4)
            if cleaned.isEmpty {
                Self.log.debug("Plan explanation came back empty")
                Haptics.warning()
            } else {
                planSummary = cleaned
            }
        }
    }

    private static let explainSystemPrompt =
        "You are a warm, plain-spoken money coach inside a personal budgeting app. "
        + "Explain the user's retirement plan in three or four short sentences, using only the "
        + "facts given. No lists, no headings, no disclaimers, no advice to see a professional."

    /// With no personal plan, the household facts stand on their own and the prompt is built from
    /// them alone rather than from placeholder personal numbers.
    private static func explainFacts(_ plan: PersonalPlanResult?, extraFacts: [String] = []) -> String {
        var lines: [String] = []
        if let plan {
            let snapshot = plan.snapshot
            let config = plan.config
            lines.append("Current age: \(config.currentAge)")
            lines.append("Saved so far: \(CurrencyFormatter.string(snapshot.invested, format: .whole))")
            lines.append("Enough to retire: \(CurrencyFormatter.string(snapshot.fiNumber, format: .whole)) at a \((config.withdrawalRatePct / 100).formatted(.percent.precision(.fractionLength(0...1)))) withdrawal rate")
            let monthlySpend = Money(cents: snapshot.annualSpending.cents / 12)
            lines.append("Planned monthly spending in retirement: \(CurrencyFormatter.string(monthlySpend, format: .whole))")
            lines.append("Saving each month: \(CurrencyFormatter.string(config.monthlyContribution, format: .whole))")
            lines.append("Expected return: \((config.expectedReturnPct / 100).formatted(.percent.precision(.fractionLength(0...1)))) a year, with \((config.inflationPct / 100).formatted(.percent.precision(.fractionLength(0...1)))) inflation")
            if let projected = snapshot.projectedRetireAge {
                lines.append("Projected retirement age: about \(clampedInt(projected, min: 0, max: 150))")
            } else {
                lines.append("Projected retirement age: not reached with these numbers")
            }
            lines.append("Chance the money lasts to \(config.lifeExpectancy): \(snapshot.successProbability.formatted(.percent.precision(.fractionLength(0))))")
        }
        lines.append(contentsOf: extraFacts)
        return "Facts about my retirement plan:\n"
            + lines.joined(separator: "\n")
            + "\nExplain what these numbers mean for me."
    }

    /// First `limit` sentences of `text`, joined with single spaces. Anything the model rambles
    /// past the limit is dropped.
    private static func clippedSentences(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..<trimmed.endIndex,
                                    options: [.bySentences, .localized]) { substring, _, _, stop in
            if let substring {
                let sentence = substring.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
            }
            if sentences.count >= limit { stop = true }
        }
        return sentences.joined(separator: " ")
    }

    /// The copy rule bans em dashes everywhere user-facing; model output gets the same wash.
    private static func strippedDashes(_ text: String) -> String {
        text.replacingOccurrences(of: " \u{2014} ", with: ", ")
            .replacingOccurrences(of: "\u{2014}", with: ", ")
            .replacingOccurrences(of: " \u{2013} ", with: ", ")
            .replacingOccurrences(of: "\u{2013}", with: ", ")
    }

    // MARK: Number helpers

    /// Whole currency units to Money, clamped well inside Int64 (LESSONS_FROM_STASHY, part 2:
    /// `isFinite` alone does not make a Double to Int conversion safe).
    private static func money(fromDollars dollars: Double) -> Money {
        let cents = (dollars * 100).rounded()
        guard cents.isFinite else { return .zero }
        let clamped = min(max(cents, 0), 1e15)
        return Money(cents: Int64(clamped))
    }

    /// Signed variant for the spending delta (negative = spend less).
    private static func signedMoney(fromDollars dollars: Double) -> Money {
        let cents = (dollars * 100).rounded()
        guard cents.isFinite else { return .zero }
        let clamped = min(max(cents, -1e15), 1e15)
        return Money(cents: Int64(clamped))
    }

    private static func clampedInt(_ value: Double, min minValue: Int, max maxValue: Int) -> Int {
        guard value.isFinite else { return minValue }
        return Int(Swift.min(Swift.max(value.rounded(), Double(minValue)), Double(maxValue)))
    }
}
