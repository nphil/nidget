import SwiftUI

// MARK: - AccountsView
//
// Pushed via `Route.accounts` (ARCHITECTURE §14/§16) — no NavigationStack of its own; it lives
// inside whichever tab's stack pushed it (dashboard/settings today). Net worth hero card
// (Sparkline of `store.netWorthSeries(12)` + a "vs last month" delta chip), then three sections:
// For Budget, Off Budget, and a collapsed-by-default Closed disclosure — mirroring BudgetView's
// income-group disclosure pattern (LESSONS_FROM_STASHY §1: the list's modifier chain stays
// unconditional, only the row content is gated on `closedExpanded`). `netWorthSeries` already
// returns true net worth (a running sum of every transaction's signed amount — outflow-negative,
// inflow-positive — per BudgetDatabase's doc comment), so the hero and delta render its sign
// as-is; no re-derivation needed.

struct AccountsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var netWorthValues: [Double] = []
    @State private var netWorthCurrent: Money = .zero
    @State private var netWorthDelta: Money = .zero
    @State private var hasLoadedNetWorth = false
    @State private var closedExpanded = false

    init() {}

    var body: some View {
        content
            .themedScreen()
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.large)
            .task(id: store.accounts) { await loadNetWorth() }
    }

    // MARK: Screen

    @ViewBuilder
    private var content: some View {
        if store.accounts.isEmpty {
            EmptyStateView(systemImage: "building.columns",
                           title: "No accounts yet",
                           message: "Accounts you add in Actual will show up here once your budget syncs.",
                           actionTitle: "Sync Now",
                           action: { Task { await store.syncNow() } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            accountsList
        }
    }

    private var accountsList: some View {
        List {
            heroRow
            if !forBudgetAccounts.isEmpty {
                sectionHeader("For Budget")
                ForEach(forBudgetAccounts) { accountRow($0) }
            }
            if !offBudgetAccounts.isEmpty {
                sectionHeader("Off Budget")
                ForEach(offBudgetAccounts) { accountRow($0) }
            }
            if !closedAccounts.isEmpty {
                closedDisclosureHeader
                if closedExpanded {
                    ForEach(closedAccounts) { accountRow($0) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.syncNow() }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 6, leading: theme.layout.cardPadding, bottom: 6, trailing: theme.layout.cardPadding)
    }

    // MARK: Net worth hero

    private var heroRow: some View {
        heroCard
            .padding(.top, theme.layout.spacing * 0.5)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(rowInsets)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Net Worth")
                Spacer(minLength: theme.layout.spacing)
                if hasLoadedNetWorth {
                    deltaChip
                }
            }
            if hasLoadedNetWorth {
                AmountText(netWorthCurrent, style: .display, colorized: false)
            } else {
                AmountText(.zero, style: .display, redacted: true)
            }
            sparklineArea
        }
        .themedCard()
        .animation(reduceMotion ? nil : theme.motion.spring, value: netWorthCurrent)
    }

    @ViewBuilder
    private var sparklineArea: some View {
        if hasLoadedNetWorth && netWorthValues.count > 1 {
            Sparkline(values: netWorthValues, fillGradient: theme.chart.filledAreas)
                .frame(height: 64)
        } else if hasLoadedNetWorth {
            Text("Add more history to see the trend take shape.")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(height: 64)
        } else {
            HStack {
                Spacer()
                ProgressView().tint(theme.palette.accent)
                Spacer()
            }
            .frame(height: 64)
        }
    }

    private var deltaChip: some View {
        let rising = netWorthDelta.cents >= 0
        let chipColor = rising ? theme.palette.positive : theme.palette.negative
        return HStack(spacing: 3) {
            Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .foregroundStyle(chipColor)
            AmountText(netWorthDelta, style: .caption, showSign: true)
            Text("vs last month")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(chipColor.opacity(0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rising ? "Up versus last month" : "Down versus last month")
    }

    private func loadNetWorth() async {
        let series = await store.netWorthSeries(monthsBack: 12)
        guard !Task.isCancelled else { return }
        netWorthValues = series.map { $0.1.doubleValue }
        netWorthCurrent = series.last?.1 ?? .zero
        let previous = series.count >= 2 ? series[series.count - 2].1 : .zero
        netWorthDelta = netWorthCurrent - previous
        hasLoadedNetWorth = true
    }

    // MARK: Sections

    private var forBudgetAccounts: [Account] {
        store.accounts.filter { !$0.offBudget && !$0.closed }
    }

    private var offBudgetAccounts: [Account] {
        store.accounts.filter { $0.offBudget && !$0.closed }
    }

    private var closedAccounts: [Account] {
        store.accounts.filter { $0.closed }
    }

    private func sectionHeader(_ title: String) -> some View {
        SectionHeader(title)
            .padding(.top, theme.layout.spacing * 0.75)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(rowInsets)
    }

    private var closedDisclosureHeader: some View {
        Button {
            Haptics.tick()
            if reduceMotion {
                closedExpanded.toggle()
            } else {
                withAnimation(theme.motion.snappy) { closedExpanded.toggle() }
            }
        } label: {
            SectionHeader("Closed (\(closedAccounts.count))", trailing: {
                AnyView(
                    Image(systemName: "chevron.right")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .rotationEffect(.degrees(closedExpanded ? 90 : 0))
                        .foregroundStyle(theme.palette.textTertiary)
                )
            })
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, theme.layout.spacing * 0.75)
        .animation(reduceMotion ? nil : theme.motion.snappy, value: closedExpanded)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(closedExpanded ? "Double-tap to collapse" : "Double-tap to expand")
    }

    // MARK: Account row

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: theme.layout.spacing * 0.75) {
            HStack(spacing: 6) {
                Text(account.name)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                if account.simpleFINID != nil {
                    Image(systemName: "link")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.accent)
                        .accessibilityLabel("Linked to SimpleFIN")
                }
            }
            Spacer(minLength: theme.layout.spacing * 0.5)
            AmountText(account.balance, style: .body)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tick()
            router.openAccount(account.id)
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.palette.separator)
        .listRowInsets(rowInsets)
        .accessibilityHint("Opens \(account.name)")
    }
}
