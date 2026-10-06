import Foundation

/// A local set of category assignments, never a replacement for the history.
struct ExpenseCategoryImport: Codable {
    struct Move: Codable {
        let fromGroup: String
        let category: String
        let toGroup: String
    }
    struct Assignment: Codable {
        let identity: String
        let description: String
        let occurredAt: String
        let amountKopecks: Int64
        let fromPath: String
        let toPath: String
    }
    struct Result {
        let history: SavedHistory
        let assigned: Int
        let skipped: Int
        let moved: Int
        let destinations: [String: Int]
    }

    let format: String
    let moves: [Move]
    let assignments: [Assignment]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 5_000_000,
              let plan = try? JSONDecoder().decode(Self.self, from: data),
              plan.format == "finance-test-category-plan-v1",
              plan.assignments.count <= 10_000,
              Set(plan.assignments.map(\.identity)).count == plan.assignments.count else {
            throw AppFailure(message: "Это не файл разметки категорий Finance Test или он повреждён.")
        }
        return plan
    }

    /// Work on a copy. Any invalid destination rejects the entire plan.
    /// Explicit choices made since the export and changed operations are skipped.
    func preview(_ original: SavedHistory) throws -> Result {
        guard format == "finance-test-category-plan-v1",
              Set(assignments.map(\.identity)).count == assignments.count else {
            throw AppFailure(message: "Некорректный файл разметки.")
        }
        var history = original
        var moved = 0
        for move in moves {
            guard move.fromGroup != move.toGroup else {
                throw AppFailure(message: "Группа переноса совпадает с исходной.")
            }
            if let source = history.categoryTree.first(where: { $0.name == move.fromGroup }),
               let category = source.categories.first(where: { $0.name == move.category }) {
                let targetID: UUID
                if let target = history.categoryTree.first(where: { $0.name == move.toGroup }) {
                    targetID = target.id
                } else if let id = history.addExpenseGroup(name: move.toGroup) {
                    targetID = id
                } else { throw AppFailure(message: "Не удалось создать группу «\(move.toGroup)».") }
                guard history.moveExpenseCategory(category.id, toGroup: targetID, at: 0) else {
                    throw AppFailure(message: "Не удалось перенести категорию «\(move.category)».")
                }
                moved += 1
            } else if !history.categoryTree.contains(where: {
                $0.name == move.toGroup && $0.categories.contains(where: { $0.name == move.category })
            }) {
                throw AppFailure(message: "Исходная категория «\(move.category)» отсутствует.")
            }
        }
        var targets: [String: UUID] = [:]
        for group in history.categoryTree {
            for category in group.categories { targets[group.name + "/" + category.name] = category.id }
        }
        guard assignments.allSatisfy({ targets[$0.toPath] != nil }) else {
            throw AppFailure(message: "Категория назначения отсутствует. Проверьте дерево категорий.")
        }
        let operations = Dictionary(original.operations.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let resolver = ExpenseCategoryResolver(original)
        let ruledPayees = Set((original.categoryRules ?? []).map(\.payeeKey))
        var assigned = 0, skipped = 0
        var destinations: [String: Int] = [:]
        for item in assignments {
            guard let operation = operations[item.identity],
                  operation.description == item.description,
                  operation.occurredAt == item.occurredAt,
                  operation.amountKopecks == item.amountKopecks,
                  original.categoryOverrides?[item.identity] == nil,
                  !ruledPayees.contains(FinancialEngine.counterpartyKey(operation.description)),
                  resolver.resolve(operation)?.path == item.fromPath else {
                skipped += 1
                continue
            }
            guard history.setExpenseCategory(targets[item.toPath]!, for: operation, forPayee: false) else {
                throw AppFailure(message: "Операция не допускает смену категории.")
            }
            assigned += 1
            destinations[item.toPath, default: 0] += 1
        }
        return Result(history: history, assigned: assigned, skipped: skipped, moved: moved, destinations: destinations)
    }
}
