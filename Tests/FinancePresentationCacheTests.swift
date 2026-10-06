import Foundation

@main
struct FinancePresentationCacheTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        let cache = FinancePresentationCache()
        var history = SavedHistory()
        let now = Date()
        let interval = historyInterval(.lastDays(30), now: now)
        cache.prepare(history)
        var computations = 0
        func marker() -> Int {
            cache.value("marker") { computations += 1; return computations }
        }
        require(marker() == 1 && marker() == 1, "Repeated navigation must reuse results")
        history.lastSync = now
        history.lastStopReason = "Synthetic sync message"
        cache.prepare(history)
        require(marker() == 1, "Sync metadata must not invalidate financial results")
        _ = cache.report(history, interval: interval)
        history.manualOperations = [ManualOperation(kind: .expense, amountKopecks: 25000, date: now,
                                                    group: "Еда", subcategory: "Кафе и рестораны")]
        cache.prepare(history)
        require(marker() == 2, "Saved operation must invalidate the cache")
        let report = cache.report(history, interval: interval)
        let direct = FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy)
        require(report.netExpenseKopecks == direct.netExpenseKopecks && report.operationCount == direct.operationCount,
                "Cached report must match the unchanged engine after saving")
        require(history.addExpenseGroup(name: "Новая группа") != nil, "Synthetic group should be valid")
        cache.prepare(history)
        require(marker() == 3, "Category changes must invalidate results")
        history.categoryOverrides = ["synthetic": UUID()]
        cache.prepare(history)
        require(marker() == 4, "Single operation overrides must invalidate results")
        history.categoryRules = [CategoryRule(payeeKey: "synthetic", title: "Synthetic", categoryID: UUID())]
        cache.prepare(history)
        require(marker() == 5, "Payee rules must invalidate results")
        history.accounts = [Account(name: "Synthetic", icon: "banknote", color: "green", startBalanceKopecks: 100000, startDate: now)]
        cache.prepare(history)
        require(marker() == 6, "Account edits must invalidate the current balance")
        history.accountGroups = [AccountGroup(name: "Synthetic", includesInBalance: false)]
        cache.prepare(history)
        require(marker() == 7, "Group visibility must invalidate the current balance")
        history.manualOperations = []
        cache.prepare(history)
        require(cache.report(history, interval: interval).operationCount == 0, "Deletion must remove cached operations")

        // Synthetic data only: compare repeated UI calculations with navigation through the cache.
        history.operations = (0..<480).map { index in
            BankOperation(identity: "synthetic:\(index)", occurredAt: "2026-09-\(String(format: "%02d", index % 28 + 1))T10:00:00Z",
                          timePrecision: "second", description: "Synthetic \(index % 20)", amountKopecks: -25000,
                          currency: "RUB", status: "Выполнено", category: "Кафе и рестораны", mcc: "5812",
                          purpose: nil, paymentMethod: nil, providers: [], kind: "payment")
        }
        let start = Date()
        for _ in 0..<3 {
            _ = FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy)
            _ = FinancialEngine.monthForecast(history.financialInputs, now: now, taxonomy: history.expenseTaxonomy)
        }
        let directSeconds = Date().timeIntervalSince(start)
        cache.prepare(history)
        _ = cache.report(history, interval: interval)
        _ = cache.forecast(history, now: now)
        let cachedStart = Date()
        for _ in 0..<3 {
            cache.prepare(history)
            _ = cache.report(history, interval: interval)
            _ = cache.forecast(history, now: now)
        }
        print("Cache invalidation checks passed")
        print("480 synthetic operations, 3 navigation redraws: direct \(directSeconds)s; cached \(Date().timeIntervalSince(cachedStart))s")
    }
}
