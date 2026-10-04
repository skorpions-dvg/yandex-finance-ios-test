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
                   providers: [String] = [], components: [Int64] = [], date: String = "2026-10-02T10:00:00Z") -> FinancialOperationInput {
        FinancialOperationInput(occurredAt: date, description: description, amountKopecks: amount,
                                status: status, category: category, purpose: purpose,
                                providers: providers, kind: kind, componentAmountsKopecks: components)
    }

    static func main() {
        require(FinancialEngine.classify(op(-10_000, kind: "expense")).type == .expense, "expense")
        require(FinancialEngine.classify(op(5_000, kind: "unclassified_income")).type == .income, "income")
        require(FinancialEngine.classify(op(3_000, kind: "refund", category: "Возврат")).type == .refund, "refund")
        require(FinancialEngine.classify(op(50_000, kind: "internal_transfer", category: "Переводы между своими счетами")).type == .internalTransfer, "internal transfer")
        require(FinancialEngine.classify(op(30, kind: "interest_income", category: "Проценты")).type == .interestIncome, "interest")
        require(FinancialEngine.classify(op(-199, kind: "expense", description: "Комиссия банка")).type == .commission, "commission")
        require(FinancialEngine.classify(op(-20_000, kind: "installment_payment", providers: ["BNPL"])).type == .split, "split")
        require(FinancialEngine.classify(op(-4_000, kind: "expense", status: "В обработке")).type == .pending, "pending")
        require(FinancialEngine.classify(op(-5_000, kind: "expense", status: "Отменено")).type == .cancelled, "cancelled")
        require(FinancialEngine.classify(op(-6_000, kind: "new_unknown_kind")).type == .expense, "completed negative unknown kind is an expense")
        require(FinancialEngine.classify(op(6_000, kind: "new_unknown_kind")).type == .unknown, "positive unknown kind must not be guessed as income")
        require(FinancialEngine.classify(op(-7_000, kind: "transfer")).type == .expense, "external outgoing transfer")
        require(FinancialEngine.classify(op(8_000, kind: "transfer")).type == .income, "external incoming transfer")

        let grouped = op(-163_500, kind: "grouped_operation", components: [-190_000, 26_500])
        let groupedAssessment = FinancialEngine.classify(grouped)
        require(groupedAssessment.type == .expense, "grouped type")
        require(groupedAssessment.expenseContributionKopecks == 163_500, "grouped parent total only")

        let formatter = ISO8601DateFormatter()
        let interval = DateInterval(start: formatter.date(from: "2026-10-01T00:00:00Z")!,
                                    end: formatter.date(from: "2026-11-01T00:00:00Z")!)
        let summary = FinancialEngine.summarize([
            op(-10_000, kind: "expense"),
            op(3_000, kind: "refund", category: "Возврат"),
            op(5_000, kind: "unclassified_income"),
            op(30, kind: "interest_income", category: "Проценты"),
            op(50_000, kind: "internal_transfer", category: "Переводы между своими счетами"),
            op(-199, kind: "expense", description: "Комиссия банка"),
            op(-20_000, kind: "installment_payment", providers: ["BNPL"]),
            op(-4_000, kind: "expense", status: "В обработке"),
            op(-5_000, kind: "expense", status: "Отменено"),
            grouped,
            op(-99_999, kind: "expense", date: "2026-09-30T23:59:59Z")
        ], in: interval)

        require(summary.operationCount == 10, "period filtering")
        require(summary.grossExpenseKopecks == 173_699, "gross expenses use parent group once")
        require(summary.refundsKopecks == 3_000, "refund contribution")
        require(summary.netExpenseKopecks == 170_699, "net expense")
        require(summary.incomeKopecks == 5_030, "ordinary + interest income")
        require(summary.netCashFlowKopecks == -165_669, "net cash flow")
        require(summary.counts[.internalTransfer] == 1, "internal transfer bucket")
        require(summary.counts[.split] == 1, "split bucket")
        require(summary.counts[.pending] == 1, "pending bucket")
        require(summary.counts[.cancelled] == 1, "cancelled bucket")
        require(summary.signedAmounts[.expense] == -173_500, "component amounts must not be added to type totals")

        let dateFormatter = ISO8601DateFormatter()
        let february = DateInterval(start: dateFormatter.date(from: "2031-02-01T00:00:00Z")!,
                                    end: dateFormatter.date(from: "2031-03-01T00:00:00Z")!)
        let dateFormats = FinancialEngine.summarize([
            op(-111, kind: "expense", date: "2031-02-14T12:34:56.789Z"),
            op(-222, kind: "expense", date: "2031-02-15T12:34:56Z"),
            op(-333, kind: "expense", date: "2031-02-16T15:34:56.123+03:00"),
            op(-444, kind: "expense", date: "2031-03-01T00:00:00Z"),
            op(-555, kind: "expense", date: "not-a-date")
        ], in: february)
        require(dateFormats.operationCount == 3, "fractional and plain ISO8601 dates must be included")
        require(dateFormats.grossExpenseKopecks == 666, "period totals must include fractional-second timestamps")
        require(dateFormats.invalidDateCount == 1, "invalid dates must be surfaced instead of silently disappearing")

        let october = FinancialEngine.report([
            op(-1_783_100, kind: "legacy_purchase", category: "Супермаркеты"),
            op(188_600, kind: "refund", category: "Возврат"),
            op(-163_582, kind: "expense", status: "В обработке"),
            op(9_000, kind: "new_unknown_kind", description: "Непонятное поступление")
        ], in: interval)
        require(october.operationCount == 4, "october control count")
        require(october.grossExpenseKopecks == 1_783_100, "legacy debit is an expense")
        require(october.refundsKopecks == 188_600, "october refund")
        require(october.netExpenseKopecks == 1_594_500, "expense after refund")
        require(october.pendingDebitKopecks == 163_582, "pending stays out of final expense")
        require(october.bankDebitKopecks == 1_946_682, "bank debit is settled plus pending")
        require(october.incomeKopecks == 0, "unknown credit is not income")
        require(october.unknownCount == 1, "unknown credit remains visible")
        require(october.expenseLines.contains { $0.title == "Покупки" && $0.children.contains { $0.title == "Супермаркеты" } }, "purchase category expands")

        print("Finance engine tests passed")
    }
}
