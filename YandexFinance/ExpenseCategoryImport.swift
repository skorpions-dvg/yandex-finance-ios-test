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
        guard !data.isEmpty else {
            throw AppFailure(message: "Файл пуст. Дождитесь загрузки из iCloud и выберите его ещё раз.")
        }
        guard data.count <= 5_000_000 else {
            throw AppFailure(message: "Файл разметки слишком большой.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppFailure(message: "Не удалось прочитать JSON. Выберите исходный файл разметки категорий.")
        }
        if object["history"] != nil {
            throw AppFailure(message: "Выбрана резервная копия. Здесь нужен файл разметки категорий, а копия открывается через «Восстановить из копии».")
        }
        if object["operations"] != nil && object["format"] == nil {
            throw AppFailure(message: "Выбран список для ручного разбора. Для импорта нужен файл разметки категорий, в названии которого есть «category-plan» или «Разметка».")
        }
        guard object["format"] as? String == "finance-test-category-plan-v1" else {
            throw AppFailure(message: "Это не разметка категорий Finance Test. Выберите файл «category-plan» или «Разметка».")
        }
        guard let plan = try? JSONDecoder().decode(Self.self, from: data) else {
            throw AppFailure(message: "В разметке отсутствуют нужные поля или неверно записаны данные. Нужен исходный JSON без изменений.")
        }
        guard plan.assignments.count <= 10_000,
              Set(plan.assignments.map(\.identity)).count == plan.assignments.count else {
            throw AppFailure(message: "Разметка содержит слишком много записей или повторяющиеся операции.")
        }
        return plan
    }

    #if os(iOS)
    /// Coordinate reads with the document provider so an iCloud file is materialized before decoding.
    static func read(from url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var readResult: Swift.Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            readResult = Swift.Result { try Data(contentsOf: readableURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let readResult else { throw CocoaError(.fileReadUnknown) }
        return try decode(readResult.get())
    }
    #endif

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
                  !ruledPayees.contains(FinancialEngine.payeeRuleKey(operation.description)),
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
