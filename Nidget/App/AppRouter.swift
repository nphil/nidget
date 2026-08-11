import SwiftUI
import Observation

// MARK: - AppTab
//
// The five root tabs (ARCHITECTURE §16). Raw values double as stable identifiers.

enum AppTab: String, CaseIterable {
    case dashboard, budget, transactions, retire, settings
}

// MARK: - Route
//
// Every pushable destination in the app (ARCHITECTURE §16). Values are lightweight Hashable
// data — never views — so any feature can deep-link through `AppRouter.push`.

enum Route: Hashable {
    case accounts
    case account(String)
    case reports
    case transactionDetail(String)
    case themeGallery
    case securitySettings
    case retirementAssumptions
    case manageCategories
    case intelligence
    case aiBenchmark
    case guide
}

// MARK: - AppRouter
//
// One router for the whole app, injected as an environment object by NidgetApp. Each tab owns
// an independent NavigationPath; `push` targets whichever tab is frontmost so widgets and
// cross-feature links Just Work from anywhere.

@MainActor @Observable
final class AppRouter {
    var tab: AppTab = .dashboard

    var dashboardPath = NavigationPath()
    var budgetPath = NavigationPath()
    var transactionsPath = NavigationPath()
    var retirePath = NavigationPath()
    var settingsPath = NavigationPath()

    /// The global Quick Add sheet, reachable from every tab (presented by RootView).
    var quickAddPresented = false

    /// Handoff for `openTransactions(filter:)` — TransactionsView consumes this in a
    /// `.task(id:)` and clears it after applying.
    var pendingTransactionFilter: TransactionQuery?

    /// Whether `tab`'s stack is showing its root screen, i.e. nothing has been pushed on top.
    /// RootView uses this to keep the Quick Add bar accessory on top-level screens only —
    /// reading one tab's path at a time, so a push in a background tab changes nothing here.
    func isAtRoot(of tab: AppTab) -> Bool {
        switch tab {
        case .dashboard: return dashboardPath.isEmpty
        case .budget: return budgetPath.isEmpty
        case .transactions: return transactionsPath.isEmpty
        case .retire: return retirePath.isEmpty
        case .settings: return settingsPath.isEmpty
        }
    }

    /// Appends to the CURRENT tab's path.
    func push(_ route: Route) {
        switch tab {
        case .dashboard: dashboardPath.append(route)
        case .budget: budgetPath.append(route)
        case .transactions: transactionsPath.append(route)
        case .retire: retirePath.append(route)
        case .settings: settingsPath.append(route)
        }
    }

    func openAccount(_ id: String) {
        push(.account(id))
    }

    func openReports() {
        push(.reports)
    }

    /// Jumps to the Transactions tab with a filter pre-applied.
    func openTransactions(filter: TransactionQuery) {
        pendingTransactionFilter = filter
        tab = .transactions
    }
}

// MARK: - Route destinations
//
// The single Route → feature-view mapping (ARCHITECTURE §16 — those names and initializers
// are binding on their owning agents). Every tab's root NavigationStack content applies this.

private struct RouteDestinationsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            case .accounts:
                AccountsView()
            case .account(let id):
                AccountDetailView(accountID: id)
            case .reports:
                ReportsView()
            case .transactionDetail(let id):
                TransactionDetailView(transactionID: id)
            case .themeGallery:
                ThemeGalleryView()
            case .securitySettings:
                SecuritySettingsView()
            case .retirementAssumptions:
                AssumptionsSheet()
            case .manageCategories:
                ManageCategoriesView()
            case .intelligence:
                IntelligenceView()
            case .aiBenchmark:
                AIBenchmarkView()
            case .guide:
                GuideView(embedded: true)
            }
        }
    }
}

extension View {
    /// Maps every `Route` to its feature view. Apply to the root content of each tab's
    /// `NavigationStack`.
    func withRouteDestinations() -> some View {
        modifier(RouteDestinationsModifier())
    }
}
