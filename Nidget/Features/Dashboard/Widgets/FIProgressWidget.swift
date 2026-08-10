import SwiftUI

// MARK: - FIProgressWidget
//
// A GaugeArc of progress toward financial independence. AppStore exposes no retirement data,
// so this computes its own snapshot: RetirementConfig from Preferences.retirementConfigJSON,
// invested = linked account balances (+ extra assets, inside the planner), annual spending
// derived from the last 12 months of outflow. The planner runs on a detached task (it includes
// a small Monte Carlo pass) and results only land if the task is still current. Tapping opens
// the Retire tab.

struct FIProgressWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct LoadKey: Equatable {
        let accounts: [Account]
        let configJSON: String
    }

    @State private var progress: Double = 0
    @State private var invested: Money = .zero
    @State private var fiNumber: Money = .zero
    @State private var hasPlan = false
    @State private var hasLoaded = false

    var body: some View {
        WidgetCardButton(action: { router.tab = .retire }) {
            content
        }
        .accessibilityHint("Opens retirement planning")
        .task(id: LoadKey(accounts: store.accounts, configJSON: preferences.retirementConfigJSON)) {
            await load()
        }
    }

    // MARK: Load

    private func load() async {
        var config = RetirementConfig()
        let json = preferences.retirementConfigJSON
        if !json.isEmpty, let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(RetirementConfig.self, from: data) {
            config = decoded
        }

        let linked = Set(config.linkedAccountIDs)
        let linkedBalance = store.accounts
            .filter { linked.contains($0.id) }
            .reduce(Money.zero) { $0 + $1.balance }

        let spendSeries = await store.monthlySpendSeries(monthsBack: 12)
        guard !Task.isCancelled else { return }
        let annualSpending = spendSeries.reduce(Money.zero) { $0 + $1.1.magnitude }

        let frozenConfig = config
        let snapshot = await Task.detached(priority: .userInitiated) {
            RetirementPlanner.snapshot(config: frozenConfig,
                                       investedNow: linkedBalance,
                                       annualSpendingFromBudget: annualSpending,
                                       runs: 200)
        }.value
        guard !Task.isCancelled else { return }

        progress = min(max(snapshot.progress, 0), 1)
        invested = snapshot.invested
        fiNumber = snapshot.fiNumber
        hasPlan = snapshot.invested.cents > 0 || !config.linkedAccountIDs.isEmpty
        hasLoaded = true
    }

    private var progressText: String {
        guard hasLoaded else { return "—" }
        return progress.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if span == .s1x1 {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
                WidgetLabel("FI Progress")
                gauge
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
                WidgetLabel("FI Progress")
                HStack(spacing: theme.layout.spacing) {
                    gauge
                        .frame(maxHeight: .infinity)
                    detailColumn
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var gauge: some View {
        GaugeArc(progress: progress, label: progressText, detail: "to FI")
            .animation(reduceMotion ? nil : theme.motion.spring, value: progress)
    }

    @ViewBuilder
    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !hasLoaded {
                AmountText(.zero, style: .body, redacted: true)
                Text("Projecting the future…")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            } else if !hasPlan {
                Text("No plan yet")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Link investment accounts in Retire.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    WidgetLabel("Invested")
                    AmountText(invested, style: .caption, colorized: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    WidgetLabel("FI Number")
                    AmountText(fiNumber, style: .caption, colorized: false)
                }
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: invested)
    }
}
