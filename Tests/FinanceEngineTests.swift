import Foundation

@main
struct FinanceEngineTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func op(_ amount: Int64, kind: String, status: String = "Выполнено", category: String = "Тест",
                   description: String = "Синтетическая операция", purpose: String? = nil,
                   providers: [String] = [], components: [Int64] = [], date: String = "2032-06-02T10:00:00Z") -> FinancialOperationInput {
        FinancialOperationInput(occurredAt: date, description: description, amountKopecks: amount,
                                status: status, category: category, purpose: purpose,
                                providers: providers, kind: kind, componentAmountsKopecks: components)
    }

    static func main() {
        require(FinancialEngine.classify(op(-10_000, kind: "expense")).type == .expense, "expense")
        require(FinancialEngine.classify(op(5_000, kind: "income")).type == .income, "explicit income")
        require(FinancialEngine.classify(op(5_100, kind: "unclassified_income")).type == .unknown, "technical unclassified income must stay unknown")
        require(FinancialEngine.classify(op(5_200, kind: "unclassified_income", category: "Зарплата", description: "Зарплата за месяц")).type == .income, "salary text confirms income")
        require(FinancialEngine.classify(op(5_300, kind: "unclassified_income", description: "Кэшбэк 5 процентов")).type == .income, "cashback with percent text remains cashback income")
        require(FinancialEngine.classify(op(3_000, kind: "refund", category: "Возврат")).type == .refund, "refund")
        require(FinancialEngine.classify(op(50_000, kind: "internal_transfer", category: "Переводы между своими счетами")).type == .internalTransfer, "internal transfer")
        require(FinancialEngine.classify(op(30, kind: "interest_income", category: "Проценты")).type == .interestIncome, "interest")
        require(FinancialEngine.classify(op(-199, kind: "expense", description: "Комиссия банка")).type == .commission, "commission")
        require(FinancialEngine.classify(op(-50_000, kind: "expense", description: "Снятие наличных в банкомате")).type == .internalTransfer, "cash withdrawal")
        require(FinancialEngine.classify(op(-250, kind: "expense", description: "Комиссия за снятие наличных в банкомате")).type == .commission, "cash withdrawal fee stays commission")
        require(FinancialEngine.classify(op(-20_000, kind: "installment_payment", providers: ["BNPL"])).type == .split, "split")
        require(FinancialEngine.classify(op(-4_000, kind: "expense", status: "В обработке")).type == .pending, "pending")
        require(FinancialEngine.classify(op(-5_000, kind: "expense", status: "Отменено")).type == .cancelled, "cancelled")
        require(FinancialEngine.classify(op(-6_000, kind: "legacy_kind")).type == .expense, "completed negative unknown kind is an expense")
        require(FinancialEngine.classify(op(-6_100, kind: "unclassified_income")).type == .expense, "legacy negative income kind falls back to expense")
        require(FinancialEngine.classify(op(-6_200, kind: "income")).type == .expense, "legacy negative explicit income kind falls back to expense")
        require(FinancialEngine.classify(op(-6_300, kind: "refund", category: "Возврат")).type == .expense, "negative stale refund metadata falls back to expense")
        require(FinancialEngine.classify(op(-6_400, kind: "interest_income", category: "Проценты")).type == .expense, "negative stale interest metadata falls back to expense")
        require(FinancialEngine.classify(op(6_000, kind: "legacy_kind")).type == .unknown, "positive unknown kind must not be guessed as income")
        require(FinancialEngine.classify(op(-7_000, kind: "transfer")).type == .expense, "external outgoing transfer")
        require(FinancialEngine.classify(op(8_000, kind: "transfer")).type == .income, "external incoming transfer")
        require(FinancialEngine.classify(op(8_100, kind: "grouped_operation", category: "Перевод")).type == .income, "grouped positive transfer category remains income")
        require(FinancialEngine.classify(op(8_200, kind: "unclassified_income", category: "Проценты", description: "Проценты")).type == .interestIncome, "plain interest category remains interest income")

        let grouped = op(-146_800, kind: "grouped_operation", components: [-178_000, 31_200])
        let groupedAssessment = FinancialEngine.classify(grouped)
        require(groupedAssessment.type == .expense, "grouped type")
        require(groupedAssessment.expenseContributionKopecks == 146_800, "grouped parent total only")
        require(FinancialEngine.classify(op(14_680, kind: "grouped_operation", components: [17_800, -3_120])).type == .unknown, "positive grouped operation is not guessed as income")

        let formatter = ISO8601DateFormatter()
        let interval = DateInterval(start: formatter.date(from: "2032-06-01T00:00:00Z")!,
                                    end: formatter.date(from: "2032-07-01T00:00:00Z")!)
        let summary = FinancialEngine.summarize([
            op(-10_000, kind: "expense"),
            op(3_000, kind: "refund", category: "Возврат"),
            op(5_000, kind: "income"),
            op(30, kind: "interest_income", category: "Проценты"),
            op(50_000, kind: "internal_transfer", category: "Переводы между своими счетами"),
            op(-199, kind: "expense", description: "Комиссия банка"),
            op(-20_000, kind: "installment_payment", providers: ["BNPL"]),
            op(-4_000, kind: "expense", status: "В обработке"),
            op(-5_000, kind: "expense", status: "Отменено"),
            grouped,
            op(-99_999, kind: "expense", date: "2032-05-31T23:59:59Z")
        ], in: interval)

        require(summary.operationCount == 10, "period filtering")
        require(summary.grossExpenseKopecks == 156_999, "gross expenses use parent group once")
        require(summary.refundsKopecks == 3_000, "refund contribution")
        require(summary.netExpenseKopecks == 153_999, "net expense")
        require(summary.incomeKopecks == 5_030, "ordinary + interest income")
        require(summary.netCashFlowKopecks == -148_969, "net cash flow")
        require(summary.counts[.internalTransfer] == 1, "internal transfer bucket")
        require(summary.counts[.split] == 1, "split bucket")
        require(summary.counts[.pending] == 1, "pending bucket")
        require(summary.counts[.cancelled] == 1, "cancelled bucket")
        require(summary.signedAmounts[.expense] == -156_800, "component amounts must not be added to type totals")

        let dateInterval = DateInterval(start: formatter.date(from: "2033-02-01T00:00:00Z")!,
                                        end: formatter.date(from: "2033-03-01T00:00:00Z")!)
        let dateFormats = FinancialEngine.summarize([
            op(-111, kind: "expense", date: "2033-02-14T12:34:56.789Z"),
            op(-222, kind: "expense", date: "2033-02-15T12:34:56Z"),
            op(-333, kind: "expense", date: "2033-02-16T15:34:56.123+03:00"),
            op(-444, kind: "expense", date: "2033-03-01T00:00:00Z"),
            op(-555, kind: "expense", date: "not-a-date")
        ], in: dateInterval)
        require(dateFormats.operationCount == 3, "fractional and plain ISO8601 dates must be included")
        require(dateFormats.grossExpenseKopecks == 666, "period totals must include fractional-second timestamps")
        require(dateFormats.invalidDateCount == 1, "invalid dates must be surfaced instead of silently disappearing")

        let report = FinancialEngine.report([
            op(-123_400, kind: "legacy_purchase", category: "Супермаркеты"),
            op(12_300, kind: "refund", category: "Возврат"),
            op(-45_600, kind: "expense", status: "В обработке"),
            op(-78_900, kind: "internal_transfer", category: "Переводы между своими счетами"),
            op(-22_200, kind: "installment_payment", providers: ["BNPL"]),
            op(33_300, kind: "legacy_credit", description: "Непонятное поступление"),
            op(777, kind: "interest_income", category: "Проценты"),
            op(-66_600, kind: "expense", status: "Отменено")
        ], in: interval)
        require(report.operationCount == 8, "report count")
        require(report.grossExpenseKopecks == 123_400, "legacy debit is an expense")
        require(report.refundsKopecks == 12_300, "refund reduces expense")
        require(report.netExpenseKopecks == 111_100, "net expense")
        require(report.pendingDebitKopecks == 45_600, "pending stays out of final expense")
        require(report.incomeKopecks == 777, "only confirmed income enters income total")
        require(report.movementKopecks == 78_900, "confirmed own transfer is movement")
        require(report.bankDebitKopecks == 270_100, "bank debit turnover includes expense, pending, movement and split but excludes cancelled")
        require(report.bankCreditKopecks == 46_377, "bank credit turnover includes positive bank movements")
        require(report.unknownCount == 1, "unknown credit remains visible")
        let unknownLine = report.incompleteLines.first { $0.title == "Не определено" }
        require(unknownLine?.children.count == 1, "unknown operations expose diagnostics")
        require(unknownLine?.children.first?.title == "Непонятное поступление", "unknown diagnostic shows operation title")
        require(unknownLine?.children.first?.amountKopecks == 33_300, "unknown diagnostic shows operation amount")
        require(unknownLine?.children.first?.note?.contains("может быть перевод между своими счетами") == true, "unknown diagnostic shows classification reason")
        require(report.expenseLines.contains { $0.title == "Покупки" && $0.children.contains { $0.title == "Супермаркеты" } }, "purchase category expands")
        require(report.expenseLines.contains { $0.title == "Возвраты" }, "refund is shown inside expenses")
        require(report.expenseLines.contains { $0.title == "Сплит" }, "split is shown separately")
        require(report.incomeLines.contains { $0.title == "Проценты" }, "interest subgroup")

        let positiveSafetyReport = FinancialEngine.report([
            op(20_000, kind: "unclassified_income", description: "Неизвестное поступление"),
            op(3_500, kind: "unclassified_income", description: "Кэшбэк 5 процентов")
        ], in: interval)
        require(positiveSafetyReport.incomeKopecks == 3_500, "only explicitly recognized cashback enters income")
        require(positiveSafetyReport.unknownCount == 1, "generic positive fallback remains unknown")
        require(positiveSafetyReport.incomeLines.contains { $0.title == "Кэшбэк" && $0.amountKopecks == 3_500 }, "cashback has priority over percent wording")
        let positiveUnknown = positiveSafetyReport.incompleteLines.first { $0.title == "Не определено" }?.children.first
        require(positiveUnknown?.note?.contains("Тип: unclassified_income") == true, "unknown diagnostic includes raw kind")

        let staleMetadataReport = FinancialEngine.report([
            op(-21_000, kind: "refund", category: "Возврат"),
            op(-34_000, kind: "interest_income", category: "Проценты"),
            op(5_500, kind: "refund", category: "Возврат")
        ], in: interval)
        require(staleMetadataReport.grossExpenseKopecks == 55_000, "negative stale refund/interest metadata contributes to expense")
        require(staleMetadataReport.refundsKopecks == 5_500, "positive refund still reduces expense")
        require(staleMetadataReport.netExpenseKopecks == 49_500, "stale metadata report net expense")
        require(staleMetadataReport.unknownCount == 0, "negative stale metadata must not remain unknown")


        let withdrawalReport = FinancialEngine.report([
            op(-75_000, kind: "expense", description: "Снятие наличных"),
            op(-300, kind: "expense", description: "Комиссия за снятие наличных")
        ], in: interval)
        require(withdrawalReport.movementLines.contains { $0.title == "Снятие наличных" && $0.amountKopecks == 75_000 }, "cash withdrawal is shown as movement")
        require(withdrawalReport.expenseLines.contains { $0.title == "Комиссии" && $0.amountKopecks == 300 }, "cash withdrawal fee remains expense")
        require(withdrawalReport.netExpenseKopecks == 300, "cash withdrawal itself is excluded from financial expense")


        let policyNow = ISO8601DateFormatter().date(from: "2033-03-20T12:00:00Z")!
        let recentCompleted = policyNow.addingTimeInterval(-1 * 86400)
        let policyBase = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: "not-a-date", status: "Выполнено")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(policyBase.days == 8, "completed operations do not need date parsing or widen refresh")

        let processing = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: "2033-03-01T12:00:00.123+03:00", status: "Обрабатывается")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(processing.days >= 20, "Обрабатывается must widen the refresh window")
        require(processing.stalePendingCount == 0, "recent processing is actively watched")

        let stalePending = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: "2032-12-01T12:00:00Z", status: "Pending")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(stalePending.days == 8, "stale pending must not widen every refresh for months")
        require(stalePending.stalePendingCount == 1, "stale pending is surfaced separately")

        let recentNoStatus = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: "2033-03-10T12:00:00Z", status: "Не указан")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(recentNoStatus.days >= 11, "recent status-less operation remains watched")

        let oldNoStatus = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: "2033-02-01T12:00:00Z", status: "Не указан")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(oldNoStatus.days == 8, "old status-less operation no longer widens refresh")

        require(FinancialEngine.isPendingStatus("Обрабатывается"), "processing status must be pending")
        require(FinancialEngine.isPendingStatus("Ожидает подтверждения"), "waiting status must be pending")
        require(FinancialEngine.isPendingStatus("hold"), "hold status must be pending")
        require(!FinancialEngine.isPendingStatus("Обработана"), "completed processed status must not be pending")
        require(FinancialEngine.classify(op(-12_345, kind: "expense", status: "Обработана")).type == .expense, "completed processed debit remains expense")

        let iso = ISO8601DateFormatter()
        let exactly14 = iso.string(from: policyNow.addingTimeInterval(-Double(IncrementalSyncPolicy.noStatusWatchDays) * 86400))
        let justOlder14 = iso.string(from: policyNow.addingTimeInterval(-Double(IncrementalSyncPolicy.noStatusWatchDays) * 86400 - 1))
        let noStatusBoundary = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: exactly14, status: "Не указан")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(noStatusBoundary.days == IncrementalSyncPolicy.noStatusWatchDays + 1, "status-less operation exactly at 14-day boundary is still watched")
        let noStatusPastBoundary = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: justOlder14, status: "Не указан")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(noStatusPastBoundary.days == 8, "status-less operation just older than 14 days no longer widens refresh")

        let exactly45 = iso.string(from: policyNow.addingTimeInterval(-Double(IncrementalSyncPolicy.pendingWatchDays) * 86400))
        let justOlder45 = iso.string(from: policyNow.addingTimeInterval(-Double(IncrementalSyncPolicy.pendingWatchDays) * 86400 - 1))
        let holdBoundary = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: exactly45, status: "hold")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(holdBoundary.days == IncrementalSyncPolicy.pendingWatchDays + 1, "pending exactly at 45-day boundary is still watched")
        require(holdBoundary.stalePendingCount == 0, "45-day boundary pending is not stale")
        let holdPastBoundary = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: justOlder45, status: "hold")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(holdPastBoundary.days == 8, "pending just older than 45 days no longer widens refresh")
        require(holdPastBoundary.stalePendingCount == 1, "pending just older than 45 days is surfaced as stale")

        let processedStatus = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: iso.string(from: policyNow.addingTimeInterval(-15 * 86400)), status: "Обработана")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(processedStatus.days == 8, "completed 'Обработана' status must not widen refresh")

        print("Finance engine tests passed")
    }
}
