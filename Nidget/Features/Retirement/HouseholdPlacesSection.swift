import SwiftUI
import Charts

// MARK: - HouseholdPlacesSection
//
// The Places face of the Household Plan: the six retirement destinations Retiron carries, each
// costed in today's money, inflated to the target age, and then measured against what the
// portfolio and the Atlanta rent can actually cover.
//
// Runway here is plain division: the portfolio divided by what a year costs after rental income,
// with no growth and no inflation during the drawdown. It is deliberately the same blunt number
// Retiron shows, so the two apps never disagree in front of the owner.

struct HouseholdPlacesSection: View {
    let plan: HouseholdPlanResult

    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode

    /// One destination with its numbers worked out.
    private struct Place: Identifiable {
        var id: String { destination.name }
        var destination: Destination
        var runway: DestinationRunway
    }

    private var places: [Place] {
        let config = plan.config
        let yearsToTarget = max(0, config.targetRetirementAge - config.personA.age)
        let rentAnnual = (plan.targetRow?.netRentMonthly ?? 0) * 12
        return Destination.defaults.map { destination in
            Place(destination: destination,
                  runway: DestinationMath.runway(destination: destination,
                                                 portfolioAtTarget: plan.summary.portfolioAtTarget,
                                                 netRentAnnualAtTarget: rentAnnual,
                                                 inflationPct: config.inflationPct,
                                                 yearsToTarget: yearsToTarget))
        }
    }

    var body: some View {
        let places = self.places
        return VStack(spacing: theme.layout.cardSpacing) {
            headerCard
            runwayCard(places)
            ForEach(places) { place in
                placeCard(place)
            }
        }
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            cardLabel("Where You Could Land")
            Text("Costs are in today's money, then lifted to what they would be at \(plan.config.targetRetirementAge). The Atlanta rent comes off the top in every one of them.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    // MARK: Runway chart

    private func runwayCard(_ places: [Place]) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            cardLabel("Years The Money Lasts")
            Chart(places) { place in
                BarMark(x: .value("Years", place.runway.runwayYears),
                        y: .value("Place", place.destination.name))
                    .foregroundStyle(color(for: place))
                    .cornerRadius(theme.chart.barCornerRadius)
            }
            .chartXAxis {
                AxisMarks { value in
                    if theme.chart.gridLines { AxisGridLine() }
                    AxisValueLabel {
                        if let years = value.as(Double.self) {
                            Text(String(Self.wholeYears(years)))
                        }
                    }
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .frame(height: 220)
            .privacySensitive()
            .blur(radius: privacyMode ? 8 : 0)
            .accessibilityHidden(true)
            Text("Sixty years is as far as this counts. Anything at that end of the chart simply does not run out.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    // MARK: One place

    private func placeCard(_ place: Place) -> some View {
        let destination = place.destination
        let runway = place.runway
        return VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            HStack(spacing: theme.layout.spacing * 0.5) {
                Text(destination.flag)
                    .font(theme.font(.title))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.name)
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.palette.textPrimary)
                    Text(destination.city)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                Spacer(minLength: theme.layout.spacing)
                coverageBadge(runway.coveragePct)
            }
            .frame(minHeight: 44)
            Text(destination.blurb)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: theme.layout.spacing * 0.4) {
                moneyRow("A year there today", Money(clampedDollars: destination.annualCost))
                moneyRow("A year there at \(plan.config.targetRetirementAge)",
                         Money(clampedDollars: runway.adjustedCost))
                moneyRow("After the Atlanta rent", Money(clampedDollars: runway.netNeed))
            }
            Text(runwaySentence(runway))
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    private func coverageBadge(_ pct: Double) -> some View {
        let color = badgeColor(pct)
        return Text(Self.percentText(pct))
            .font(theme.font(.caption))
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background { Capsule().fill(color.opacity(0.14)) }
            .accessibilityLabel("\(Self.percentText(pct)) of what this place needs")
    }

    private func badgeColor(_ pct: Double) -> Color {
        if pct >= 100 { return theme.palette.positive }
        if pct >= 75 { return theme.palette.accent }
        return theme.palette.negative
    }

    private func runwaySentence(_ runway: DestinationRunway) -> String {
        let years = Self.wholeYears(runway.runwayYears)
        if runway.netNeed <= 0 {
            return "The rent alone covers a year here, so the portfolio never has to."
        }
        if runway.runwayYears >= DestinationMath.maxRunwayYears {
            return "The portfolio outlasts anything worth planning for here."
        }
        return "The portfolio covers about \(years) years of that."
    }

    private func moneyRow(_ label: String, _ amount: Money) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: theme.layout.spacing)
            AmountText(amount, style: .body, colorized: false)
        }
        .frame(minHeight: 32)
    }

    // MARK: Helpers

    private func color(for place: Place) -> Color {
        let index = Destination.defaults.firstIndex { $0.name == place.destination.name } ?? 0
        return theme.palette.chart[index % theme.palette.chart.count]
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.font(.label))
            .foregroundStyle(theme.palette.textSecondary)
            .textCase(theme.typography.labelCase)
            .tracking(theme.typography.labelTracking)
    }

    private static func wholeYears(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), 0), 999))
    }

    private static func percentText(_ value: Double) -> String {
        let safe = value.isFinite ? min(max(value, 0), 999) : 0
        return (safe / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}
