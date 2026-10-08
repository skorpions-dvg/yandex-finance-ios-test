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
    /// Expense category "Group/Subcategory" chosen by the user (a rule, a change on the operation card or the
    /// category of a manual entry). It wins over every text guess; nil leaves the built-in guess.
    var categoryPath: String? = nil
    /// Income category chosen by the user (a sender rule or a change on the operation card). Only applies to
    /// income and interest; it never changes what an operation is.
    var incomeCategoryName: String? = nil
    /// Statement source marker; deposit rows never move the bank card.
    var paymentMethod: String? = nil
}

/// The user's expense categories in display order. The built-in tree is used until the user edits it.
struct ExpenseTaxonomy: Equatable {
    struct Group: Equatable {
        var name: String
        var subcategories: [String]
        /// Bills and other obligations: the forecast never treats them as one-off purchases.
        var isFixedCosts: Bool
    }
    var groups: [Group]

    var groupNames: [String] { groups.map(\.name) }
    var subcategoryOrder: [String] { groups.flatMap(\.subcategories) }
    var fixedCostGroups: Set<String> { Set(groups.filter(\.isFixedCosts).map(\.name)) }

    static let builtin = ExpenseTaxonomy(groups: [
        Group(name: "Еда", subcategories: ["Супермаркеты", "Кафе и рестораны", "Доставка еды"], isFixedCosts: false),
        Group(name: "Транспорт", subcategories: ["Такси", "Общественный транспорт", "Топливо", "Авто"], isFixedCosts: false),
        Group(name: "Покупки", subcategories: ["Маркетплейсы", "Одежда", "Электроника", "Дом и быт"], isFixedCosts: false),
        Group(name: "Обязательные", subcategories: ["ЖКХ", "Связь и интернет", "Подписки", "Здоровье"], isFixedCosts: true),
        Group(name: "Другое", subcategories: ["Развлечения", "Путешествия", "Подарки", "Доставка и курьеры",
                                              "Комиссии", "Прочее"], isFixedCosts: false),
        // Money sent to people is not «other spending»; on its own it no longer hides what was bought.
        Group(name: "Переводы", subcategories: ["Переводы другим"], isFixedCosts: false),
    ])
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
        // A move between the card and the Save account, as the bank's shared history lists it: one row per account,
        // both titled after the Save account. It is never a purchase, a refund or income.
        if amount != 0 && !split && kind != "interest_income" && (description == "счет в сейвах" ||
            (description.contains("→") && description.contains("сейв"))) {
            return FinancialAssessment(type: .internalTransfer, reason: "Перевод между картой и Сейвом — перемещение между своими счетами.", originalAmountKopecks: amount, expenseContributionKopecks: 0, incomeContributionKopecks: 0, refundContributionKopecks: 0)
        }
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

    static func report(_ operations: [FinancialOperationInput], in interval: DateInterval,
                       taxonomy: ExpenseTaxonomy = .builtin) -> FinanceReport {
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

        let otherAccountRows = saveSidePairRows(operations)
        for (index, operation) in operations.enumerated() {
            guard let date = BankDateParser.parse(operation.occurredAt) else {
                invalidDateCount += 1
                continue
            }
            guard date >= interval.start && date < interval.end else { continue }
            operationCount += 1
            let assessment = classify(operation)
            // The Save statement repeats the deposit side of transfers the card statement already has.
            let fromSaveStatement = isSaveSide(operation) || otherAccountRows.contains(index)
            if assessment.type != .cancelled && !fromSaveStatement {
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
                if fromSaveStatement { continue }
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

        let incomeOrder = incomeSubcategoryOrder
        // Groups outside the taxonomy (a category deleted after an entry was made) still show, after the known ones.
        let reserved = ["Сплит", "Возвраты"]
        let extraGroups = expenseGroups.keys.filter { !taxonomy.groupNames.contains($0) && !reserved.contains($0) }.sorted()
        let expenseOrder = taxonomy.groupNames + extraGroups + reserved
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
                             expenseLines: lines(expenseGroups, order: expenseOrder, childOrder: taxonomy.subcategoryOrder),
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

    static func compareReports(_ operations: [FinancialOperationInput], currentInterval: DateInterval, previousInterval: DateInterval,
                               taxonomy: ExpenseTaxonomy = .builtin) -> MonthlyComparison {
        let current = report(operations, in: currentInterval, taxonomy: taxonomy)
        let previous = report(operations, in: previousInterval, taxonomy: taxonomy)

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
        for group in taxonomy.groups {
            for subcategory in group.subcategories where !comparisonExcludedSubcategories.contains(subcategory) {
                let group = group.name
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

    // MARK: - Account balances

    /// Current balance of a user account: the balance entered at `since`, plus, for the scanned bank card, every
    /// bank movement after that moment. Cancelled operations do not move money; pending ones already reduce the
    /// available balance in the bank, so they count. Manual operations are added in a later version.
    static func accountBalance(startKopecks: Int64, since: Date, tracksBankCard: Bool, operations: [FinancialOperationInput]) -> Int64 {
        guard tracksBankCard else { return startKopecks }
        let otherAccountRows = saveSidePairRows(operations)
        return operations.enumerated().reduce(startKopecks) { balance, item in
            let operation = item.element
            guard !isSaveSide(operation), !otherAccountRows.contains(item.offset),
                  let date = BankDateParser.parse(operation.occurredAt), date >= since,
                  classify(operation).type != .cancelled else { return balance }
            return balance + operation.amountKopecks
        }
    }

    // MARK: - Month reserve

    enum ReserveStatus: Equatable {
        /// The reserve is at least the buffer.
        case fine
        /// Positive but below the buffer.
        case tight
        /// The current balance will not last until the end of the month at this pace.
        case short
    }

    /// What stays from the balance at the end of the month if spending continues as forecast: the balance minus the
    /// spending still expected this month (recurring payments and the variable tail) plus the regular income still
    /// expected (a salary that has its usual day ahead). Irregular income is never guessed here; see
    /// `monthReserveWithTypicalIncome`.
    static func monthReserve(balanceKopecks: Int64, forecast: MonthForecast) -> Int64 {
        balanceKopecks - max(0, forecast.projectedExpenseKopecks - forecast.spentKopecks) + forecast.expectedIncomeLeftKopecks
    }

    /// The reserve at the usual low and high spending of the months the forecast is built from.
    static func monthReserveRange(balanceKopecks: Int64, forecast: MonthForecast) -> (low: Int64, high: Int64) {
        let left = forecast.expectedIncomeLeftKopecks
        let atHighSpending = balanceKopecks - max(0, forecast.projectedExpenseHighKopecks - forecast.spentKopecks) + left
        let atLowSpending = balanceKopecks - max(0, forecast.projectedExpenseLowKopecks - forecast.spentKopecks) + left
        return (min(atHighSpending, atLowSpending), max(atHighSpending, atLowSpending))
    }

    /// The same reserve if the usual irregular income (transfers from people and the like) still comes this month.
    static func monthReserveWithTypicalIncome(balanceKopecks: Int64, forecast: MonthForecast) -> Int64 {
        monthReserve(balanceKopecks: balanceKopecks, forecast: forecast)
            + max(0, forecast.typicalIrregularIncomeKopecks - forecast.irregularIncomeSoFarKopecks)
    }

    static func reserveStatus(_ reserveKopecks: Int64, bufferKopecks: Int64) -> ReserveStatus {
        if reserveKopecks < 0 { return .short }
        return reserveKopecks >= bufferKopecks ? .fine : .tight
    }

    // MARK: - Search

    /// Search over saved operations: every word of the query has to match. A word matches when it occurs in the title,
    /// bank category, purpose, MCC, status, the app's category path or the financial type, or, for a number, when it is
    /// the amount in rubles ("1555", "1 555", "2031,65", with or without the sign).
    static func operationMatches(_ operation: FinancialOperationInput, query: String) -> Bool {
        let assessment = classify(operation)
        var fields = [operation.description, operation.category, operation.purpose ?? "", operation.mcc ?? "",
                      operation.status, assessment.type.title]
        switch assessment.type {
        case .expense, .commission:
            let path = expenseCategory(for: operation, assessment: assessment)
            fields += [path.group, path.subcategory]
        case .income, .interestIncome:
            fields.append(incomeCategory(for: operation, assessment: assessment))
        case .internalTransfer:
            fields.append(movementCategory(for: operation))
        default:
            break
        }
        let haystack = normalized(fields.joined(separator: " "))
        // "1 555" is one amount: join digit groups separated by spaces before splitting into words.
        let words = normalized(query)
            .replacingOccurrences(of: #"(?<=\d) (?=\d{3}\b)"#, with: "", options: .regularExpression)
            .split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        let amount = abs(operation.amountKopecks)
        return words.allSatisfy { word in
            if haystack.contains(word) { return true }
            let number = word.trimmingCharacters(in: CharacterSet(charactersIn: "+-−₽р."))
                .replacingOccurrences(of: ",", with: ".")
            guard let value = Decimal(string: number), number.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
            let kopecks = NSDecimalNumber(decimal: value * 100).int64Value
            return number.contains(".") ? kopecks == amount : kopecks == amount - amount % 100 && kopecks > 0
        }
    }

    // MARK: - Month forecast

    /// A payment or income that repeats with a steady period and amount.
    struct RecurringPattern: Equatable {
        let title: String
        let isIncome: Bool
        /// 7, 14, 30 (calendar month) or 365 (calendar year).
        let intervalDays: Int
        let typicalAmountKopecks: Int64
        let lastDate: Date
    }

    /// A recurring payment or income still expected this month.
    struct UpcomingPayment: Equatable, Identifiable {
        let title: String
        let amountKopecks: Int64
        let date: Date
        let isIncome: Bool
        /// Its usual day has already passed this month and it has not shown up yet.
        let overdue: Bool
        var id: String { "\(isIncome)|\(title)|\(date.timeIntervalSince1970)" }
    }

    /// One full month of the history behind the forecast, split the way the baseline sees it.
    struct BaselineMonth: Equatable, Identifiable {
        let month: Date
        /// Net expense of the month after refunds.
        let netExpenseKopecks: Int64
        let recurringKopecks: Int64
        let oneOffKopecks: Int64
        /// What goes into the median: net expense without recurring payments and one-off purchases.
        let variableKopecks: Int64
        /// What the one-off purchases of the month were, by category group («Переводы 66 000 ₽»), never by operation.
        let largestOneOffs: [String]
        var id: Date { month }
    }

    struct MonthForecast: Equatable {
        /// Net expense (after refunds) from the first day of the month through today.
        let spentKopecks: Int64
        /// Income from the first day of the month through today.
        let incomeKopecks: Int64
        let projectedExpenseKopecks: Int64
        let projectedExpenseLowKopecks: Int64
        let projectedExpenseHighKopecks: Int64
        /// Income already received plus recurring income (salary) still expected. Irregular income is not guessed.
        let projectedIncomeKopecks: Int64
        let previousMonthIncomeKopecks: Int64
        /// Usual non-recurring income per month (median), shown separately and not counted in the balance.
        let typicalIrregularIncomeKopecks: Int64
        /// Non-recurring income already received this month.
        let irregularIncomeSoFarKopecks: Int64
        /// One-off purchases this month: counted as spent, left out of the baseline and the pace.
        let oneOffKopecks: Int64
        let upcoming: [UpcomingPayment]
        /// Full months the variable spending baseline is built from (0 means the current pace alone).
        let historyMonths: Int
        /// Those months, newest first, for the "how it is calculated" view.
        let baselineMonths: [BaselineMonth]
        let elapsedDays: Int
        let daysInMonth: Int

        /// Expected income minus projected spending; negative means the money is not expected to last.
        var projectedBalanceKopecks: Int64 { projectedIncomeKopecks - projectedExpenseKopecks }
        /// Regular income still expected this month; one whose usual day has passed without it arriving is not counted.
        var expectedIncomeLeftKopecks: Int64 {
            upcoming.filter { $0.isIncome && !$0.overdue }.reduce(0) { $0 + $1.amountKopecks }
        }
        /// The same balance if the usual irregular income still comes this month (the second, optimistic scenario).
        var balanceWithTypicalIncomeKopecks: Int64 {
            projectedBalanceKopecks + max(0, typicalIrregularIncomeKopecks - irregularIncomeSoFarKopecks)
        }
    }

    private struct DatedAmount {
        let date: Date
        let key: String
        let title: String
        let isIncome: Bool
        let amount: Int64
        /// "Group/Subcategory" for expenses, empty for income.
        var category = ""
    }

    /// Counterparty key from the bank text: letters only, so amounts, dates and account numbers that change from
    /// month to month (for example a utility bill "ЭЭ 3732.24, ГВС …, ПРД08.2026") do not split one payee into many.
    /// Payee key for rules «for every operation of this payee»; empty when the title names nobody: a statement row
    /// damaged into a date and amounts, or a title with fewer than three letters. Such a key would join unrelated
    /// operations under one rule.
    static func payeeRuleKey(_ title: String) -> String {
        if title.range(of: #"^\s*\d{2}\.\d{2}\.\d{4}"#, options: .regularExpression) != nil { return "" }
        let key = counterpartyKey(title)
        return key.filter(\.isLetter).count >= 3 ? key : ""
    }

    static func counterpartyKey(_ text: String) -> String {
        String(normalized(text).map { $0.isLetter ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }

    /// Completed income and expense movements with their counterparty; refunds, transfers, split and pending are left out.
    private static func datedAmounts(_ operations: [FinancialOperationInput]) -> [DatedAmount] {
        operations.compactMap { operation in
            guard let date = BankDateParser.parse(operation.occurredAt) else { return nil }
            let assessment = classify(operation)
            let key = counterpartyKey(operation.description)
            if assessment.incomeContributionKopecks > 0 {
                return DatedAmount(date: date, key: key, title: operation.description, isIncome: true, amount: assessment.incomeContributionKopecks)
            }
            if assessment.expenseContributionKopecks > 0 {
                let path = expenseCategory(for: operation, assessment: assessment)
                return DatedAmount(date: date, key: key, title: operation.description, isIncome: false,
                                   amount: assessment.expenseContributionKopecks, category: path.group + "/" + path.subcategory)
            }
            return nil
        }
    }

    private static let recurringPeriods: [(days: Int, tolerance: Int)] = [(7, 1), (14, 2), (30, 4), (365, 15)]

    /// The date `n` periods after `date`: months and years are counted from the same start, so a payment of the 31st is
    /// on the 28th or 29th only in February and on the 31st again in March.
    private static func step(_ date: Date, by intervalDays: Int, times n: Int = 1, calendar: Calendar) -> Date {
        switch intervalDays {
        case 30: return calendar.date(byAdding: .month, value: n, to: date)!
        case 365: return calendar.date(byAdding: .year, value: n, to: date)!
        default: return calendar.date(byAdding: .day, value: intervalDays * n, to: date)!
        }
    }

    private static func median(_ values: [Int64]) -> Int64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func quantile(_ values: [Int64], _ q: Double) -> Int64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * q
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + Int64((Double(sorted[upper] - sorted[lower]) * (position - Double(lower))).rounded())
    }

    /// Payments and income from the same counterparty at least three times, about every 7, 14, 30 or 365 days,
    /// with amounts within 15% of their median (two thirds of the time), and seen recently enough to still be active.
    static func recurringPatterns(_ operations: [FinancialOperationInput], now: Date = Date(), calendar: Calendar = .current) -> [RecurringPattern] {
        let horizon = calendar.date(byAdding: .day, value: -400, to: now)!
        // A title that cannot be a payee key (only digits, a date) never makes a "recurring payment" of its own.
        let items = datedAmounts(operations).filter { $0.date >= horizon && $0.date <= now && !payeeRuleKey($0.title).isEmpty }
        let groups = Dictionary(grouping: items) { "\($0.isIncome)|\($0.key)" }
        func days(_ from: Date, _ to: Date) -> Int {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
        }
        var patterns: [RecurringPattern] = []
        for (_, group) in groups where group.count >= 3 {
            let sorted = group.sorted { $0.date < $1.date }
            let intervals = zip(sorted, sorted.dropFirst()).map { days($0.date, $1.date) }
            guard let period = recurringPeriods.first(where: { period in
                intervals.filter { abs($0 - period.days) <= period.tolerance }.count * 3 >= intervals.count * 2
            }) else { continue }
            let amounts = sorted.map(\.amount)
            let typical = median(amounts)
            guard amounts.filter({ abs($0 - typical) * 100 <= typical * 15 }).count * 3 >= amounts.count * 2 else { continue }
            let last = sorted[sorted.count - 1]
            guard days(last.date, now) <= period.days * 3 / 2 + period.tolerance else { continue }
            patterns.append(RecurringPattern(title: last.title, isIncome: last.isIncome, intervalDays: period.days,
                                             typicalAmountKopecks: typical, lastDate: last.date))
        }
        return patterns.sorted { ($0.isIncome ? 1 : 0, $0.title) < ($1.isIncome ? 1 : 0, $1.title) }
    }

    /// Month forecast = what already happened + recurring payments still expected + variable spending for the rest
    /// of the month. The variable baseline is the median of up to six full months without recurring items and
    /// one-off purchases; the daily rate of the rest of the month is that usual rate blended with this month's own, the
    /// month weighing more with every day (30 days of history count as much as the days gone). The low and high values
    /// use the quartiles of the same months; recurring items stay exact. Without usable history the pace of this month
    /// is taken over at least seven days.
    /// A purchase is one-off when its payee does not show up in another month, it is not an obligation (group
    /// "Обязательные" or another group marked as fixed costs), it is above 3% of the usual monthly variable spending, and it is more than twice the median
    /// purchase of its category, or, for a category with fewer than three purchases in the history, more than 5% of
    /// the usual monthly variable spending. Months with fewer than three expenses are not used.
    /// Built on `report`, so the usual rules apply.
    static func monthForecast(_ operations: [FinancialOperationInput], now: Date = Date(), calendar: Calendar = .current,
                              taxonomy: ExpenseTaxonomy = .builtin) -> MonthForecast {
        // The engine is also compiled on its own (statement import tests), so month bounds are computed here.
        let monthStartDate = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStartDate)!
        let elapsed = max(1, calendar.dateComponents([.day], from: monthStartDate, to: endOfToday).day ?? 1)
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStartDate)?.count ?? 30
        let remaining = max(0, daysInMonth - elapsed)

        let patterns = recurringPatterns(operations, now: now, calendar: calendar)
        // Operations dated after today (a pending one, a scheduled one) do not take part in today's forecast.
        let allItems = datedAmounts(operations).filter { $0.date < endOfToday }
        let recurringKeys = Set(patterns.map { "\($0.isIncome)|\(counterpartyKey($0.title))" })
        let recurringItems = allItems.filter { recurringKeys.contains("\($0.isIncome)|\($0.key)") }
        func sum(_ items: [DatedAmount], income: Bool, in interval: DateInterval) -> Int64 {
            items.filter { $0.isIncome == income && $0.date >= interval.start && $0.date < interval.end }.reduce(0) { $0 + $1.amount }
        }

        // Full months only: a month before the saved history or the partly covered month it starts in
        // (for example a statement that begins mid-month) would drag the baseline down.
        let firstSaved = operations.compactMap { BankDateParser.parse($0.occurredAt) }.min()
        var months: [(interval: DateInterval, report: FinanceReport)] = []
        var previousMonthIncome: Int64 = 0
        for back in 1...6 {
            let start = calendar.date(byAdding: .month, value: -back, to: monthStartDate)!
            let month = DateInterval(start: start, end: calendar.date(byAdding: .month, value: 1, to: start)!)
            let monthReport = report(operations, in: month)
            if back == 1 { previousMonthIncome = monthReport.incomeKopecks }
            // A month with almost no spending saved (an incompletely covered archive month) is not representative.
            let expenseCount = allItems.filter { !$0.isIncome && $0.date >= month.start && $0.date < month.end }.count
            if expenseCount >= 3, let firstSaved, firstSaved < calendar.date(byAdding: .day, value: 7, to: start)! {
                months.append((month, monthReport))
            }
        }
        let historyStart = months.map(\.interval.start).min() ?? monthStartDate

        // One-off purchases: compared with the usual purchase of their category in the history.
        let variableItems = allItems.filter { !$0.isIncome && !recurringKeys.contains("\($0.isIncome)|\($0.key)") }
        let historyByCategory = Dictionary(grouping: variableItems.filter { $0.date >= historyStart && $0.date < monthStartDate }, by: \.category)
            .mapValues { $0.map(\.amount) }
        let roughBaseline = median(months.map { $0.report.netExpenseKopecks - sum(recurringItems, income: false, in: $0.interval) })
        // A payee seen in two or more different months is a habit (a person you send money to, a utility bill),
        // not a one-off, even when single amounts are large.
        let monthsByPayee = Dictionary(grouping: variableItems, by: \.key)
            .mapValues { Set($0.map { calendar.dateComponents([.year, .month], from: $0.date) }).count }
        func isOneOff(_ item: DatedAmount) -> Bool {
            if (monthsByPayee[item.key] ?? 0) >= 2 { return false }
            // Bills, phone, subscriptions and health are obligations, not one-off purchases.
            if let group = item.category.split(separator: "/", maxSplits: 1).first,
               taxonomy.fixedCostGroups.contains(String(group)) { return false }
            // Too small to matter for the month: at most 3% of the usual monthly variable spending.
            if roughBaseline > 0 && item.amount * 100 <= roughBaseline * 3 { return false }
            if let history = historyByCategory[item.category], history.count >= 3 { return item.amount > 2 * median(history) }
            return roughBaseline > 0 && item.amount * 20 > roughBaseline
        }
        let oneOffItems = variableItems.filter(isOneOff)

        func variableExpense(in interval: DateInterval, report monthReport: FinanceReport) -> Int64 {
            monthReport.netExpenseKopecks - sum(recurringItems, income: false, in: interval) - sum(oneOffItems, income: false, in: interval)
        }
        let variableExpenses = months.map { variableExpense(in: $0.interval, report: $0.report) }
        let baselineMonths = months.map { month -> BaselineMonth in
            let oneOffs = oneOffItems.filter { $0.date >= month.interval.start && $0.date < month.interval.end }
            return BaselineMonth(month: month.interval.start,
                                 netExpenseKopecks: month.report.netExpenseKopecks,
                                 recurringKopecks: sum(recurringItems, income: false, in: month.interval),
                                 oneOffKopecks: oneOffs.reduce(0) { $0 + $1.amount },
                                 variableKopecks: variableExpense(in: month.interval, report: month.report),
                                 largestOneOffs: Dictionary(grouping: oneOffs) { item in
                                        String(item.category.split(separator: "/", maxSplits: 1).first ?? "Прочее")
                                    }.map { group, items in (group, items.reduce(0) { $0 + $1.amount }) }
                                    .sorted { $0.1 > $1.1 }
                                    .map { "\($0.0) \((Decimal($0.1) / 100).formatted(.currency(code: "RUB")))" })
        }
        let variableIncomes = months.map { $0.report.incomeKopecks - sum(recurringItems, income: true, in: $0.interval) }

        let soFarInterval = DateInterval(start: monthStartDate, end: endOfToday)
        let soFar = report(operations, in: soFarInterval)
        let variableSoFar = variableExpense(in: soFarInterval, report: soFar)
        let baseline = median(variableExpenses)

        // The daily rate of the rest of the month is the usual one blended with this month's own, and this month's
        // weight grows with the days elapsed (`priorDays` days of history count as much as the month so far). One
        // purchase in the first days therefore barely moves the forecast, and a month that really runs differently
        // is followed gradually, never in jumps.
        let priorDays = 30.0
        func tail(_ base: Int64) -> Int64 {
            if base <= 0 {
                // No usable history: fall back to the plain daily pace of this month.
                // At least a week of pace: one purchase on the first day must not be multiplied by the days left.
                return max(0, variableSoFar) * Int64(remaining) / Int64(max(elapsed, 7))
            }
            let usual = Double(base) / Double(daysInMonth)
            let current = Double(max(0, variableSoFar)) / Double(elapsed)
            let rate = (usual * priorDays + current * Double(elapsed)) / (priorDays + Double(elapsed))
            return Int64((rate * Double(remaining)).rounded())
        }

        var upcoming: [UpcomingPayment] = []
        for pattern in patterns {
            var count = 1
            var next = step(pattern.lastDate, by: pattern.intervalDays, times: count, calendar: calendar)
            while next < monthEnd {
                if next >= monthStartDate {
                    upcoming.append(UpcomingPayment(title: pattern.title, amountKopecks: pattern.typicalAmountKopecks, date: next,
                                                    isIncome: pattern.isIncome, overdue: next < startOfToday))
                }
                count += 1
                next = step(pattern.lastDate, by: pattern.intervalDays, times: count, calendar: calendar)
            }
        }
        upcoming.sort { $0.date < $1.date }
        let upcomingExpense = upcoming.filter { !$0.isIncome }.reduce(0) { $0 + $1.amountKopecks }
        // An income whose usual day has passed without it arriving is counted nowhere (the reserve already ignores it).
        let upcomingIncome = upcoming.filter { $0.isIncome && !$0.overdue }.reduce(0) { $0 + $1.amountKopecks }

        let known = soFar.netExpenseKopecks + upcomingExpense
        let estimates = [tail(quantile(variableExpenses, 0.25)), tail(baseline), tail(quantile(variableExpenses, 0.75))].map { known + $0 }

        return MonthForecast(spentKopecks: soFar.netExpenseKopecks,
                             incomeKopecks: soFar.incomeKopecks,
                             projectedExpenseKopecks: estimates[1],
                             projectedExpenseLowKopecks: estimates.min()!,
                             projectedExpenseHighKopecks: estimates.max()!,
                             projectedIncomeKopecks: soFar.incomeKopecks + upcomingIncome,
                             previousMonthIncomeKopecks: previousMonthIncome,
                             typicalIrregularIncomeKopecks: median(variableIncomes),
                             irregularIncomeSoFarKopecks: soFar.incomeKopecks - sum(recurringItems, income: true, in: soFarInterval),
                             oneOffKopecks: sum(oneOffItems, income: false, in: soFarInterval),
                             upcoming: upcoming,
                             historyMonths: variableExpenses.count,
                             baselineMonths: baselineMonths,
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
            .filter { $0.title != "Сплит" && $0.title != "Возвраты" && $0.amountKopecks > 0 }
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
            if assessment.type == .internalTransfer && isSaveTransfer(operation) && !isSaveSide(operation) {
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

    /// Operations entered by hand carry their chosen category in `purpose` as "manual-category:Group/Subcategory"
    /// (or "manual-category:Subcategory" for income); it wins over any text guess.
    static let manualCategoryPrefix = "manual-category:"

    private static func manualCategory(_ operation: FinancialOperationInput) -> [String]? {
        guard let purpose = operation.purpose, purpose.hasPrefix(manualCategoryPrefix) else { return nil }
        return purpose.dropFirst(manualCategoryPrefix.count).split(separator: "/", maxSplits: 1).map(String.init)
    }

    static let incomeSubcategoryOrder = ["Переводы от других", "Пополнения", "Зарплата и выплаты", "Кэшбэк", "Проценты", "Прочие доходы"]

    static func incomeCategory(for operation: FinancialOperationInput, assessment: FinancialAssessment? = nil) -> String {
        if let chosen = operation.incomeCategoryName, incomeSubcategoryOrder.contains(chosen) {
            let type = (assessment ?? classify(operation)).type
            if type == .income || type == .interestIncome { return chosen }
        }
        if let manual = manualCategory(operation), manual.count == 1, incomeSubcategoryOrder.contains(manual[0]) { return manual[0] }
        let assessment = assessment ?? classify(operation)
        let combined = normalized([operation.description, operation.category, operation.purpose ?? ""].joined(separator: " "))
        if containsAny(combined, ["кэшбэк", "кешбэк", "cashback"]) { return "Кэшбэк" }
        if assessment.type == .interestIncome { return "Проценты" }
        if containsAny(combined, ["зарплат", "заработная плата"]) { return "Зарплата и выплаты" }
        if containsAny(combined, ["банкомат", "внесение налич", "пополн"]) { return "Пополнения" }
        if normalized(operation.kind) == "transfer" || combined.contains("перевод") { return "Переводы от других" }
        return "Прочие доходы"
    }

    /// Built-in expense tree, flattened; the user's tree is `ExpenseTaxonomy` built from `SavedHistory`.
    static let expenseGroupOrder = ExpenseTaxonomy.builtin.groupNames
    static let expenseSubcategoryOrder = ExpenseTaxonomy.builtin.subcategoryOrder

    /// Four-digit category code inside an aggregator title: «YANDEX*5411*DK» → "5411".
    static func embeddedMCC(_ title: String) -> String {
        let parts = title.split(separator: "*")
        guard parts.count >= 3 else { return "" }
        return parts.dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isNumber) }.map(String.init) ?? ""
    }

    static func expenseCategory(for operation: FinancialOperationInput, assessment: FinancialAssessment? = nil) -> FinanceCategoryPath {
        if let chosen = operation.categoryPath.map({ $0.split(separator: "/", maxSplits: 1).map(String.init) }),
           chosen.count == 2, !chosen[0].isEmpty, !chosen[1].isEmpty {
            return FinanceCategoryPath(group: chosen[0], subcategory: chosen[1])
        }
        if let manual = manualCategory(operation), manual.count == 2, !manual[0].isEmpty, !manual[1].isEmpty {
            return FinanceCategoryPath(group: manual[0], subcategory: manual[1])
        }
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
            return FinanceCategoryPath(group: "Переводы", subcategory: "Переводы другим")
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

        // High-confidence MCC fallback for common bank categories that arrive too generic. Statements carry no MCC,
        // but aggregator titles do: «YANDEX*5411*DK» is a grocery purchase.
        // A code of four digits is used; anything else (a cut «54») falls back to the code inside the title.
        switch mcc.count == 4 ? mcc : embeddedMCC(operation.description) {
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
        case "4812", "5732", "5734":
            return FinanceCategoryPath(group: "Покупки", subcategory: "Электроника")
        case "4814", "4816":
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Связь и интернет")
        case "4899":
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Подписки")
        case "4900":
            return FinanceCategoryPath(group: "Обязательные", subcategory: "ЖКХ")
        case "5912", "8011", "8021", "8031", "8041", "8042", "8043", "8049", "8050", "8062", "8071", "8099":
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Здоровье")
        case "5815", "5816", "7832":
            return FinanceCategoryPath(group: "Другое", subcategory: "Развлечения")
        case "4511", "4722", "7011":
            return FinanceCategoryPath(group: "Другое", subcategory: "Путешествия")
        case "5399":
            return FinanceCategoryPath(group: "Покупки", subcategory: "Маркетплейсы")
        case "4215":
            return FinanceCategoryPath(group: "Другое", subcategory: "Доставка и курьеры")
        case "5651", "5661", "5691", "5699":
            return FinanceCategoryPath(group: "Покупки", subcategory: "Одежда")
        case "5200", "5211", "5251", "5712", "5719":
            return FinanceCategoryPath(group: "Покупки", subcategory: "Дом и быт")
        default:
            break
        }

        // Shop names as banks and statements print them, Latin transliterations included.
        if containsAny(freeText, ["magnit", "магнит", "perekrestok", "перекресток", "pyaterochka", "пятерочк", "auchan", "ашан",
                                  "vkusvill", "вкусвилл", "lenta ", "гипермаркет лента", "maria-ra", "мария-ра", "metro c&c"]) {
            return FinanceCategoryPath(group: "Еда", subcategory: "Супермаркеты")
        }
        if containsAny(freeText, ["kfc", "burger king", "вкусно и точка", "vkusno i tochka", "coffee", "шаурм", "shaurm"]) {
            return FinanceCategoryPath(group: "Еда", subcategory: "Кафе и рестораны")
        }
        if containsAny(freeText, ["lemana", "лемана", "leroy", "леруа", "fix price", "фикс прайс", "ikea", "икеа"]) {
            return FinanceCategoryPath(group: "Покупки", subcategory: "Дом и быт")
        }
        if containsAny(freeText, ["apteka", "аптек"]) {
            return FinanceCategoryPath(group: "Обязательные", subcategory: "Здоровье")
        }
        if containsAny(freeText, ["dzhinsy", "джинсы", "gloria jeans", "ostin", "befree", "sportmaster", "спортмастер"]) {
            return FinanceCategoryPath(group: "Покупки", subcategory: "Одежда")
        }
        // A city transport card: «ETK» with the region number, as transport operators print it.
        if freeText.range(of: "etk[0-9]{2}", options: .regularExpression) != nil {
            return FinanceCategoryPath(group: "Транспорт", subcategory: "Общественный транспорт")
        }
        if containsAny(freeText, ["tutu", "туту.ру", "aviasales", "авиасейлс", "rzd", "ржд"]) {
            return FinanceCategoryPath(group: "Другое", subcategory: "Путешествия")
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

    /// The Save account's own row of a movement (the Save statement, or the Save part of a card ↔ Save transfer in the
    /// bank's shared history). The card statement or the card row already has the other side, so it never moves the
    /// card balance and is not counted twice.
    static func isSaveSide(_ operation: FinancialOperationInput) -> Bool {
        normalized(operation.paymentMethod).contains("сейв")
    }

    private enum TransferDestination { case save, card }

    /// The bank's shared history titles a card ↔ Save row after the destination: «Счёт в Сейвах» for card → Save,
    /// «Карта Пэй» for Save → card (or «A → B»).
    private static func transferDestination(_ operation: FinancialOperationInput) -> TransferDestination? {
        let title = normalized(operation.description)
        let target = title.contains("→") ? String(title.split(separator: "→").last ?? "") : title
        if title == "счет в сейвах" || (title.contains("→") && target.contains("сейв")) { return .save }
        if title == "карта пэй" || (title.contains("→") && target.contains("карт") && target.contains("пэй")) { return .card }
        return nil
    }

    /// Indices of the rows that belong to the other account of a card ↔ Save transfer listed as two rows: equal amounts
    /// with opposite signs within two minutes. For card → Save the card keeps the debit and the credit row is the Save's;
    /// for Save → card the card keeps the credit. Rows the scanner already tagged with their account are left to
    /// `isSaveSide`, and a row without its pair is never dropped.
    static func saveSidePairRows(_ operations: [FinancialOperationInput]) -> Set<Int> {
        let candidates = operations.indices.compactMap { index -> (Int, TransferDestination, Date)? in
            let operation = operations[index]
            guard !isSaveSide(operation), operation.amountKopecks != 0, classify(operation).type == .internalTransfer,
                  let destination = transferDestination(operation),
                  let date = BankDateParser.parse(operation.occurredAt) else { return nil }
            return (index, destination, date)
        }
        var result = Set<Int>()
        for (index, destination, date) in candidates {
            let amount = operations[index].amountKopecks
            // The row of the account that is not the card: the Save receives on card → Save, sends on Save → card.
            guard destination == .save ? amount > 0 : amount < 0 else { continue }
            let paired = candidates.contains { other in
                other.0 != index && operations[other.0].amountKopecks == -amount && abs(other.2.timeIntervalSince(date)) <= 120
            }
            if paired { result.insert(index) }
        }
        return result
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
