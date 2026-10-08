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

/// Suggestions only: nothing is persisted until the user chooses an existing category.
enum CategorySuggestions {
    private struct Evidence {
        let operation: BankOperation
        let key: String
        let categoryID: UUID
    }

    static func suggest(for group: ReviewGroup, history: SavedHistory) -> [CategorySuggestion] {
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
        let resolver = ExpenseCategoryResolver(history)
        // resolve also excludes income, refunds, own transfers and unfinished operations.
        let evidence: [Evidence] = group.key.isEmpty ? [] : history.allOperations.compactMap { item in
            guard !excluded.contains(item.identity), let id = resolver.resolve(item)?.id,
                  id != UncategorizedReview.otherExpenseID,
                  let category = history.expenseCategory(id: id),
                  !(category.group.name == "Другое" && category.category.name == "Прочее") else { return nil }
            return Evidence(operation: item, key: FinancialEngine.payeeRuleKey(item.description), categoryID: id)
        }
        if !group.key.isEmpty, let best = mostFrequent(evidence.filter({ $0.key == group.key })) {
            append(best.id, reason: .history, count: best.count)
        }

        if let words = ReceiptParser.keywordCategory(merchant: operation.description),
           let categoryGroup = history.categoryTree.first(where: { $0.name == words.group }),
           let category = categoryGroup.categories.first(where: { $0.name == words.subcategory }) {
            append(category.id, reason: .words, count: 0)
        }

        if !group.key.isEmpty, let word = significantWord(operation.description) {
            let similar = evidence.filter {
                !$0.key.isEmpty && $0.key != group.key && significantWord($0.operation.description) == word
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
