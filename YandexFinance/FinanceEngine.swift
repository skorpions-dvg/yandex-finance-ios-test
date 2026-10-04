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

struct FinanceLine: Identifiable {
    let id: String
    let title: String
    let count: Int
    let amountKopecks: Int64
    let note: String?
    let children: [FinanceLine]
}

struct FinanceReport {
    let operationCount: Int
    let invalidDateCount: Int
    let incomeKopecks: Int64
    let grossExpenseKopecks: Int64
    let refundsKopecks: Int64
    let movementKopecks: Int64
    let pendingDebitKopecks: Int64
    let bankDebitKopecks: Int64
    let bankCreditKopecks: Int64
    let unknownCount: Int
    let incomeLines: [FinanceLine]
    let expenseLines: [FinanceLine]
    let movementLines: [FinanceLine]
    let incompleteLines: [FinanceLine]

    var netExpenseKopecks: Int64 { grossExpenseKopecks - refundsKopecks }
    var differenceKopecks: Int64 { incomeKopecks - netExpenseKopecks }
}

struct SyncStatusInput {
    let occurredAt: String
    let status: String
}

struct SyncLookbackResult {
    let days: Int
    let stalePendingCount: Int
}

enum BankDateParser {
    private static let fractionalISO8601 = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true)
    private static let plainISO8601 = Date.ISO8601FormatStyle(timeZoneSeparator: .colon)

    static func parse(_ value: String) -> Date? {
        (try? fractionalISO8601.parse(value)) ?? (try? plainISO8601.parse(value))
    }
}

enum IncrementalSyncPolicy {
    static let noStatusWatchDays = 14
    static let pendingWatchDays = 45

    static func operationDate(_ value: String) -> Date? { BankDateParser.parse(value) }

    static func isOpenStatus(_ value: String) -> Bool { FinancialEngine.isPendingStatus(value) }

    static func calculate(_ operations: [SyncStatusInput], lastCompletedSync: Date?, now: Date) -> SyncLookbackResult {
        var start = lastCompletedSync?.addingTimeInterval(-7 * 86400)
            ?? now.addingTimeInterval(-183 * 86400)
        let noStatusCutoff = now.addingTimeInterval(-Double(noStatusWatchDays) * 86400)
        let pendingCutoff = now.addingTimeInterval(-Double(pendingWatchDays) * 86400)
        var stalePendingCount = 0

        for operation in operations {
            let open = isOpenStatus(operation.status)
            let noStatus = FinancialEngine.isNoStatus(operation.status)
            guard open || noStatus else { continue }
            guard let date = BankDateParser.parse(operation.occurredAt) else { continue }

            if open {
                if date >= pendingCutoff {
                    start = min(start, date.addingTimeInterval(-86400))
                } else {
                    stalePendingCount += 1
                }
            } else if noStatus && date >= noStatusCutoff {
                start = min(start, date.addingTimeInterval(-86400))
            }
        }

        return SyncLookbackResult(days: max(7, Int(ceil(now.timeIntervalSince(start) / 86400))),
                                  stalePendingCount: stalePendingCount)
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

    static func isPendingStatus(_ value: String) -> Bool {
        let status = normalized(value)
        // Keep this narrower than the generic Russian root "обраб":
        // "Обрабатывается" is pending, while a completed "Обработана" is not.
        return containsAny(status, ["в обработке", "обрабатыва", "ожида", "в процессе", "pending", "hold", "заблок"])
    }

    static func isNoStatus(_ value: String) -> Bool {
        normalized(value).contains("не указан")
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

        if isPendingStatus(operation.status) {
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

        let cashback = amount > 0 && containsAny(combined, ["кэшбэк", "кешбэк", "cashback"])
        if cashback {
            return FinancialAssessment(type: .income, reason: "Кэшбэк считается доходом, а не возвратом покупки.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
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

        let cashWithdrawal = amount < 0 && containsAny(combined, ["снятие налич", "выдача налич", "банкомат"])
        if cashWithdrawal {
            return FinancialAssessment(type: .internalTransfer, reason: "Снятие наличных — перемещение денег, а не покупка.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        if kind == "transfer" {
            if amount < 0 {
                return FinancialAssessment(type: .expense, reason: "Перевод не подтверждён как перевод между своими счетами; отрицательная сумма учитывается как расход.", originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            if amount > 0 {
                return FinancialAssessment(type: .income, reason: "Перевод не подтверждён как перевод между своими счетами; положительная сумма учитывается как доход.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
            }
        }

        // Components are diagnostic detail only. Parent total is the sole financial amount.
        if kind == "grouped_operation" {
            if amount < 0 {
                return FinancialAssessment(type: .expense, reason: "Сводная операция учтена только по итогу группы; составляющие повторно не суммируются.", originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            if amount > 0 {
                return FinancialAssessment(type: .income, reason: "Сводная операция учтена только по итогу группы; составляющие повторно не суммируются.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
            }
        }

        // At this point all special cases have already been handled. Direction is authoritative for
        // old/stale generic kinds: a completed negative bank movement is an outflow and must not
        // remain "unknown" merely because an older saved record carries an obsolete income kind.
        if amount < 0 {
            let reason = (kind == "expense")
                ? "Обычное списание."
                : "Завершённое списание со старым или неподходящим типом учтено как расход по направлению суммы."
            return FinancialAssessment(type: .expense, reason: reason, originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        if amount > 0 && (kind == "unclassified_income" || kind == "income") {
            return FinancialAssessment(type: .income, reason: "Поступление, не отнесённое банком к возврату, процентам или своим переводам.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
        }

        // A finished positive movement is not guessed: it can be an own-account transfer.
        return FinancialAssessment(type: .unknown, reason: "Положительная операция без подтверждённого типа не считается доходом: это может быть перевод между своими счетами.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
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
            guard let date = BankDateParser.parse(operation.occurredAt) else {
                invalidDateCount += 1
                continue
            }
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

    static func report(_ operations: [FinancialOperationInput], in interval: DateInterval) -> FinanceReport {
        var invalidDateCount = 0
        var operationCount = 0
        var income: Int64 = 0
        var grossExpense: Int64 = 0
        var refunds: Int64 = 0
        var movement: Int64 = 0
        var pendingDebit: Int64 = 0
        var bankDebit: Int64 = 0
        var bankCredit: Int64 = 0
        var unknownCount = 0
        var incomeGroups: [String: (Int, Int64, [String: (Int, Int64)])] = [:]
        var expenseGroups: [String: (Int, Int64, [String: (Int, Int64)])] = [:]
        var movementGroups: [String: (Int, Int64)] = [:]
        var incompleteGroups: [String: (Int, Int64)] = [:]

        func add(_ groups: inout [String: (Int, Int64, [String: (Int, Int64)])], _ title: String, _ child: String?, _ amount: Int64) {
            var group = groups[title] ?? (0, Int64(0), [String: (Int, Int64)]())
            group.0 += 1
            group.1 += amount
            if let child {
                var item = group.2[child] ?? (0, Int64(0))
                item.0 += 1
                item.1 += amount
                group.2[child] = item
            }
            groups[title] = group
        }

        for operation in operations {
            guard let date = BankDateParser.parse(operation.occurredAt) else {
                invalidDateCount += 1
                continue
            }
            guard date >= interval.start && date < interval.end else { continue }
            operationCount += 1
            let assessment = classify(operation)
            let combined = normalized([operation.description, operation.category, operation.purpose ?? ""].joined(separator: " "))
            let category = operation.category.isEmpty ? "Без категории" : operation.category
            if assessment.type != .cancelled {
                if operation.amountKopecks < 0 { bankDebit += -operation.amountKopecks }
                if operation.amountKopecks > 0 { bankCredit += operation.amountKopecks }
            }
            switch assessment.type {
            case .income, .interestIncome:
                income += assessment.incomeContributionKopecks
                add(&incomeGroups, incomeTitle(operation, assessment, combined), nil, assessment.incomeContributionKopecks)
            case .expense, .commission:
                grossExpense += assessment.expenseContributionKopecks
                let title = expenseTitle(operation, assessment, combined)
                let child = title == "Покупки" ? category : nil
                add(&expenseGroups, title, child, assessment.expenseContributionKopecks)
            case .refund:
                refunds += assessment.refundContributionKopecks
                add(&expenseGroups, "Возвраты", nil, assessment.refundContributionKopecks)
            case .split:
                add(&expenseGroups, "Сплит", nil, abs(assessment.originalAmountKopecks))
            case .internalTransfer:
                movement += abs(assessment.originalAmountKopecks)
                let title = movementTitle(combined)
                var item = movementGroups[title] ?? (0, Int64(0))
                item.0 += 1
                item.1 += abs(assessment.originalAmountKopecks)
                movementGroups[title] = item
            case .pending:
                if assessment.originalAmountKopecks < 0 { pendingDebit += -assessment.originalAmountKopecks }
                var pending = incompleteGroups["В обработке"] ?? (0, Int64(0))
                pending.0 += 1
                pending.1 += assessment.originalAmountKopecks
                incompleteGroups["В обработке"] = pending
            case .cancelled:
                var cancelled = incompleteGroups["Отменено"] ?? (0, Int64(0))
                cancelled.0 += 1
                cancelled.1 += assessment.originalAmountKopecks
                incompleteGroups["Отменено"] = cancelled
            case .unknown:
                unknownCount += 1
                var unknown = incompleteGroups["Не определено"] ?? (0, Int64(0))
                unknown.0 += 1
                unknown.1 += assessment.originalAmountKopecks
                incompleteGroups["Не определено"] = unknown
            }
        }

        let incomeOrder = ["Переводы от других", "Пополнения", "Зарплата и выплаты", "Кэшбэк", "Проценты", "Прочие доходы"]
        let expenseOrder = ["Покупки", "Переводы другим", "Комиссии", "Сплит", "Прочие расходы", "Возвраты"]
        let incompleteOrder = ["В обработке", "Не определено", "Отменено"]
        let incompleteLines = incompleteOrder.compactMap { title -> FinanceLine? in
            guard let item = incompleteGroups[title], item.0 > 0 else { return nil }
            let note = title == "В обработке" ? "Не входит в окончательный расход." : nil
            return FinanceLine(id: title, title: title, count: item.0, amountKopecks: item.1, note: note, children: [])
        }
        return FinanceReport(operationCount: operationCount, invalidDateCount: invalidDateCount,
                             incomeKopecks: income, grossExpenseKopecks: grossExpense, refundsKopecks: refunds,
                             movementKopecks: movement, pendingDebitKopecks: pendingDebit,
                             bankDebitKopecks: bankDebit, bankCreditKopecks: bankCredit, unknownCount: unknownCount,
                             incomeLines: lines(incomeGroups, order: incomeOrder),
                             expenseLines: lines(expenseGroups, order: expenseOrder),
                             movementLines: movementGroups.map { FinanceLine(id: $0.key, title: $0.key, count: $0.value.0, amountKopecks: $0.value.1, note: nil, children: []) }.sorted { $0.title < $1.title },
                             incompleteLines: incompleteLines)
    }

    private static func incomeTitle(_ operation: FinancialOperationInput, _ assessment: FinancialAssessment, _ combined: String) -> String {
        if assessment.type == .interestIncome || combined.contains("процент") { return "Проценты" }
        if containsAny(combined, ["кэшбэк", "кешбэк", "cashback"]) { return "Кэшбэк" }
        if combined.contains("зарплат") { return "Зарплата и выплаты" }
        if containsAny(combined, ["банкомат", "внесение налич", "пополнение"]) { return "Пополнения" }
        if operation.kind == "transfer" || combined.contains("перевод") { return "Переводы от других" }
        return "Прочие доходы"
    }

    private static func expenseTitle(_ operation: FinancialOperationInput, _ assessment: FinancialAssessment, _ combined: String) -> String {
        if assessment.type == .commission || combined.contains("комисси") { return "Комиссии" }
        if operation.kind == "transfer" || combined.contains("перевод") { return "Переводы другим" }
        if operation.category == "Не определено" || operation.category.isEmpty { return "Прочие расходы" }
        return "Покупки"
    }

    private static func movementTitle(_ combined: String) -> String {
        if containsAny(combined, ["снятие налич", "выдача налич", "банкомат"]) { return "Снятие наличных" }
        if containsAny(combined, ["сейв", "накопитель"]) { return "Накопительные счета" }
        return "Между своими счетами"
    }

    private static func lines(_ groups: [String: (Int, Int64, [String: (Int, Int64)])], order: [String]) -> [FinanceLine] {
        order.compactMap { title in
            guard let group = groups[title], group.0 > 0 else { return nil }
            let children = group.2.map { FinanceLine(id: title + "/" + $0.key, title: $0.key, count: $0.value.0, amountKopecks: $0.value.1, note: nil, children: []) }
                .sorted { $0.amountKopecks > $1.amountKopecks }
            let note = title == "Сплит" ? "Пока не входит в итог расходов, чтобы не задвоить покупку." : (title == "Возвраты" ? "Уменьшает расходы, это не заработок." : nil)
            return FinanceLine(id: title, title: title, count: group.0, amountKopecks: group.1, note: note, children: children)
        }
    }
}
