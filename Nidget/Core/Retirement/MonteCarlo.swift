import Foundation

// MARK: - SeededGenerator (SplitMix64)
//
// A tiny deterministic RNG so retirement projections are stable frame-to-frame: the same seed
// always produces the same Monte Carlo bands, keeping the UI from flickering on every recompute.

/// SplitMix64 pseudo-random generator (Steele, Lea & Flood 2014).
///
/// State update: `s ← s + 0x9E3779B97F4A7C15` (the 64-bit golden-ratio increment), then the
/// output is the state passed through two xor-shift-multiply finalization rounds:
///
///     z = s
///     z = (z ⊕ (z ≫ 30)) · 0xBF58476D1CE4E5B9
///     z = (z ⊕ (z ≫ 27)) · 0x94D049BB133111EB
///     output = z ⊕ (z ≫ 31)
///
/// Fast, full-period over 2⁶⁴ seeds, and deterministic across platforms.
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform `Double` strictly inside (0, 1).
    ///
    /// Formula: `u = (⌊next() / 2¹¹⌋ + 0.5) · 2⁻⁵³` — the top 53 bits of the raw draw give a
    /// value in [0, 2⁵³); adding 0.5 before scaling keeps the result strictly positive and
    /// strictly below 1, so `log(u)` in Box–Muller can never see 0.
    mutating func nextUnitUniform() -> Double {
        (Double(next() >> 11) + 0.5) * 0x1.0p-53
    }
}

// MARK: - NormalSampler (Box–Muller)

/// Draws normally-distributed samples from a `SeededGenerator` using the Box–Muller transform.
///
/// Given independent uniforms u₁, u₂ ∈ (0, 1):
///
///     r = √(−2 · ln u₁)
///     z₀ = r · cos(2π·u₂)      z₁ = r · sin(2π·u₂)
///
/// z₀ and z₁ are independent standard normals; the second is cached and returned on the next
/// call, so each pair of uniform draws yields two samples.
struct NormalSampler: Sendable {
    private var generator: SeededGenerator
    private var spare: Double?

    init(seed: UInt64) {
        self.generator = SeededGenerator(seed: seed)
    }

    /// One standard-normal sample z ~ N(0, 1).
    mutating func nextStandardNormal() -> Double {
        if let cached = spare {
            spare = nil
            return cached
        }
        let u1 = generator.nextUnitUniform()
        let u2 = generator.nextUnitUniform()
        let radius = (-2.0 * log(u1)).squareRoot()
        let angle = 2.0 * Double.pi * u2
        spare = radius * sin(angle)
        return radius * cos(angle)
    }

    /// One sample x ~ N(mean, stdDev²): `x = mean + stdDev·z`.
    mutating func next(mean: Double, stdDev: Double) -> Double {
        mean + stdDev * nextStandardNormal()
    }
}

// MARK: - MonteCarloSimulator

/// Simulation core for retirement projections. Pure `Double` math — no `Money`, no formatting,
/// no allocation inside the hot loops beyond the preallocated result matrix. 1,000 runs over a
/// 60-year horizon is ~60k normal draws + 61 sorts of 1,000 elements: well under 50 ms.
/// Callers should still hop off the main actor (`Task.detached(priority: .userInitiated)`).
enum MonteCarloSimulator {

    /// Per-year percentile paths (index 0 = today) plus the overall success probability.
    struct PercentileResult: Sendable {
        var p10: [Double]
        var p25: [Double]
        var p50: [Double]
        var p75: [Double]
        var p90: [Double]
        /// Fraction of runs whose balance is still positive at the final year.
        var successProbability: Double
    }

    /// Runs `runs` independent paths of the yearly balance recurrence and reduces them to
    /// nearest-rank percentile bands.
    ///
    /// Each year draws a real return r ~ N(µ, σ²) and applies:
    ///
    ///     balanceᵧ = max(balanceᵧ₋₁ · max(1 + r, 0) + flowᵧ, 0)
    ///
    /// where `flowᵧ = +annualContribution` while accumulating (year index ≤ `contributionYears`)
    /// and `−annualWithdrawal` afterwards. The `max(1 + r, 0)` guard keeps a sub-−100% draw from
    /// flipping the balance's sign; the outer `max(·, 0)` clamps ruined paths at 0, which is
    /// self-perpetuating in the withdrawal phase (0 · growth − withdrawal < 0 → 0 again), so ruin
    /// is permanent without needing a flag.
    ///
    /// - Parameters:
    ///   - startBalance: Balance today, in whole currency units (negative is floored to 0).
    ///   - annualContribution: Amount added at the end of each accumulation year.
    ///   - annualWithdrawal: Amount removed at the end of each retirement year.
    ///   - mu: Expected REAL annual return, as a fraction (e.g. 0.04).
    ///   - sigma: Annual return standard deviation, as a fraction (negative floored to 0).
    ///   - contributionYears: Number of leading years that receive contributions.
    ///   - totalYears: Simulation horizon; the result arrays have `totalYears + 1` entries.
    ///   - runs: Number of Monte Carlo paths (floored to 1).
    ///   - seed: SplitMix64 seed — the same seed always yields the same result.
    static func simulate(startBalance: Double,
                         annualContribution: Double,
                         annualWithdrawal: Double,
                         mu: Double,
                         sigma: Double,
                         contributionYears: Int,
                         totalYears: Int,
                         runs: Int,
                         seed: UInt64) -> PercentileResult {
        let years = max(totalYears, 0)
        let runCount = max(runs, 1)
        let stdDev = max(sigma, 0)
        let start = max(startBalance, 0)

        var sampler = NormalSampler(seed: seed)

        // Year-major storage so each year's cross-section can be sorted in place:
        // yearValues[yearIndex][runIndex].
        var yearValues = [[Double]](repeating: [Double](repeating: start, count: runCount),
                                    count: years + 1)
        var survivors = 0

        for run in 0..<runCount {
            var balance = start
            for year in 1..<(years + 1) {
                // r ~ N(µ, σ²): one real return per simulated year.
                let annualReturn = sampler.next(mean: mu, stdDev: stdDev)
                let growth = max(1.0 + annualReturn, 0.0)
                balance *= growth
                balance += (year <= contributionYears) ? annualContribution : -annualWithdrawal
                if balance < 0 { balance = 0 }
                yearValues[year][run] = balance
            }
            if balance > 0 { survivors += 1 }
        }

        // Nearest-rank indices are identical for every year (same sample count).
        let i10 = nearestRankIndex(0.10, count: runCount)
        let i25 = nearestRankIndex(0.25, count: runCount)
        let i50 = nearestRankIndex(0.50, count: runCount)
        let i75 = nearestRankIndex(0.75, count: runCount)
        let i90 = nearestRankIndex(0.90, count: runCount)

        var p10 = [Double](repeating: 0, count: years + 1)
        var p25 = [Double](repeating: 0, count: years + 1)
        var p50 = [Double](repeating: 0, count: years + 1)
        var p75 = [Double](repeating: 0, count: years + 1)
        var p90 = [Double](repeating: 0, count: years + 1)

        for year in 0..<(years + 1) {
            yearValues[year].sort()
            let sorted = yearValues[year]
            p10[year] = sorted[i10]
            p25[year] = sorted[i25]
            p50[year] = sorted[i50]
            p75[year] = sorted[i75]
            p90[year] = sorted[i90]
        }

        /// success = surviving runs ÷ total runs.
        let successProbability = Double(survivors) / Double(runCount)

        return PercentileResult(p10: p10, p25: p25, p50: p50, p75: p75, p90: p90,
                                successProbability: successProbability)
    }

    /// Nearest-rank percentile index: 1-based rank = ⌈p·n⌉ clamped to [1, n], returned 0-based.
    ///
    /// e.g. p = 0.10, n = 1000 → rank 100 → index 99.
    static func nearestRankIndex(_ p: Double, count: Int) -> Int {
        let rank = Int((p * Double(count)).rounded(.up))
        return min(max(rank, 1), count) - 1
    }
}
