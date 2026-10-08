import Foundation

/// UI-only memoization. Sync messages and tab changes do not alter financial data.
final class FinancePresentationCache {
    private var snapshot: SavedHistory?
    private var values: [String: Any] = [:]

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
            // Only the accounts or their groups changed (hiding an account, a new name, another order): what is built from
            // them is dropped, the forecast, the reports and the review of categories stay (the forecast takes ~1 s).
            snapshot = history
            values = values.filter { !Self.dependsOnAccounts($0.key) }
            return
        }
        snapshot = history
        values.removeAll(keepingCapacity: true)
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

    func forecast(_ history: SavedHistory, now: Date = Date()) -> FinancialEngine.MonthForecast {
        value("forecast:\(Calendar.current.startOfDay(for: now))") {
            FinancialEngine.monthForecast(inputs(history), now: now, taxonomy: history.expenseTaxonomy)
        }
    }
}
