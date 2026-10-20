import Foundation

/// UI-only memoization. Sync messages and tab changes do not alter financial data.
final class FinancePresentationCache {
    private var snapshot: SavedHistory?
    private var values: [String: Any] = [:]
    /// Grows each time the operations change: a forecast computed in the background for an older history is not kept.
    private(set) var generation = 0

    func prepare(_ history: SavedHistory) {
        if let old = snapshot,
           old.operations == history.operations,
           old.manualOperations == history.manualOperations,
           old.expenseCategories == history.expenseCategories,
           old.categoryRules == history.categoryRules,
           old.categoryOverrides == history.categoryOverrides,
           old.incomeCategoryRules == history.incomeCategoryRules,
           old.incomeCategoryOverrides == history.incomeCategoryOverrides,
           old.operationNatures == history.operationNatures,
           old.operationLooks == history.operationLooks,
           old.payeeLookRules == history.payeeLookRules {
            if old.accounts == history.accounts && old.accountGroups == history.accountGroups { return }
            // Which account follows the card or Save decides which operations belong to which account (the inputs and the
            // reports of an account): then everything is computed again; hiding, names and order keep the rest.
            if Self.bankLinks(old) != Self.bankLinks(history) {
                snapshot = history
                values.removeAll(keepingCapacity: true)
                generation += 1
                return
            }
            // Only the accounts or their groups changed (hiding an account, a new name, another order): what is built from
            // them is dropped, the forecast, the reports and the review of categories stay (the forecast takes ~1 s).
            snapshot = history
            values = values.filter { !Self.dependsOnAccounts($0.key) }
            return
        }
        snapshot = history
        values.removeAll(keepingCapacity: true)
        generation += 1
    }

    private static func bankLinks(_ history: SavedHistory) -> [String] {
        // The first account of each link is the one the operations follow (`SavedHistory.financialInputs`); the order of the
        // linked accounts among themselves means nothing else.
        let accounts = history.accounts ?? []
        return ["card:" + (accounts.first { $0.tracksBankCard }?.id.uuidString ?? "-"),
                "save:" + (accounts.first { $0.tracksSave == true }?.id.uuidString ?? "-")]
    }

    /// Keys of values made from the accounts: the balances of accounts, of the reserve, the pages of one account.
    private static func dependsOnAccounts(_ key: String) -> Bool {
        key.hasPrefix("account") || key.hasPrefix("balance") || key.hasPrefix("reserveBalance")
    }

    func value<T>(_ key: String, compute: () -> T) -> T {
        if let cached = values[key] as? T { return cached }
        let result = compute()
        values[key] = result
        return result
    }

    func inputs(_ history: SavedHistory) -> [FinancialOperationInput] {
        value("inputs") { history.financialInputs }
    }

    /// The bank rows as inputs, for the balances of the accounts.
    func bankInputs(_ history: SavedHistory) -> [FinancialOperationInput] {
        value("bankInputs") { history.operations.map(\.financialInput) }
    }

    /// The balance of one account. The key holds only what the balance depends on (not whether the account is shown, its name or
    /// order), and it is not dropped when only the accounts change: hiding an account with the eye only adds up known numbers.
    func accountBalance(_ account: Account, history: SavedHistory) -> Int64 {
        let key = "acctbal:\(account.id):\(account.startBalanceKopecks):\(account.startDate.timeIntervalSince1970):\(account.tracksBankCard):\(account.tracksSave ?? false)"
        return value(key) { account.balance(bankOperations: bankInputs(history), manual: history.manualOperations ?? []) }
    }

    /// The inputs of the chosen accounts; every input under «all accounts».
    func inputs(_ history: SavedHistory, scope: ReportAccountScope) -> [FinancialOperationInput] {
        guard !scope.isAll else { return inputs(history) }
        return value("inputs:\(scope.cacheKey)") { inputs(history).filter(scope.includes) }
    }

    func report(_ history: SavedHistory, interval: DateInterval, scope: ReportAccountScope = .all) -> FinanceReport {
        value("report:\(interval.start):\(interval.end):\(scope.cacheKey)") {
            FinancialEngine.report(inputs(history, scope: scope), in: interval, taxonomy: history.expenseTaxonomy)
        }
    }

    /// The budgets of the month with what is spent against each (all accounts, as the reports count).
    func budgetStatuses(_ history: SavedHistory, month: Date) -> [BudgetStatus] {
        // The limits are in the key, not in `prepare`: changing a limit must not throw away the forecast and the reports.
        let limits = (history.budgets ?? []).map { "\($0.group ?? "-")|\($0.month ?? "*")|\($0.limitKopecks)" }.joined(separator: ";")
        return value("budgets:\(BudgetEngine.monthKey(month)):\(limits)") {
            BudgetEngine.statuses(inputs: inputs(history), budgets: history.budgets ?? [], month: month, taxonomy: history.expenseTaxonomy)
        }
    }

    /// The range of the forecast once computed in the background for the day (`FinancialEngine.forecastRange`); dropped with
    /// the rest when the data change.
    func cachedForecastRange(now: Date = Date()) -> FinancialEngine.ForecastRange? {
        values["forecastRange:\(Calendar.current.startOfDay(for: now))"] as? FinancialEngine.ForecastRange
    }

    func storeForecastRange(_ range: FinancialEngine.ForecastRange, now: Date = Date()) {
        values["forecastRange:\(Calendar.current.startOfDay(for: now))"] = range
    }

    func forecast(_ history: SavedHistory, now: Date = Date()) -> FinancialEngine.MonthForecast {
        value(forecastKey(history, now: now)) {
            FinancialEngine.monthForecast(inputs(history), now: now, taxonomy: history.expenseTaxonomy, answers: history.paymentAnswers ?? [:],
                                          subscriptions: history.subscriptions ?? [], loans: history.loans ?? [])
        }
    }

    /// The answers about late payments are in the key, not in `prepare`: an answer recomputes the forecast only.
    func forecastKey(_ history: SavedHistory, now: Date = Date()) -> String {
        let answers = (history.paymentAnswers ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.kind.rawValue)\($0.value.movedTo.map { "@\($0.timeIntervalSince1970)" } ?? "")" }.joined(separator: ";")
        return "forecast:\(Calendar.current.startOfDay(for: now)):\(answers):\(history.commitmentsKey)"
    }

    /// The forecast if it is already computed, without computing it (the home screen computes it in the background: about a
    /// second on the first drawing after the launch, which froze the greeting — 46.47).
    func cachedForecast(_ history: SavedHistory, now: Date = Date()) -> FinancialEngine.MonthForecast? {
        values[forecastKey(history, now: now)] as? FinancialEngine.MonthForecast
    }

    /// Keeps a forecast computed in the background, unless the operations changed meanwhile. True when it was kept.
    @discardableResult
    func storeForecast(_ forecast: FinancialEngine.MonthForecast, history: SavedHistory, now: Date, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        let key = forecastKey(history, now: now)
        guard values[key] == nil else { return false }
        values[key] = forecast
        return true
    }
}
