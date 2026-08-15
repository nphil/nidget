import SwiftUI
import Charts

// MARK: - PlacesView
//
// "Places", pushed via `Route.retirePlaces`: the six retirement destinations Retiron carries,
// each costed in today's money, inflated to the target age, and then measured against what the
// portfolio and the rental income can actually cover.
//
// The runways come off `HouseholdPlanModel`, computed in the same detached pass as the
// projection, so this screen never does the math while drawing. Runway is plain division: the
// portfolio divided by what a year costs after rental income, with no growth and no inflation
// during the drawdown. It is deliberately the same blunt number Retiron shows, so the two apps
// never disagree in front of the owner.

struct PlacesView: View {
    /// Optional on purpose: a force read traps if this destination is ever built outside the
    /// Retire tab's injected stack, so the model is unwrapped once and the screen shows a
    /// placeholder instead of crashing.
    @Environment(HouseholdPlanModel.self) private var household: HouseholdPlanModel?

    var body: some View {
        if let household {
            PlacesContent(household: household)
        } else {
            RetirePlaceholderScreen(title: "Places")
        }
    }
}

private struct PlacesContent: View {
    let household: HouseholdPlanModel

    @Environment(\.theme) private var theme
    @Environment(\.privacyMode) private var privacyMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expandedPlace: String?

    var body: some View {
        Group {
            if let plan = household.plan {
                planScroll(plan)
            } else {
                loadingView
            }
        }
        .themedScreen()
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: household.recomputeKey) {
            await household.recompute()
        }
    }

    private var loadingView: some View {
        VStack(spacing: theme.layout.spacing) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.palette.accent)
            Text("Pricing the six places…")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Layout

    private func planScroll(_ plan: HouseholdPlanResult) -> some View {
        ScrollView {
            VStack(spacing: theme.layout.cardSpacing) {
                headerCard(plan)
                runwayCard
                placesCard(plan)
            }
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.top, theme.layout.spacing * 0.5)
            .padding(.bottom, theme.layout.cardSpacing)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Header

    private func headerCard(_ plan: HouseholdPlanResult) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            SectionHeader("Where you could land")
            Text("Costs are in today's money, then lifted to what they would be at \(plan.config.targetRetirementAge). The \(HouseholdCopy.homeCity) rent comes off the top in every one of them.")
                .font(theme.font(.subheadline))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("These places are set in the plan on Retiron.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themedCard()
    }

    // MARK: Runway chart

    private var runwayCard: some View {
        let runways = household.runways
        let maxYears = runways.map(\.runway.runwayYears).max() ?? 0
        return VStack(alignment: .leading, spacing: theme.layout.spacing) {
            SectionHeader("Years the money lasts")
            if maxYears <= 0 {
                Text("The plan cannot fund a move yet.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                runwayChart(runways, maxYears: maxYears)
            }
        }
        .themedCard()
    }

    /// One hue on purpose: the bar length is the only thing the chart says, and coverage
    /// judgment lives on the row badges below, where status colors are genuinely status. The x
    /// axis is hidden entirely; each bar carries its own trailing label instead.
    private func runwayChart(_ runways: [HouseholdPlaceRunway], maxYears: Double) -> some View {
        Chart(runways) { place in
            BarMark(x: .value("Years", place.runway.runwayYears),
                    y: .value("Place", place.destination.name))
                .foregroundStyle(theme.palette.accent.opacity(0.85))
                .cornerRadius(theme.chart.barCornerRadius)
                .annotation(position: .trailing, alignment: .center, spacing: 4,
                            overflowResolution: .init(x: .fit(to: .plot), y: .disabled)) {
                    Text(barLabel(place.runway))
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                }
        }
        .chartXScale(domain: 0...(maxYears * 1.18))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .frame(height: 200)
        .privacySensitive()
        .blur(radius: privacyMode ? 8 : 0)
        .accessibilityHidden(true)
    }

    private func barLabel(_ runway: DestinationRunway) -> String {
        if runway.runwayYears >= DestinationMath.maxRunwayYears {
            return "\(Self.wholeYears(DestinationMath.maxRunwayYears))+ yr"
        }
        return "\(Self.wholeYears(runway.runwayYears)) yr"
    }

    // MARK: The places

    private func placesCard(_ plan: HouseholdPlanResult) -> some View {
        let runways = household.runways
        return VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            SectionHeader("Place by place")
            ForEach(runways) { place in
                placeRow(place, targetAge: plan.config.targetRetirementAge)
                if place.id != runways.last?.id {
                    Rectangle()
                        .fill(theme.palette.separator)
                        .frame(height: 1)
                }
            }
        }
        .themedCard()
    }

    private func placeRow(_ place: HouseholdPlaceRunway, targetAge: Int) -> some View {
        let destination = place.destination
        let isOpen = expandedPlace == place.id
        return VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            Button {
                toggle(place.id)
            } label: {
                HStack(spacing: theme.layout.spacing * 0.5) {
                    Text(destination.flag)
                        .font(theme.font(.title))
                        .accessibilityHidden(true)
                    Text(destination.name)
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: theme.layout.spacing)
                    coverageBadge(place.runway.coveragePct)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                placeDetail(destination: destination, runway: place.runway, targetAge: targetAge)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: isOpen)
    }

    @ViewBuilder
    private func placeDetail(destination: Destination, runway: DestinationRunway,
                             targetAge: Int) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.5) {
            Text(destination.city)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            Text(destination.blurb)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: theme.layout.spacing * 0.4) {
                moneyRow("A year there today", Money(clampedDollars: destination.annualCost))
                moneyRow("A year there at \(targetAge)",
                         Money(clampedDollars: runway.adjustedCost))
                moneyRow("After the \(HouseholdCopy.homeCity) rent",
                         Money(clampedDollars: runway.netNeed))
            }
            Text(runwaySentence(runway))
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        if runway.netNeed <= 0 {
            return "The rent alone covers a year here, so the portfolio never has to."
        }
        if runway.runwayYears >= DestinationMath.maxRunwayYears {
            return "The portfolio outlasts anything worth planning for here."
        }
        // `wholeYears` rounds, so one year and under a year are ordinary values here and both
        // need their own words.
        switch Self.wholeYears(runway.runwayYears) {
        case 0: return "The portfolio covers less than a year of that."
        case 1: return "The portfolio covers about a year of that."
        case let years: return "The portfolio covers about \(years) years of that."
        }
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

    // MARK: Interaction

    private func toggle(_ id: String) {
        Haptics.tick()
        let apply = { expandedPlace = (expandedPlace == id) ? nil : id }
        if reduceMotion {
            apply()
        } else {
            withAnimation(theme.motion.snappy) { apply() }
        }
    }

    // MARK: Helpers

    private static func wholeYears(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), 0), 999))
    }

    private static func percentText(_ value: Double) -> String {
        let safe = value.isFinite ? min(max(value, 0), 999) : 0
        return (safe / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}
