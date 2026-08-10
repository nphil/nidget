import SwiftUI

// MARK: - AccountsListWidget
//
// The biggest balances at a glance. 1x1 collapses to a total + open-account count (whole card
// opens Accounts); larger spans list the top accounts as compact rows that deep-link straight
// into each account. Rows stretch to share the tile's height so tap targets stay generous.

struct AccountsListWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if span == .s1x1 {
            WidgetCardButton(action: { router.push(.accounts) }) {
                summaryBody
            }
            .accessibilityHint("Opens your accounts")
        } else {
            listBody
        }
    }

    // MARK: Data

    private var openAccounts: [Account] {
        store.accounts
            .filter { !$0.closed }
            .sorted { $0.balance.cents > $1.balance.cents }
    }

    private var totalBalance: Money {
        openAccounts.reduce(.zero) { $0 + $1.balance }
    }

    private var rowLimit: Int {
        span == .s2x2 ? 5 : 2
    }

    // MARK: 1x1 summary

    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            WidgetLabel("Accounts")
            Spacer(minLength: 0)
            AmountText(totalBalance, style: .title, colorized: false)
            Text(openAccounts.isEmpty
                 ? "None linked yet"
                 : "\(openAccounts.count) open")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : theme.motion.snappy, value: openAccounts.count)
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: totalBalance)
    }

    // MARK: 2x1 / 2x2 list

    private var listBody: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            headerButton
            if openAccounts.isEmpty {
                Spacer(minLength: 0)
                Text("No accounts yet — connect your budget's accounts to see them here.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 2) {
                    ForEach(openAccounts.prefix(rowLimit)) { account in
                        accountRow(account)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .themedCard()
        .animation(reduceMotion ? nil : theme.motion.spring, value: openAccounts)
    }

    private var headerButton: some View {
        Button {
            router.push(.accounts)
        } label: {
            HStack(spacing: 4) {
                WidgetLabel("Accounts")
                Image(systemName: "chevron.right")
                    .font(theme.font(.label))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.textTertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
        .accessibilityLabel("All accounts")
    }

    private func accountRow(_ account: Account) -> some View {
        Button {
            router.openAccount(account.id)
        } label: {
            HStack(spacing: theme.layout.spacing * 0.5) {
                Text(account.name)
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if account.offBudget {
                    Text("Off budget")
                        .font(theme.font(.label))
                        .foregroundStyle(theme.palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: theme.layout.spacing * 0.5)
                AmountText(account.balance, style: .caption)
            }
            .frame(minHeight: 36, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(pressAnimation: reduceMotion ? nil : theme.motion.snappy))
        .accessibilityHint("Opens \(account.name)")
    }
}
