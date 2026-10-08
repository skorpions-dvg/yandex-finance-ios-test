import Foundation

struct CategorySuggestion: Equatable, Identifiable {
    enum Reason: Equatable { case history, words, similarPayees }
    let categoryID: UUID
    let group: String
    let subcategory: String
    let reason: Reason
    let count: Int
    var id: UUID { categoryID }
}

struct RuleCandidate: Equatable, Identifiable {
    let payeeKey: String
    let title: String
    let categoryID: UUID
    let operationCount: Int
    var id: String { payeeKey }
}

/// A short-lived undo record, never a backup of the financial history.
struct ExpenseReviewUndo {
    struct ManualCategory {
        let operationID: UUID
        let categoryID: UUID
    }

    let id = UUID()
    let rules: [CategoryRule]?
    let overrides: [String: UUID]?
    let manualCategory: ManualCategory?

    init(_ history: SavedHistory, operation: BankOperation? = nil) {
        rules = history.categoryRules
        overrides = history.categoryOverrides
        if let id = operation?.manualID,
           let current = history.manualOperations?.first(where: { $0.id == id }),
           let categoryID = history.expenseCategoryID(for: current.bankOperation) {
            manualCategory = ManualCategory(operationID: id, categoryID: categoryID)
        } else { manualCategory = nil }
    }

    func changed(in history: SavedHistory) -> Bool {
        if let previous = manualCategory {
            guard let current = history.manualOperations?.first(where: { $0.id == previous.operationID }) else { return false }
            return history.expenseCategoryID(for: current.bankOperation) != previous.categoryID
        }
        return rules != history.categoryRules || overrides != history.categoryOverrides
    }

    @discardableResult
    func restore(in history: inout SavedHistory) -> Bool {
        if let previous = manualCategory {
            // Use the current record, so amount, date, accounts and comment edited since the choice survive undo.
            guard let current = history.manualOperations?.first(where: { $0.id == previous.operationID }),
                  current.kind == .expense,
                  history.setExpenseCategory(previous.categoryID, for: current.bankOperation, forPayee: false) else { return false }
        }
        history.categoryRules = rules
        history.categoryOverrides = overrides
        return true
    }
}

enum ExpenseReviewEdits {
    /// Use the existing setter for each unresolved row, including rows with individual Misc overrides.
    static func apply(_ categoryID: UUID, to group: ReviewGroup, history: inout SavedHistory) -> Bool {
        guard group.kind == .expense, !group.operations.isEmpty else { return false }
        var next = history
        for operation in group.operations {
            guard next.setExpenseCategory(categoryID, for: operation, forPayee: group.appliesToAll) else { return false }
        }
        history = next
        return true
    }
}

/// Suggestions only: nothing is persisted until the user chooses an existing category.
enum CategorySuggestions {
    private struct Evidence {
        let operation: BankOperation
        let key: String
        let categoryID: UUID
        let word: String?
    }

    /// The sorted operations of the history, by payee and by the significant word of the title.
    private struct Evidences {
        let byKey: [String: [Evidence]]
        let byWord: [String: [Evidence]]
        static let empty = Evidences(byKey: [:], byWord: [:])
    }

    /// Resolving the category of every operation is what costs: it is done once for all the groups, not once per group.
    private static func evidences(_ history: SavedHistory) -> Evidences {
        let resolver = ExpenseCategoryResolver(history)
        // resolve also excludes income, refunds, own transfers and unfinished operations.
        let all: [Evidence] = history.allOperations.compactMap { item in
            guard let id = resolver.resolve(item)?.id,
                  id != UncategorizedReview.otherExpenseID,
                  let category = history.expenseCategory(id: id),
                  !(category.group.name == "Другое" && category.category.name == "Прочее") else { return nil }
            return Evidence(operation: item, key: FinancialEngine.payeeRuleKey(item.description), categoryID: id,
                            word: significantWord(item.description))
        }
        return Evidences(byKey: Dictionary(grouping: all, by: \.key),
                         byWord: Dictionary(grouping: all.filter { $0.word != nil }, by: { $0.word ?? "" }))
    }

    static func suggest(for group: ReviewGroup, history: SavedHistory) -> [CategorySuggestion] {
        suggestions(for: [group], history: history)[group.id] ?? []
    }

    /// Suggestions of every group, by the id of the group.
    static func suggestions(for groups: [ReviewGroup], history: SavedHistory) -> [String: [CategorySuggestion]] {
        let evidence = groups.contains { $0.kind == .expense && !$0.key.isEmpty } ? evidences(history) : Evidences.empty
        var result: [String: [CategorySuggestion]] = [:]
        for group in groups { result[group.id] = suggest(group, history: history, evidence: evidence) }
        return result
    }

    private static func suggest(_ group: ReviewGroup, history: SavedHistory, evidence: Evidences) -> [CategorySuggestion] {
        guard group.kind == .expense, let operation = group.operations.first else { return [] }
        var result: [CategorySuggestion] = []
        func append(_ id: UUID, reason: CategorySuggestion.Reason, count: Int) {
            guard id != UncategorizedReview.otherExpenseID,
                  let category = history.expenseCategory(id: id),
                  !(category.group.name == "Другое" && category.category.name == "Прочее"),
                  !result.contains(where: { $0.categoryID == id }) else { return }
            result.append(CategorySuggestion(categoryID: id, group: category.group.name,
                                             subcategory: category.category.name, reason: reason, count: count))
        }

        let excluded = Set(group.operations.map(\.identity))
        if !group.key.isEmpty {
            let own = (evidence.byKey[group.key] ?? []).filter { !excluded.contains($0.operation.identity) }
            if let best = mostFrequent(own) { append(best.id, reason: .history, count: best.count) }
        }

        if let words = ReceiptParser.keywordCategory(merchant: operation.description),
           let categoryGroup = history.categoryTree.first(where: { $0.name == words.group }),
           let category = categoryGroup.categories.first(where: { $0.name == words.subcategory }) {
            append(category.id, reason: .words, count: 0)
        }

        if !group.key.isEmpty, let word = significantWord(operation.description) {
            let similar = (evidence.byWord[word] ?? []).filter {
                !$0.key.isEmpty && $0.key != group.key && !excluded.contains($0.operation.identity)
            }
            if let best = mostFrequent(similar), best.count >= 2, best.count * 5 >= similar.count * 4 {
                append(best.id, reason: .similarPayees, count: best.count)
            }
        }
        return Array(result.prefix(3))
    }

    static func ruleCandidates(_ history: SavedHistory) -> [RuleCandidate] {
        let ruled = Set((history.categoryRules ?? []).map(\.payeeKey))
        let overrides = history.categoryOverrides ?? [:]
        let resolver = ExpenseCategoryResolver(history)
        var byPayee: [String: [BankOperation]] = [:]
        for operation in history.operations where !operation.isManual && resolver.resolve(operation) != nil {
            let key = FinancialEngine.payeeRuleKey(operation.description)
            guard !key.isEmpty, !ruled.contains(key) else { continue }
            byPayee[key, default: []].append(operation)
        }
        return byPayee.compactMap { key, operations in
            let chosen = operations.compactMap { overrides[$0.identity] }
            guard chosen.count >= 3, let id = chosen.first, chosen.allSatisfy({ $0 == id }),
                  history.expenseCategory(id: id) != nil else { return nil }
            let latest = operations.sorted {
                let left = BankDateParser.parse($0.occurredAt) ?? .distantPast
                let right = BankDateParser.parse($1.occurredAt) ?? .distantPast
                return left == right ? $0.identity < $1.identity : left > right
            }[0]
            return RuleCandidate(payeeKey: key, title: latest.description, categoryID: id, operationCount: operations.count)
        }.sorted {
            $0.operationCount == $1.operationCount ? $0.payeeKey < $1.payeeKey : $0.operationCount > $1.operationCount
        }
    }

    private static func mostFrequent(_ evidence: [Evidence]) -> (id: UUID, count: Int)? {
        let grouped = Dictionary(grouping: evidence, by: \.categoryID)
        let ranked = grouped.map { id, items in
            (id: id, count: items.count, date: items.compactMap { BankDateParser.parse($0.operation.occurredAt) }.max() ?? .distantPast)
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        return ranked.first.map { ($0.id, $0.count) }
    }

    private static func significantWord(_ title: String) -> String? {
        // Legal/payment prefixes and generic shop labels cannot identify a merchant.
        let ignored: Set<String> = ["ооо", "оао", "зао", "пао", "ао", "ип", "ip", "llc", "ltd", "jsc",
                                    "оплата", "покупка", "перевод", "payment", "сбп", "sbp", "qr",
                                    "магазин", "супермаркет", "кафе", "аптека"]
        return title.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).first { $0.filter(\.isLetter).count >= 4 && !ignored.contains($0) }
    }
}
