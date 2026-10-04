import Foundation

enum FinancialType: String, CaseIterable, Identifiable {
    case expense
    case income
    case refund
    case internalTransfer = "internal_transfer"
    case interestIncome = "interest_income"
    case commission
    case split
    case pending
    case cancelled
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense: return "Расход"
        case .income: return "Доход"
        case .refund: return "Возврат"
        case .internalTransfer: return "Между своими счетами"
        case .interestIncome: return "Проценты"
        case .commission: return "Комиссия"
        case .split: return "Сплит"
        case .pending: return "В обработке"
        case .cancelled: return "Отменено"
        case .unknown: return "Не определено"
        }
    }
}

struct FinancialOperationInput {
    let occurredAt: String
    let description: String
    let amountKopecks: Int64
    let status: String
    let category: String
    let purpose: String?
    let providers: [String]
    let kind: String
    let componentAmountsKopecks: [Int64]
}

struct FinancialAssessment {
    let type: FinancialType
    let reason: String
    let originalAmountKopecks: Int64
    let expenseContributionKopecks: Int64
    let incomeContributionKopecks: Int64
    let refundContributionKopecks: Int64
}

struct FinancialBucket: Identifiable {
    let type: FinancialType
    let count: Int
    let signedAmountKopecks: Int64
    var id: String { type.rawValue }
}

struct FinancialSummary {
    let operationCount: Int
    let invalidDateCount: Int
    let counts: [FinancialType: Int]
    let signedAmounts: [FinancialType: Int64]
    let grossExpenseKopecks: Int64
    let refundsKopecks: Int64
    let incomeKopecks: Int64

    var netExpenseKopecks: Int64 { grossExpenseKopecks - refundsKopecks }
    var netCashFlowKopecks: Int64 { incomeKopecks - netExpenseKopecks }

    var buckets: [FinancialBucket] {
        FinancialType.allCases.compactMap { type in
            let count = counts[type] ?? 0
            guard count > 0 else { return nil }
            return FinancialBucket(type: type, count: count, signedAmountKopecks: signedAmounts[type] ?? 0)
        }
    }
}

enum FinancialEngine {
    private static func normalized(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func containsAny(_ value: String, _ fragments: [String]) -> Bool {
        fragments.contains { value.contains($0) }
    }

    static func classify(_ operation: FinancialOperationInput) -> FinancialAssessment {
        let status = normalized(operation.status)
        let category = normalized(operation.category)
        let description = normalized(operation.description)
        let purpose = normalized(operation.purpose)
        let combined = [description, category, purpose].joined(separator: " ")
        let kind = normalized(operation.kind)
        let amount = operation.amountKopecks

        if containsAny(status, ["отмен", "отклон", "аннулир", "не выполн", "cancelled", "canceled"]) {
            return FinancialAssessment(type: .cancelled, reason: "Банк пометил операцию как отменённую/не выполненную.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        if containsAny(status, ["в обработке", "обрабаты", "ожида", "в процессе", "pending", "hold", "заблок"]) {
            return FinancialAssessment(type: .pending, reason: "Операция ещё не завершена и пока не входит в окончательные итоги.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        let explicitRefund = kind == "refund" || category.contains("возврат") || description.hasPrefix("возврат") || purpose.contains("возврат")
        if explicitRefund {
            guard amount > 0 else {
                return FinancialAssessment(type: .unknown, reason: "Операция похожа на возврат, но имеет неожиданное направление суммы.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            return FinancialAssessment(type: .refund, reason: "Возврат уменьшает расходы, а не считается заработком.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: amount)
        }

        if kind == "internal_transfer" || category.contains("переводы между своими счетами") {
            return FinancialAssessment(type: .internalTransfer, reason: "Подтверждённое перемещение между своими счетами исключено из доходов и расходов.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        let explicitInterest = kind == "interest_income" || category == "проценты" || (amount > 0 && combined.contains("процент"))
        if explicitInterest {
            guard amount > 0 else {
                return FinancialAssessment(type: .unknown, reason: "Операция похожа на начисление процентов, но сумма не является поступлением.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            return FinancialAssessment(type: .interestIncome, reason: "Начисленные проценты считаются доходом.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
        }

        let split = kind == "installment_payment" || operation.providers.contains(where: { normalized($0) == "bnpl" }) || category.contains("сплит")
        if split {
            return FinancialAssessment(type: .split, reason: "Сплит учитывается отдельно до связывания покупки и платежей, чтобы не задвоить расходы.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        let commission = kind == "commission" || combined.contains("комисси")
        if commission {
            guard amount < 0 else {
                return FinancialAssessment(type: .unknown, reason: "Комиссия имеет неожиданное направление суммы и не включена в итог автоматически.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            return FinancialAssessment(type: .commission, reason: "Комиссия является расходом.", originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        if kind == "expense" {
            guard amount < 0 else {
                return FinancialAssessment(type: .unknown, reason: "Расход имеет неожиданно положительную сумму.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            return FinancialAssessment(type: .expense, reason: "Обычное списание.", originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        if kind == "unclassified_income" || kind == "income" {
            guard amount > 0 else {
                return FinancialAssessment(type: .unknown, reason: "Доход имеет неожиданно отрицательную сумму.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            return FinancialAssessment(type: .income, reason: "Поступление, не отнесённое банком к возврату, процентам или своим переводам.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
        }

        if kind == "transfer" {
            if amount < 0 {
                return FinancialAssessment(type: .expense, reason: "Перевод не подтверждён как перевод между своими счетами; отрицательная сумма учитывается как расход.", originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            if amount > 0 {
                return FinancialAssessment(type: .income, reason: "Перевод не подтверждён как перевод между своими счетами; положительная сумма учитывается как доход.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
            }
        }

        if kind == "grouped_operation" {
            // Components are diagnostic detail only. The bank-provided parent amount is already
            // the reconciled group total and is the only value included in financial totals.
            if amount < 0 {
                return FinancialAssessment(type: .expense, reason: "Сводная операция учтена только по итогу группы; составляющие повторно не суммируются.", originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            if amount > 0 {
                return FinancialAssessment(type: .income, reason: "Сводная операция учтена только по итогу группы; составляющие повторно не суммируются.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
            }
        }

        return FinancialAssessment(type: .unknown, reason: "Недостаточно подтверждённых признаков для автоматической классификации.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
    }

    private static func operationDate(_ value: String) -> Date? {
        // Collector.js serializes source timestamps with Date.toISOString(), which always
        // includes fractional seconds (for example 2026-04-02T17:41:00.705Z).
        // Older/migrated records and synthetic tests may omit them, so support both forms.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    static func summarize(_ operations: [FinancialOperationInput], in interval: DateInterval) -> FinancialSummary {
        var counts: [FinancialType: Int] = [:]
        var signedAmounts: [FinancialType: Int64] = [:]
        var grossExpense: Int64 = 0
        var refunds: Int64 = 0
        var income: Int64 = 0
        var operationCount = 0
        var invalidDateCount = 0

        for operation in operations {
            guard let date = operationDate(operation.occurredAt) else {
                invalidDateCount += 1
                continue
            }
            // DateInterval.contains includes the end instant. Month/day accounting needs a
            // half-open interval [start, end), otherwise exactly 00:00 of the next period is
            // counted twice.
            guard date >= interval.start && date < interval.end else { continue }
            operationCount += 1
            let assessment = classify(operation)
            counts[assessment.type, default: 0] += 1
            signedAmounts[assessment.type, default: 0] += assessment.originalAmountKopecks
            grossExpense += assessment.expenseContributionKopecks
            refunds += assessment.refundContributionKopecks
            income += assessment.incomeContributionKopecks
        }

        return FinancialSummary(operationCount: operationCount, invalidDateCount: invalidDateCount,
                                counts: counts, signedAmounts: signedAmounts,
                                grossExpenseKopecks: grossExpense, refundsKopecks: refunds, incomeKopecks: income)
    }
}
