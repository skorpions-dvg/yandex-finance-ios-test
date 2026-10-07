import Foundation

struct ReviewGroup: Identifiable {
    enum Kind: String { case expense, income }
    let id: String
    let key: String
    let kind: Kind
    var operations: [BankOperation]
    var amountKopecks: Decimal {
        operations.reduce(Decimal.zero) { $0 + Decimal($1.amountKopecks.magnitude) }
    }
    var latestDate: Date? { operations.compactMap { BankDateParser.parse($0.occurredAt) }.max() }
    var title: String { key.isEmpty ? "Без названия" : operations[0].description }
    var appliesToAll: Bool { !key.isEmpty && !operations[0].isManual }
}

/// Presentation grouping only. Category selection and financial classification stay in existing APIs.
enum UncategorizedReview {
    static let otherExpenseID: UUID = {
        ExpenseCategoryGroup.builtin.first { $0.name == "Другое" }!
            .categories.first { $0.name == "Прочее" }!.id
    }()

    static func groups(_ history: SavedHistory) -> [ReviewGroup] {
        let operations = history.allOperations
        let inputs = history.financialInputs
        let resolver = ExpenseCategoryResolver(history)
        let rules = Set((history.categoryRules ?? []).map(\.payeeKey))
        var grouped: [String: ReviewGroup] = [:]
        for (operation, input) in zip(operations, inputs) {
            let key = FinancialEngine.counterpartyKey(operation.description)
            let type = FinancialEngine.classify(input).type
            let kind: ReviewGroup.Kind
            if (type == .expense || type == .commission),
               resolver.resolve(operation)?.id == otherExpenseID,
               key.isEmpty || !rules.contains(key) {
                kind = .expense
            } else if (type == .income || type == .interestIncome),
                      FinancialEngine.incomeCategory(for: input) == "Прочие доходы" {
                kind = .income
            } else { continue }
            // Manual entries cannot create a payee rule through the existing setters.
            let id = kind.rawValue + ":" + (key.isEmpty || operation.isManual ? operation.identity : key)
            if grouped[id] != nil { grouped[id]?.operations.append(operation) }
            else { grouped[id] = ReviewGroup(id: id, key: key, kind: kind, operations: [operation]) }
        }
        return grouped.values.sorted {
            if $0.amountKopecks != $1.amountKopecks { return $0.amountKopecks > $1.amountKopecks }
            return $0.id < $1.id
        }
    }
}
