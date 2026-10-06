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
    let mcc: String?
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

struct FinanceCategoryPath: Equatable, Hashable {
    let group: String
    let subcategory: String
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

struct SaveAccountSummary {
    let toSaveKopecks: Int64
    let fromSaveKopecks: Int64
    let interestIncomeKopecks: Int64
    let operationCount: Int

    var netTransferKopecks: Int64 { toSaveKopecks - fromSaveKopecks }
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

    private static func containsWord(_ value: String, _ word: String) -> Bool {
        value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == word }
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

        let split = kind == "installment_payment" || operation.providers.contains(where: { normalized($0) == "bnpl" }) || category.contains("сплит")
        if amount == 0 {
            return FinancialAssessment(type: .unknown, reason: "Нулевая сумма не создаёт доход или расход; природа операции требует проверки.", originalAmountKopecks: 0, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        let transferHint = kind == "transfer" || category.contains("перевод") || category.contains("пополн")
        // Cash brought to the card is money coming in, never a purchase refund, even if the card was tagged as one.
        let cashDeposit = amount > 0 && !split && kind != "internal_transfer" && containsAny(combined, ["пополнение налич", "внесение налич", "взнос налич"])
        if cashDeposit {
            return FinancialAssessment(type: .income, reason: "Внесение наличных считается доходом (пополнение), а не возвратом покупки.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
        }
        let refundText = !transferHint && containsAny([description, purpose].joined(separator: " "),
                                     ["возврат покупки", "возврат средств", "возврат оплаты", "возврат платежа", "возврат по операции"])
        let explicitRefund = kind == "refund" || category == "возврат" || category.contains("возврат покупки") || refundText
        if explicitRefund && amount > 0 && !split {
            return FinancialAssessment(type: .refund, reason: "Возврат уменьшает расходы, а не считается заработком.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: amount)
        }

        let strongCommission = kind == "commission" || category.contains("комисси")
        let mentionsNoCommission = containsAny(combined, ["без комиссии", "комиссия 0", "комиссия: 0"])
        let textCommission = !mentionsNoCommission && (description.hasPrefix("комиссия") || purpose.hasPrefix("комиссия") ||
            containsAny(combined, ["комиссия банка", "комиссия за", "комиссия по"]))
        let commission = strongCommission || textCommission
        if commission {
            guard amount < 0 else {
                return FinancialAssessment(type: .unknown, reason: "Комиссия имеет неожиданное направление суммы и не включена в итог автоматически.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            return FinancialAssessment(type: .commission, reason: "Комиссия является расходом.", originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        let ownTransferText = containsAny(category, ["между своими счетами", "между моими счетами", "между счетами одного клиента"]) ||
            containsAny(combined, ["между своими счетами", "между моими счетами", "перевод между счетами одного клиента"])
        if kind == "internal_transfer" || ownTransferText {
            return FinancialAssessment(type: .internalTransfer, reason: "Подтверждённое перемещение между своими счетами исключено из доходов и расходов.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        if split {
            return FinancialAssessment(type: .split, reason: "Сплит учитывается отдельно до связывания покупки и платежей, чтобы не задвоить расходы.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }


        // Cashback wins over generic mentions of percentages (for example, “кэшбэк 5 процентов”).
        let cashback = amount > 0 && containsAny(combined, ["кэшбэк", "кешбэк", "cashback"])
        if cashback {
            return FinancialAssessment(type: .income, reason: "Кэшбэк считается доходом, а не возвратом покупки.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
        }

        let interestText = containsAny(combined, ["начисление процентов", "начислены проценты", "выплата процентов", "выплачены проценты", "процентный доход"])
        // Explicit interest wording/category wins over a generic «Пополнение/Перевод» label.
        // A stale collector kind alone still cannot override a real transfer category.
        let explicitInterest = category == "проценты" || (amount > 0 && interestText) || (kind == "interest_income" && !transferHint)
        if explicitInterest && amount > 0 {
            return FinancialAssessment(type: .interestIncome, reason: "Начисленные проценты считаются доходом.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
        }

        let salary = amount > 0 && containsAny(combined, ["зарплат", "заработная плата"])
        if salary {
            return FinancialAssessment(type: .income, reason: "Поступление распознано как зарплата или выплата работодателя.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
        }


        let cashWithdrawal = amount < 0 && containsAny(combined, ["снятие налич", "выдача налич", "банкомат"])
        if cashWithdrawal {
            return FinancialAssessment(type: .internalTransfer, reason: "Снятие наличных — перемещение денег, а не покупка.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        if transferHint {
            if amount < 0 {
                return FinancialAssessment(type: .expense, reason: "Перевод не подтверждён как перевод между своими счетами; отрицательная сумма учитывается как расход.", originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
            }
            if amount > 0 {
                return FinancialAssessment(type: .income, reason: "Перевод не подтверждён как перевод между своими счетами; положительная сумма учитывается как доход.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
            }
        }

        // Components are diagnostic detail only. Parent total is the sole financial amount.
        // A negative group is a bank outflow; a positive group is not guessed as income unless
        // one of the explicit rules above already identified what it is.
        if kind == "grouped_operation", amount < 0 {
            return FinancialAssessment(type: .expense, reason: "Сводная операция учтена только по итогу группы; составляющие повторно не суммируются.", originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        // At this point all cases that are allowed to override the direction of a bank movement
        // have already been handled. Direction is authoritative for old/stale metadata: a completed
        // negative movement is an outflow even when an older saved record incorrectly says
        // "refund", "interest_income" or another generic/obsolete kind.
        if amount < 0 {
            let reason = (kind == "expense")
                ? "Обычное списание."
                : "Завершённое списание со старым или противоречивым типом учтено как расход по направлению суммы."
            return FinancialAssessment(type: .expense, reason: reason, originalAmountKopecks: amount, expenseContributionKopecks: -amount, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }

        if amount > 0 && kind == "income" {
            return FinancialAssessment(type: .income, reason: "Банк явно сохранил операцию как доход.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: amount, refundContributionKopecks: 0)
        }

        // Collector uses “unclassified_income” for positive movements whose nature is not proven.
        // Do not turn that technical fallback into financial income: it can still be an own transfer.
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
        var unknownDetails: [FinanceLine] = []

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
            if assessment.type != .cancelled {
                if operation.amountKopecks < 0 { bankDebit += -operation.amountKopecks }
                if operation.amountKopecks > 0 { bankCredit += operation.amountKopecks }
            }
            switch assessment.type {
            case .income, .interestIncome:
                income += assessment.incomeContributionKopecks
                add(&incomeGroups, incomeCategory(for: operation, assessment: assessment), nil, assessment.incomeContributionKopecks)
            case .expense, .commission:
                grossExpense += assessment.expenseContributionKopecks
                let path = expenseCategory(for: operation, assessment: assessment)
                add(&expenseGroups, path.group, path.subcategory, assessment.expenseContributionKopecks)
            case .refund:
                refunds += assessment.refundContributionKopecks
                add(&expenseGroups, "Возвраты", nil, assessment.refundContributionKopecks)
            case .split:
                add(&expenseGroups, "Сплит", nil, abs(assessment.originalAmountKopecks))
            case .internalTransfer:
                movement += abs(assessment.originalAmountKopecks)
                let title = movementCategory(for: operation)
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
                let title = operation.description.isEmpty ? "Операция без названия" : operation.description
                let rawCategory = operation.category.isEmpty ? "Без категории" : operation.category
                let rawKind = operation.kind.isEmpty ? "не указан" : operation.kind
                let rawStatus = operation.status.isEmpty ? "не указан" : operation.status
                let diagnostic = "\(assessment.reason) Дата: \(operation.occurredAt). Категория: \(rawCategory). Тип: \(rawKind). Статус: \(rawStatus)."
                unknownDetails.append(FinanceLine(id: "unknown/\(operation.occurredAt)/\(operation.amountKopecks)/\(unknownCount)",
                                                  title: title,
                                                  count: 1,
                                                  amountKopecks: operation.amountKopecks,
                                                  note: diagnostic,
                                                  children: []))
            }
        }

        let incomeOrder = ["Переводы от других", "Пополнения", "Зарплата и выплаты", "Кэшбэк", "Проценты", "Прочие доходы"]
        let expenseOrder = expenseGroupOrder + ["Сплит", "Возвраты"]
        let incompleteOrder = ["В обработке", "Не определено", "Отменено"]
        let incompleteLines = incompleteOrder.compactMap { title -> FinanceLine? in
            guard let item = incompleteGroups[title], item.0 > 0 else { return nil }
            let note = title == "В обработке" ? "Не входит в окончательный расход." : nil
            let children = title == "Не определено"
                ? unknownDetails.sorted { lhs, rhs in
                    if lhs.amountKopecks != rhs.amountKopecks { return lhs.amountKopecks < rhs.amountKopecks }
                    return lhs.title < rhs.title
                }
                : []
            return FinanceLine(id: title, title: title, count: item.0, amountKopecks: item.1, note: note, children: children)
        }
        return FinanceReport(operationCount: operationCount, invalidDateCount: invalidDateCount,
                             incomeKopecks: income, grossExpenseKopecks: grossExpense, refundsKopecks: refunds,
                             movementKopecks: movement, pendingDebitKopecks: pendingDebit,
                             bankDebitKopecks: bankDebit, bankCreditKopecks: bankCredit, unknownCount: unknownCount,
                             incomeLines: lines(incomeGroups, order: incomeOrder),
                             expenseLines: lines(expenseGroups, order: expenseOrder, childOrder: expenseSubcategoryOrder),
                             movementLines: movementGroups.map { FinanceLine(id: $0.key, title: $0.key, count: $0.value.0, amountKopecks: $0.value.1, note: nil, children: []) }.sorted { $0.title < $1.title },
                             incompleteLines: incompleteLines)
    }

    // MARK: - Month-over-month comparison

    struct MonthlyChange: Equatable {
        enum Relative: Equatable {
            case percent(Double)
            /// Growth from a zero base.
            case new
            /// No meaningful base: both values are zero, the value fell to zero from nothing, or the base is negative.
            case notApplicable
        }

        let current: Int64
        let previous: Int64
        var delta: Int64 { current - previous }
        var relative: Relative {
            if previous > 0 { return .percent(Double(delta) * 100 / Double(previous)) }
            if previous == 0 && current > 0 { return .new }
            return .notApplicable
        }
    }

    struct CategoryGrowth: Equatable {
        let group: String
        let subcategory: String
        let change: MonthlyChange
    }

    struct MonthlyComparison {
        let income: MonthlyChange
        let netExpense: MonthlyChange
        let difference: MonthlyChange
        /// Expense subcategory with the largest growth in rubles; nil when nothing grew.
        let topExpenseGrowth: CategoryGrowth?
    }

    /// Subcategories that are not spending on goods or services and stay out of the growth ranking.
    static let comparisonExcludedSubcategories: Set<String> = ["Переводы другим"]

    static func compareReports(_ operations: [FinancialOperationInput], currentInterval: DateInterval, previousInterval: DateInterval) -> MonthlyComparison {
        let current = report(operations, in: currentInterval)
        let previous = report(operations, in: previousInterval)

        func subcategoryAmounts(_ report: FinanceReport) -> [String: Int64] {
            var amounts: [String: Int64] = [:]
            for group in report.expenseLines {
                for line in group.children { amounts[line.id] = line.amountKopecks }
            }
            return amounts
        }
        let currentAmounts = subcategoryAmounts(current)
        let previousAmounts = subcategoryAmounts(previous)

        // Walk the fixed taxonomy so equal growth always picks the same category. Split and refunds
        // are not part of it, so they never enter the ranking.
        var best: CategoryGrowth?
        for group in expenseGroupOrder {
            for subcategory in expenseSubcategoryOrder where !comparisonExcludedSubcategories.contains(subcategory) {
                let id = group + "/" + subcategory
                let change = MonthlyChange(current: currentAmounts[id] ?? 0, previous: previousAmounts[id] ?? 0)
                if change.delta > 0 && change.delta > (best?.change.delta ?? 0) {
                    best = CategoryGrowth(group: group, subcategory: subcategory, change: change)
                }
            }
        }

        return MonthlyComparison(
            income: MonthlyChange(current: current.incomeKopecks, previous: previous.incomeKopecks),
            netExpense: MonthlyChange(current: current.netExpenseKopecks, previous: previous.netExpenseKopecks),
            difference: MonthlyChange(current: current.differenceKopecks, previous: previous.differenceKopecks),
            topExpenseGrowth: best)
    }

    // MARK: - Month forecast

    struct MonthForecast: Equatable {
        /// Net expense (after refunds) from the first day of the month through today.
        let spentKopecks: Int64
        /// Spending at the same daily pace for the whole month.
        let projectedKopecks: Int64
        /// Net expense of the whole previous month.
        let previousMonthKopecks: Int64
        /// Income from the first day of the month through today.
        let incomeKopecks: Int64
        let elapsedDays: Int
        let daysInMonth: Int
    }

    /// Whether this month's spending pace fits: today's month-to-date numbers extrapolated linearly
    /// to the end of the month, next to the previous month's total. Uses `report`, so the usual rules apply.
    static func monthForecast(_ operations: [FinancialOperationInput], now: Date = Date(), calendar: Calendar = .current) -> MonthForecast {
        let periods = monthComparisonPeriods(selectedStart: now, currentDate: now, calendar: calendar)
        let monthStartDate = periods.current.start
        let previousMonth = DateInterval(start: periods.previous.start, end: monthStartDate)
        let elapsed = calendar.dateComponents([.day], from: monthStartDate, to: periods.current.end).day ?? 1
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStartDate)?.count ?? 30
        let soFar = report(operations, in: periods.current)
        let spent = soFar.netExpenseKopecks
        return MonthForecast(spentKopecks: spent,
                             projectedKopecks: elapsed > 0 ? spent * Int64(daysInMonth) / Int64(elapsed) : spent,
                             previousMonthKopecks: report(operations, in: previousMonth).netExpenseKopecks,
                             incomeKopecks: soFar.incomeKopecks,
                             elapsedDays: elapsed,
                             daysInMonth: daysInMonth)
    }

    // MARK: - Chart data

    struct CategoryAmount: Equatable, Identifiable {
        let title: String
        let amountKopecks: Int64
        var id: String { title }
    }

    /// Spending per top-level expense group, in taxonomy order, taken from the report's own lines.
    /// Split and refunds are not groups, so the amounts add up to `grossExpenseKopecks`.
    static func expenseByGroup(_ report: FinanceReport) -> [CategoryAmount] {
        report.expenseLines
            .filter { expenseGroupOrder.contains($0.title) && $0.amountKopecks > 0 }
            .map { CategoryAmount(title: $0.title, amountKopecks: $0.amountKopecks) }
    }

    struct DailyAmount: Equatable, Identifiable {
        let day: Date
        let amountKopecks: Int64
        var id: Date { day }
    }

    /// Net expense (after refunds) for every calendar day of the interval, built from `report` so the
    /// same classification rules apply; the amounts add up to the interval's `netExpenseKopecks`.
    static func dailyNetExpense(_ operations: [FinancialOperationInput], in interval: DateInterval, calendar: Calendar = .current) -> [DailyAmount] {
        var days: [DailyAmount] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let slice = DateInterval(start: max(day, interval.start), end: min(next, interval.end))
            days.append(DailyAmount(day: day, amountKopecks: report(operations, in: slice).netExpenseKopecks))
            day = next
        }
        return days
    }

    static func saveAccountSummary(_ operations: [FinancialOperationInput], in interval: DateInterval) -> SaveAccountSummary {
        var toSave: Int64 = 0
        var fromSave: Int64 = 0
        var interest: Int64 = 0
        var tracked = 0

        for operation in operations {
            guard let date = BankDateParser.parse(operation.occurredAt), date >= interval.start && date < interval.end else { continue }
            let assessment = classify(operation)
            if assessment.type == .internalTransfer && isSaveTransfer(operation) {
                if operation.amountKopecks < 0 { toSave += -operation.amountKopecks }
                if operation.amountKopecks > 0 { fromSave += operation.amountKopecks }
                tracked += 1
            } else if assessment.type == .interestIncome {
                interest += assessment.incomeContributionKopecks
                tracked += 1
            }
        }

        return SaveAccountSummary(toSaveKopecks: toSave, fromSaveKopecks: fromSave,
                                  interestIncomeKopecks: interest, operationCount: tracked)
    }

    static func incomeCategory(for operation: FinancialOperationInput, assessment: FinancialAssessment? = nil) -> String {
        let assessment = assessment ?? classify(operation)
        let combined = normalized([operation.description, operation.category, operation.purpose ?? ""].joined(separator: " "))
        if containsAny(combined, ["кэшбэк", "кешбэк", "cashback"]) { return "Кэшбэк" }
        if assessment.type == .interestIncome { return "Проценты" }
        if containsAny(combined, ["зарплат", "заработная плата"]) { return "Зарплата и выплаты" }
        if containsAny(combined, ["банкомат", "внесение налич", "пополн"]) { return "Пополнения" }
        if normalized(operation.kind) == "transfer" || combined.contains("перевод") { return "Переводы от других" }
        return "Прочие доходы"
    }

    static let expenseGroupOrder = ["Еда", "Транспорт", "Покупки", "Обязательные", "Другое"]
    static let expenseSubcategoryOrder = [
        "Супермаркеты", "Кафе и рестораны", "Доставка еды",
        "Такси", "Общественный транспорт", "Топливо", "Авто",
        "Маркетплейсы", "Одежда", "Электроника", "Дом и быт",
        "ЖКХ", "Связь и интернет", "Подписки", "Здоровье",
        "Развлечения", "Путешествия", "Подарки", "Доставка и курьеры", "Переводы другим", "Комиссии", "Прочее"
    ]

    static func expenseCategory(for operation: FinancialOperationInput, assessment: FinancialAssessment? = nil) -> FinanceCategoryPath {
        let assessment = assessment ?? classify(operation)
        let category = normalized(operation.category)
        let kind = normalized(operation.kind)
        let description = normalized(operation.description)
        let purpose = normalized(operation.purpose)
        let freeText = [description, purpose].filter { !$0.isEmpty }.joined(separator: " ")
        let mcc = (operation.mcc ?? "").filter(\.isNumber)

        // Financial nature wins over merchant wording. A transfer or bank fee must never be
        // swallowed by a merchant/category keyword.
        if assessment.type == .commission {
            return FinanceCategoryPath(group: "Другое", subcategory: "Комиссии")
        }

        // A few services are more specific than the bank's broad technical category/MCC.
        // Keep these rules narrow so generic Yandex or transfer operations are not reclassified.
        if containsAny(freeText, ["яндекс плюс", "yandex plus"]) {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Подписки")
        }
        if containsAny(description, ["яндекс.доставка", "яндекс доставка", "yandex delivery"]) {
            return FinanceCategoryPath(group: "Другое", subcategory: "Доставка и курьеры")
        }

        let hasPersonalAccount = containsAny(purpose, ["лицевой счет", "лицевой сч", "л/с"])
        let housingRecipient = hasPersonalAccount
            && (description.contains("жилищник") || containsAny(description, ["управляющ", "ооо ук ", " ук ", "тсж", "жск"]))
        let gasUtilityRecipient = containsAny(description, ["горгаз", "межрегионгаз"])
            && (hasPersonalAccount || category.contains("перевод"))
        if housingRecipient || gasUtilityRecipient {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "ЖКХ")
        }

        if kind == "transfer" || category.contains("перевод") {
            return FinanceCategoryPath(group: "Другое", subcategory: "Переводы другим")
        }

        // Bank category is the strongest taxonomy signal. Resolve it before free-text so phrases
        // such as “интернет-магазин цветов” do not become “Связь и интернет”.
        if containsAny(category, ["доставка еды", "доставка продуктов"]) {
            return FinanceCategoryPath(group: "Еда", subcategory: "Доставка еды")
        }
        if containsAny(category, ["супермаркет", "продукт", "продоволь", "гипермаркет", "магазины продуктов"]) {
            return FinanceCategoryPath(group: "Еда", subcategory: "Супермаркеты")
        }
        if containsAny(category, ["кафе", "ресторан", "фастфуд", "кофейн", "общественное питание", "столов"]) {
            return FinanceCategoryPath(group: "Еда", subcategory: "Кафе и рестораны")
        }
        if category.contains("такси") {
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Такси")
        }
        if (containsWord(category, "метро") || containsAny(category, ["автобус", "трамвай", "троллейбус", "общественный транспорт", "проезд", "транспортная карта"])) {
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Общественный транспорт")
        }
        if (containsWord(category, "азс") || containsAny(category, ["топлив", "бензин", "дизел"])) {
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Топливо")
        }
        if containsAny(category, ["автосервис", "автомой", "парков", "запчаст", "шиномонтаж", "автомобил"]) {
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Авто")
        }
        if category.contains("маркетплейс") {
            return FinanceCategoryPath(group: "Покупки", subcategory: "Маркетплейсы")
        }
        if containsAny(category, ["одежд", "обув", "fashion", "модные аксессуары", "аксессуары для одежды"]) {
            return FinanceCategoryPath(group: "Покупки", subcategory: "Одежда")
        }
        if containsAny(category, ["электроник", "цифровая техника", "компьютер", "смартфон", "бытовая техника", "техника и электроника"]) {
            return FinanceCategoryPath(group: "Покупки", subcategory: "Электроника")
        }
        if containsAny(category, ["товары для дома", "дом и быт", "мебел", "стройматериал", "хозяйствен"]) {
            return FinanceCategoryPath(group: "Покупки", subcategory: "Дом и быт")
        }
        if containsAny(category, ["жкх", "коммунал", "квартплат", "электроэнерг", "водоснабж", "газоснабж"]) {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "ЖКХ")
        }
        if containsAny(category, ["подписк", "subscription", "стриминг"]) {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Подписки")
        }
        if containsAny(category, ["аптек", "медицин", "здоров", "клиник", "стоматолог", "врач"]) {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Здоровье")
        }
        let categoryLooksLikeInternetShop = containsAny(category, ["интернет-магазин", "интернет магазин"])
        if !categoryLooksLikeInternetShop && containsAny(category, ["связь", "телеком", "оператор связи", "интернет и тв", "домашний интернет", "мобильная связь"]) {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Связь и интернет")
        }
        if containsAny(category, ["развлеч", "кино", "театр", "концерт", "игры", "аттракцион"]) {
            return FinanceCategoryPath(group: "Другое", subcategory: "Развлечения")
        }
        if containsAny(category, ["путешеств", "туризм", "отел", "гостиниц", "авиабилет", "железнодорож"]) {
            return FinanceCategoryPath(group: "Другое", subcategory: "Путешествия")
        }
        if containsAny(category, ["подар", "цветы", "сувенир"]) {
            return FinanceCategoryPath(group: "Другое", subcategory: "Подарки")
        }

        // High-confidence MCC fallback for common bank categories that arrive too generic.
        switch mcc {
        case "5411", "5422", "5441", "5451", "5462", "5499":
            return FinanceCategoryPath(group: "Еда", subcategory: "Супермаркеты")
        case "5812", "5813", "5814":
            return FinanceCategoryPath(group: "Еда", subcategory: "Кафе и рестораны")
        case "4121":
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Такси")
        case "4111", "4112", "4131":
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Общественный транспорт")
        case "5541", "5542":
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Топливо")
        case "4812":
            return FinanceCategoryPath(group: "Покупки", subcategory: "Электроника")
        case "4814", "4816":
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Связь и интернет")
        case "4899":
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Подписки")
        case "4900":
            return FinanceCategoryPath(group: "Обязательные", subcategory: "ЖКХ")
        case "5912":
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Здоровье")
        case "5815", "5816", "7832":
            return FinanceCategoryPath(group: "Другое", subcategory: "Развлечения")
        case "4511", "4722", "7011":
            return FinanceCategoryPath(group: "Другое", subcategory: "Путешествия")
        default:
            break
        }

        // Merchant/purpose fallback. Keep generic web/mobile words narrow to avoid turning ordinary
        // online purchases into telecom expenses.
        if containsAny(freeText, ["яндекс еда", "yandex eats", "delivery club", "деливери", "доставка еды", "доставка продуктов", "food delivery"]) {
            return FinanceCategoryPath(group: "Еда", subcategory: "Доставка еды")
        }
        if containsAny(freeText, ["супермаркет", "гипермаркет", "магазин продуктов"]) {
            return FinanceCategoryPath(group: "Еда", subcategory: "Супермаркеты")
        }
        if containsAny(freeText, ["кафе", "ресторан", "фастфуд", "кофейн", "столов"]) {
            return FinanceCategoryPath(group: "Еда", subcategory: "Кафе и рестораны")
        }
        if freeText.contains("такси") {
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Такси")
        }
        let metroRetail = containsAny(freeText, ["cash&carry", "cash & carry", "кэш энд керри", "кеш энд керри"])
        if (!metroRetail && containsWord(freeText, "метро")) || containsAny(freeText, ["автобус", "трамвай", "троллейбус", "транспортная карта"]) {
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Общественный транспорт")
        }
        if (containsWord(freeText, "азс") || containsAny(freeText, ["заправк", "бензин", "дизел", "gas station"])) {
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Топливо")
        }
        if containsAny(freeText, ["автосервис", "автомой", "парков", "запчаст", "шиномонтаж"]) {
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Авто")
        }
        if containsAny(freeText, ["wildberries", "вайлдберриз", "ozon", "озон", "яндекс маркет", "marketplace"]) {
            return FinanceCategoryPath(group: "Покупки", subcategory: "Маркетплейсы")
        }
        if containsAny(freeText, ["магазин одежды", "магазин обуви", "fashion store"]) {
            return FinanceCategoryPath(group: "Покупки", subcategory: "Одежда")
        }
        if containsAny(freeText, ["магазин электроники", "компьютерный магазин", "смартфон", "электроника"]) {
            return FinanceCategoryPath(group: "Покупки", subcategory: "Электроника")
        }
        if containsAny(freeText, ["товары для дома", "мебель", "стройматериал", "хозяйственный магазин"]) {
            return FinanceCategoryPath(group: "Покупки", subcategory: "Дом и быт")
        }
        if containsAny(freeText, ["коммунальные услуги", "квартплата", "электроэнергия", "водоснабжение", "газоснабжение"]) {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "ЖКХ")
        }
        if containsAny(freeText, ["подписка", "subscription", "стриминг", "онлайн-сервис"]) {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Подписки")
        }
        if containsAny(freeText, ["аптека", "клиника", "стоматолог", "медицинский центр"]) {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Здоровье")
        }
        if containsAny(freeText, ["домашний интернет", "интернет-провайдер", "оплата интернета", "мобильная связь", "оператор связи", "телеком"]) {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Связь и интернет")
        }
        if containsAny(freeText, ["кинотеатр", "театр", "концерт", "аттракцион", "развлечения"]) {
            return FinanceCategoryPath(group: "Другое", subcategory: "Развлечения")
        }
        if containsAny(freeText, ["отель", "гостиница", "авиабилет", "ж/д билет", "железнодорожный билет"]) {
            return FinanceCategoryPath(group: "Другое", subcategory: "Путешествия")
        }
        if containsAny(freeText, ["магазин цветов", "цветочный", "подарок", "сувенир"]) {
            return FinanceCategoryPath(group: "Другое", subcategory: "Подарки")
        }

        // Keep broad/ambiguous bank descriptions safe rather than guessing.
        return FinanceCategoryPath(group: "Другое", subcategory: "Прочее")
    }

    private static func isSaveTransfer(_ operation: FinancialOperationInput) -> Bool {
        let combined = normalized([operation.description, operation.category, operation.purpose ?? ""].joined(separator: " "))
        return containsAny(combined, ["перевод между счетами одного клиента", "сейв", "накопитель"])
    }

    static func saveTransferDirection(for operation: FinancialOperationInput) -> String? {
        guard classify(operation).type == .internalTransfer, isSaveTransfer(operation) else { return nil }
        if operation.amountKopecks < 0 { return "Карта → Сейв" }
        if operation.amountKopecks > 0 { return "Сейв → Карта" }
        return nil
    }

    static func movementCategory(for operation: FinancialOperationInput) -> String {
        let combined = normalized([operation.description, operation.category, operation.purpose ?? ""].joined(separator: " "))
        if containsAny(combined, ["снятие налич", "выдача налич", "банкомат"]) { return "Снятие наличных" }
        if isSaveTransfer(operation) { return "Сейв" }
        return "Между своими счетами"
    }

    private static func lines(_ groups: [String: (Int, Int64, [String: (Int, Int64)])], order: [String], childOrder: [String] = []) -> [FinanceLine] {
        var childRank: [String: Int] = [:]
        for (index, title) in childOrder.enumerated() where childRank[title] == nil { childRank[title] = index }
        return order.compactMap { title in
            guard let group = groups[title], group.0 > 0 else { return nil }
            let children = group.2.map { FinanceLine(id: title + "/" + $0.key, title: $0.key, count: $0.value.0, amountKopecks: $0.value.1, note: nil, children: []) }
                .sorted { lhs, rhs in
                    let left = childRank[lhs.title] ?? Int.max
                    let right = childRank[rhs.title] ?? Int.max
                    if left != right { return left < right }
                    if lhs.amountKopecks != rhs.amountKopecks { return lhs.amountKopecks > rhs.amountKopecks }
                    return lhs.title < rhs.title
                }
            let note = title == "Сплит" ? "Пока не входит в итог расходов, чтобы не задвоить покупку." : (title == "Возвраты" ? "Уменьшает расходы, это не заработок." : nil)
            return FinanceLine(id: title, title: title, count: group.0, amountKopecks: group.1, note: note, children: children)
        }
    }

}
