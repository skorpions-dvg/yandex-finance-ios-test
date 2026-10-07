import Foundation

struct OperationComponent: Codable, Equatable {
    let displayDate: String
    let amountKopecks: Int64
    var formattedAmount: String { (Decimal(amountKopecks) / 100).formatted(.currency(code: "RUB")) }
}

struct BankOperation: Codable, Equatable, Identifiable {
    let identity: String
    let occurredAt: String
    let timePrecision: String
    let description: String
    let amountKopecks: Int64
    let currency: String
    let status: String
    let category: String
    let mcc: String?
    let purpose: String?
    let paymentMethod: String?
    let providers: [String]
    let kind: String
    var components: [OperationComponent]?
    var verifiedAt: String?
    func sameFinancialContent(as other: BankOperation) -> Bool {
        var lhs = self, rhs = other
        lhs.verifiedAt = nil; rhs.verifiedAt = nil
        return lhs == rhs
    }
    var id: String { identity }
    var formattedAmount: String {
        let value = Decimal(amountKopecks) / 100
        return value.formatted(.currency(code: currency))
    }
}



extension BankOperation {
    var financialInput: FinancialOperationInput {
        FinancialOperationInput(occurredAt: occurredAt, description: description, amountKopecks: amountKopecks,
                                status: status, category: category, mcc: mcc, purpose: purpose, providers: providers, kind: kind,
                                componentAmountsKopecks: components?.map(\.amountKopecks) ?? [], paymentMethod: paymentMethod)
    }

    var financialAssessment: FinancialAssessment { FinancialEngine.classify(financialInput) }
}

struct ImportIssue: Codable, Equatable {
    let identity: String?
    let monthOrdinal: Int?
    let reason: String
    var rowSummary: String?
    var operationURL: String?
    var observedAt: String?
    var sourceDate: String?
    var bankDate: String? {
        if let sourceDate { return sourceDate }
        guard let raw = operationURL, let url = URLComponents(string: raw),
              let encoded = url.queryItems?.first(where: { $0.name == "id" })?.value,
              let data = encoded.data(using: .utf8),
              let refs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return refs.compactMap { $0["operationTimestamp"] as? String }.sorted().first
    }
}

struct ImportBatch: Codable {
    let issues: [ImportIssue]?
    let operations: [BankOperation]
    let stopReason: String
    let skippedCount: Int?
    let warning: String?
    let oldestMonthOrdinal: Int?
    let monthsVisited: Int?
    let fastSkippedCount: Int?
    let openedCardCount: Int?
}

struct ProgressCheckpoint: Codable {
    let progress: String
    let operations: [BankOperation]
    let runID: String
    let throughSequence: Int
    let monthOrdinal: Int?
    let issues: [ImportIssue]
}

struct SavedHistory: Codable {
    var operations: [BankOperation] = []
    var lastSync: Date?
    var lastStopReason: String?
    var lastCompletedSync: Date?
    var bootstrapResumeMonth: Int?
    var bootstrapCompleted: Bool?
    var unresolvedIssues: [ImportIssue]?
    var statementArchiveThrough: Date?
    var statementImportedAt: Date?
    var statementOperationCount: Int?
    /// User-made account groups and accounts, in display order. Unlike bank operations they cannot be
    /// re-imported from the bank, which is why the backup exists.
    var accountGroups: [AccountGroup]?
    var accounts: [Account]?
    /// Income, expenses and transfers entered by hand (cash, other banks); not re-importable either.
    var manualOperations: [ManualOperation]?
    /// The user's expense tree; nil until the first edit (then `ExpenseCategoryGroup.builtin` is used).
    var expenseCategories: [ExpenseCategoryGroup]?
    /// "This payee always goes to this category", made from the operation card.
    var categoryRules: [CategoryRule]?
    /// Category chosen for one bank operation: operation identity -> `ExpenseCategory.id`. Wins over rules.
    var categoryOverrides: [String: UUID]?
    /// Set once the transfers to people were moved out of «Другое» in a tree the user had already edited.
    var transfersGroupMoved: Bool?
    /// "This sender's income always goes to this category" (a name from `FinancialEngine.incomeSubcategoryOrder`).
    var incomeCategoryRules: [IncomeCategoryRule]?
    /// Income category chosen for one bank operation: operation identity -> category name. Wins over rules.
    var incomeCategoryOverrides: [String: String]?
    /// Own title, icon and comment of bank operations: operation identity -> look.
    var operationLooks: [String: OperationLook]?
    /// Own title and icon for every operation of a payee.
    var payeeLookRules: [PayeeLookRule]?

    /// Bank operations together with the manual ones, for every list, report and forecast.
    var allOperations: [BankOperation] { operations + (manualOperations ?? []).map(\.bankOperation) }
}

/// An operation entered by hand. It becomes a regular `BankOperation` (identity "manual:<id>") for the reports,
/// so all classification rules apply; its chosen category travels in `purpose`.
struct ManualOperation: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case expense, income, transfer
    }

    var id = UUID()
    var kind: Kind
    /// Always positive; the sign comes from `kind`.
    var amountKopecks: Int64
    var date: Date
    /// Account the money leaves (expense, transfer) or arrives at (income).
    var accountID: UUID?
    /// Destination account of a transfer.
    var toAccountID: UUID?
    /// Expense: a group name of the user's tree (`SavedHistory.categoryTree`); income: nil.
    var group: String?
    /// Expense: a category name in that group; income: one of `FinancialEngine.incomeSubcategoryOrder`.
    var subcategory: String?
    var note: String = ""

    static let identityPrefix = "manual:"

    var bankOperation: BankOperation {
        let formatter = ISO8601DateFormatter()
        let categoryPath: String?
        switch kind {
        case .expense: categoryPath = group.flatMap { g in subcategory.map { "\(g)/\($0)" } }
        case .income: categoryPath = subcategory
        case .transfer: categoryPath = nil
        }
        let title: String
        switch kind {
        case .expense, .income: title = note.isEmpty ? (subcategory ?? "Операция") : note
        case .transfer: title = note.isEmpty ? "Перевод между своими счетами" : note
        }
        return BankOperation(identity: Self.identityPrefix + id.uuidString,
                             occurredAt: formatter.string(from: date),
                             timePrecision: "manual",
                             description: title,
                             amountKopecks: kind == .income ? amountKopecks : -amountKopecks,
                             currency: "RUB",
                             status: "Выполнено",
                             category: kind == .transfer ? "Переводы между своими счетами" : (subcategory ?? "Прочее"),
                             mcc: nil,
                             purpose: categoryPath.map { FinancialEngine.manualCategoryPrefix + $0 },
                             paymentMethod: "Вручную",
                             providers: [],
                             kind: kind == .income ? "income" : (kind == .expense ? "expense" : "internal_transfer"))
    }
}

extension BankOperation {
    var isManual: Bool { identity.hasPrefix(ManualOperation.identityPrefix) }
    /// The id of the manual operation behind this record, if it was entered by hand.
    var manualID: UUID? { isManual ? UUID(uuidString: String(identity.dropFirst(ManualOperation.identityPrefix.count))) : nil }
}

extension Account {
    /// Current balance: the entered balance, card movements from the bank (for the card account) and manual
    /// operations on this account dated from `startDate` on. Manual entries never move the scanned bank card,
    /// because its side of a transfer arrives from the bank anyway.
    func balance(bankOperations: [FinancialOperationInput], manual: [ManualOperation]) -> Int64 {
        var total = FinancialEngine.accountBalance(startKopecks: startBalanceKopecks, since: startDate,
                                                   tracksBankCard: tracksBankCard, operations: bankOperations)
        guard !tracksBankCard else { return total }
        for operation in manual where operation.date >= startDate {
            switch operation.kind {
            case .expense: if operation.accountID == id { total -= operation.amountKopecks }
            case .income: if operation.accountID == id { total += operation.amountKopecks }
            case .transfer:
                if operation.accountID == id { total -= operation.amountKopecks }
                if operation.toAccountID == id { total += operation.amountKopecks }
            }
        }
        return total
    }
}

struct AccountGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Missing in old backups: the group contributes to the overall balance by default.
    var includesInBalance: Bool?
}

extension Account {
    func contributesToBalance(groups: [AccountGroup]) -> Bool {
        showsBalance && (groups.first { $0.id == groupID }?.includesInBalance ?? true)
    }
}

struct Account: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// SF Symbol name.
    var icon: String
    /// One of `Account.palette` keys.
    var color: String
    var groupID: UUID?
    /// Balance entered by the user at `startDate`.
    var startBalanceKopecks: Int64
    var startDate: Date
    var showsBalance: Bool = true
    /// The bank card scanned from Yandex Bank: its operations after `startDate` move the balance.
    var tracksBankCard: Bool = false

    static let palette = ["orange", "red", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "gray"]
}

/// The accounts screen in edit mode is one flat list: each group header followed by its accounts, then the
/// accounts without a group. Dragging a header moves the whole group; dragging an account moves it under
/// whichever group header ends up above it.
enum AccountListItem: Hashable {
    case group(UUID)
    case account(UUID)
    case ungroupedHeader

    var isHeader: Bool { if case .account = self { return false }; return true }

    static func flatten(groups: [AccountGroup], accounts: [Account]) -> [AccountListItem] {
        let groupIDs = Set(groups.map(\.id))
        var items: [AccountListItem] = []
        for group in groups {
            items.append(.group(group.id))
            items += accounts.filter { $0.groupID == group.id }.map { .account($0.id) }
        }
        let ungrouped = accounts.filter { $0.groupID.map { !groupIDs.contains($0) } ?? true }
        if !ungrouped.isEmpty {
            items.append(.ungroupedHeader)
            items += ungrouped.map { .account($0.id) }
        }
        return items
    }

    /// The list after a drag from `source` to `destination` (SwiftUI `onMove` offsets).
    static func move(_ items: [AccountListItem], from source: IndexSet, to destination: Int) -> [AccountListItem] {
        guard source.count == 1, let index = source.first, items.indices.contains(index) else { return items }
        switch items[index] {
        case .ungroupedHeader:
            return items
        case .account:
            // Same semantics as SwiftUI's move(fromOffsets:toOffset:), which is not available without SwiftUI.
            var moved = items
            let item = moved.remove(at: index)
            moved.insert(item, at: min(destination > index ? destination - 1 : destination, moved.count))
            return moved
        case .group:
            let blockEnd = items[(index + 1)...].firstIndex(where: \.isHeader) ?? items.count
            if destination >= index && destination <= blockEnd { return items }
            let block = Array(items[index..<blockEnd])
            var rest = items
            rest.removeSubrange(index..<blockEnd)
            let insertion: Int
            if destination < index {
                // Moving up: land right before the group whose block contains the drop point.
                insertion = rest[..<min(destination + 1, rest.count)].lastIndex(where: { if case .group = $0 { return true }; return false }) ?? 0
                let target = min(destination, rest.count)
                let landing = target < rest.count && rest[target].isHeader ? target : insertion
                rest.insert(contentsOf: block, at: landing)
                return rest
            }
            // Moving down: land after the block containing the drop point, never below the ungrouped accounts.
            let target = destination - block.count
            let ungroupedStart = rest.firstIndex(of: .ungroupedHeader) ?? rest.count
            insertion = min(rest[target...].firstIndex(where: \.isHeader) ?? rest.count, ungroupedStart)
            rest.insert(contentsOf: block, at: insertion)
            return rest
        }
    }

    /// Groups and accounts in the order of `items`; each account belongs to the nearest group header above it.
    static func apply(_ items: [AccountListItem], groups: [AccountGroup], accounts: [Account]) -> (groups: [AccountGroup], accounts: [Account]) {
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var orderedGroups: [AccountGroup] = []
        var orderedAccounts: [Account] = []
        var current: UUID?
        for item in items {
            switch item {
            case .group(let id):
                current = id
                if let group = groupsByID[id] { orderedGroups.append(group) }
            case .ungroupedHeader:
                current = nil
            case .account(let id):
                guard var account = accountsByID[id] else { continue }
                account.groupID = current
                orderedAccounts.append(account)
            }
        }
        return (orderedGroups, orderedAccounts)
    }
}

// MARK: - Expense categories

/// A category of the user's expense tree. `sources` are the built-in "Group/Subcategory" paths whose bank
/// operations land here, so renaming, moving and merging never touches saved bank operations.
struct ExpenseCategory: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var sources: [String] = []
}

struct ExpenseCategoryGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Bills and other obligations: the forecast never treats them as one-off purchases.
    var isFixedCosts = false
    var categories: [ExpenseCategory]

    /// The built-in tree with fixed ids, so a choice made before the first edit keeps pointing at the same category.
    static let builtin: [ExpenseCategoryGroup] = ExpenseTaxonomy.builtin.groups.enumerated().map { groupIndex, group in
        ExpenseCategoryGroup(id: builtinID(groupIndex + 1, 0), name: group.name, isFixedCosts: group.isFixedCosts,
                             categories: group.subcategories.enumerated().map { index, name in
                                 let path = group.name + "/" + name
                                 let place = legacyPlaces[path] ?? (groupIndex + 1, index + 1)
                                 return ExpenseCategory(id: builtinID(place.0, place.1), name: name,
                                                        sources: [path] + (legacySources[path] ?? []))
                             })
    }

    /// Ids of the tree before «Переводы» left «Другое» (41.46). Choices and rules made earlier keep their category.
    private static let legacyPlaces: [String: (Int, Int)] = [
        "Переводы/Переводы другим": (5, 5), "Другое/Комиссии": (5, 6), "Другое/Прочее": (5, 7),
    ]
    /// Paths saved before that move, still found in manual entries.
    static let legacySources: [String: [String]] = ["Переводы/Переводы другим": ["Другое/Переводы другим"]]

    private static func builtinID(_ group: Int, _ category: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%06X%06X", group, category))!
    }
}

/// "Every expense of this payee goes to this category".
struct CategoryRule: Codable, Equatable, Identifiable {
    var id = UUID()
    /// `FinancialEngine.counterpartyKey` of the operation title.
    var payeeKey: String
    /// The operation title the rule was made from, for the rules list.
    var title: String
    var categoryID: UUID
}

/// "Every income from this sender goes to this category".
struct IncomeCategoryRule: Codable, Equatable, Identifiable {
    var id = UUID()
    /// `FinancialEngine.counterpartyKey` of the operation title.
    var payeeKey: String
    /// The operation title the rule was made from, for the rules list.
    var title: String
    var category: String
}

/// Finds the user's category of each expense: the choice on the operation, then a payee rule, then the built-in
/// guess mapped through the tree. Built once per list, because it indexes the whole tree.
struct ExpenseCategoryResolver {
    private var pathByID: [UUID: String] = [:]
    private var idByPath: [String: UUID] = [:]
    private var idBySource: [String: UUID] = [:]
    private var ruleByKey: [String: UUID] = [:]
    private let overrides: [String: UUID]
    private var incomeRuleByKey: [String: String] = [:]
    private let incomeOverrides: [String: String]

    init(_ history: SavedHistory) {
        for group in history.categoryTree {
            for category in group.categories {
                let path = group.name + "/" + category.name
                pathByID[category.id] = path
                idByPath[path] = category.id
                for source in category.sources {
                    idBySource[source] = category.id
                    // A tree saved before 41.46 knows transfers by their old path; the guess now uses the new one.
                    if source == "Другое/Переводы другим" { idBySource["Переводы/Переводы другим"] = category.id }
                }
            }
        }
        for rule in history.categoryRules ?? [] where !rule.payeeKey.isEmpty { ruleByKey[rule.payeeKey] = rule.categoryID }
        overrides = history.categoryOverrides ?? [:]
        for rule in history.incomeCategoryRules ?? [] where !rule.payeeKey.isEmpty { incomeRuleByKey[rule.payeeKey] = rule.category }
        incomeOverrides = history.incomeCategoryOverrides ?? [:]
    }

    /// The user's income category of a bank income or interest; nil for anything else or when nothing was chosen.
    func chosenIncomeCategory(_ operation: BankOperation) -> String? {
        guard !operation.isManual else { return nil }
        let type = FinancialEngine.classify(operation.financialInput).type
        guard type == .income || type == .interestIncome else { return nil }
        let chosen = incomeOverrides[operation.identity] ?? incomeRuleByKey[FinancialEngine.counterpartyKey(operation.description)]
        return chosen.flatMap { FinancialEngine.incomeSubcategoryOrder.contains($0) ? $0 : nil }
    }

    /// The category of an expense or a fee; nil for income, refunds, transfers, split and unfinished operations.
    /// `id` is nil only when the path is outside the tree (an old manual entry of a deleted category).
    func resolve(_ operation: BankOperation) -> (id: UUID?, path: String)? {
        let input = operation.financialInput
        let assessment = FinancialEngine.classify(input)
        guard assessment.type == .expense || assessment.type == .commission else { return nil }
        let guess = FinancialEngine.expenseCategory(for: input, assessment: assessment)
        let guessPath = guess.group + "/" + guess.subcategory
        if operation.isManual {
            // A manual entry carries the names it was saved with; edits of the tree keep them current.
            let id = idByPath[guessPath] ?? idBySource[guessPath]
            return (id, id.flatMap { pathByID[$0] } ?? guessPath)
        }
        for id in [overrides[operation.identity], ruleByKey[FinancialEngine.counterpartyKey(operation.description)]] {
            if let id, let path = pathByID[id] { return (id, path) }
        }
        if let id = idBySource[guessPath], let path = pathByID[id] { return (id, path) }
        return (nil, guessPath)
    }

    func financialInput(for operation: BankOperation) -> FinancialOperationInput {
        var input = operation.financialInput
        input.categoryPath = resolve(operation)?.path
        input.incomeCategoryName = chosenIncomeCategory(operation)
        return input
    }
}

extension SavedHistory {
    var categoryTree: [ExpenseCategoryGroup] { expenseCategories ?? ExpenseCategoryGroup.builtin }

    /// The tree in the form the engine takes for ordering, comparison and the forecast.
    var expenseTaxonomy: ExpenseTaxonomy {
        ExpenseTaxonomy(groups: categoryTree.map {
            ExpenseTaxonomy.Group(name: $0.name, subcategories: $0.categories.map(\.name), isFixedCosts: $0.isFixedCosts)
        })
    }

    /// Every operation with the user's categories applied: use this for reports, the forecast, search and lists
    /// instead of `allOperations.map(\.financialInput)`.
    var financialInputs: [FinancialOperationInput] {
        let resolver = ExpenseCategoryResolver(self)
        return allOperations.map(resolver.financialInput(for:))
    }

    func financialInput(for operation: BankOperation) -> FinancialOperationInput {
        ExpenseCategoryResolver(self).financialInput(for: operation)
    }

    /// Current category of an expense in the user's tree; nil for anything that is not an expense.
    func expenseCategoryID(for operation: BankOperation) -> UUID? {
        ExpenseCategoryResolver(self).resolve(operation)?.id
    }

    func expenseCategory(id: UUID) -> (group: ExpenseCategoryGroup, category: ExpenseCategory)? {
        for group in categoryTree {
            if let category = group.categories.first(where: { $0.id == id }) { return (group, category) }
        }
        return nil
    }

    // MARK: Editing the tree. Every change returns false and leaves the history untouched when it is not allowed.

    /// Trimmed name, or nil when it is empty or has "/", which separates the group and the category in a path.
    private static func cleanName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("/") ? nil : trimmed
    }

    private static let reservedGroupNames: Set<String> = ["Сплит", "Возвраты"]

    @discardableResult
    mutating func addExpenseGroup(name: String) -> UUID? {
        var tree = categoryTree
        guard let name = Self.cleanName(name), !Self.reservedGroupNames.contains(name),
              !tree.contains(where: { $0.name == name }) else { return nil }
        let group = ExpenseCategoryGroup(name: name, categories: [])
        tree.append(group)
        expenseCategories = tree
        return group.id
    }

    @discardableResult
    mutating func addExpenseCategory(name: String, groupID: UUID) -> UUID? {
        var tree = categoryTree
        guard let name = Self.cleanName(name), let index = tree.firstIndex(where: { $0.id == groupID }),
              !tree[index].categories.contains(where: { $0.name == name }) else { return nil }
        let category = ExpenseCategory(name: name)
        tree[index].categories.append(category)
        expenseCategories = tree
        return category.id
    }

    @discardableResult
    mutating func renameExpenseGroup(_ id: UUID, to name: String) -> Bool {
        var tree = categoryTree
        guard let name = Self.cleanName(name), !Self.reservedGroupNames.contains(name),
              let index = tree.firstIndex(where: { $0.id == id }),
              !tree.contains(where: { $0.id != id && $0.name == name }) else { return false }
        let old = tree[index]
        tree[index].name = name
        expenseCategories = tree
        for category in old.categories {
            renameManualPaths(from: old.name + "/" + category.name, to: name + "/" + category.name)
        }
        return true
    }

    @discardableResult
    mutating func renameExpenseCategory(_ id: UUID, to name: String) -> Bool {
        var tree = categoryTree
        guard let name = Self.cleanName(name), case let (groupIndex, index)? = Self.position(of: id, in: tree),
              !tree[groupIndex].categories.contains(where: { $0.id != id && $0.name == name }) else { return false }
        let group = tree[groupIndex].name
        let oldName = tree[groupIndex].categories[index].name
        tree[groupIndex].categories[index].name = name
        expenseCategories = tree
        renameManualPaths(from: group + "/" + oldName, to: group + "/" + name)
        return true
    }

    @discardableResult
    mutating func setFixedCosts(_ isFixedCosts: Bool, groupID: UUID) -> Bool {
        var tree = categoryTree
        guard let index = tree.firstIndex(where: { $0.id == groupID }) else { return false }
        tree[index].isFixedCosts = isFixedCosts
        expenseCategories = tree
        return true
    }

    /// Puts a group at `index` of the final order (0 = first).
    @discardableResult
    mutating func moveExpenseGroup(_ id: UUID, to index: Int) -> Bool {
        var tree = categoryTree
        guard let from = tree.firstIndex(where: { $0.id == id }) else { return false }
        let group = tree.remove(at: from)
        tree.insert(group, at: min(max(0, index), tree.count))
        expenseCategories = tree
        return true
    }

    /// Puts a category into a group (the same or another one) at `index` of that group's final order.
    @discardableResult
    mutating func moveExpenseCategory(_ id: UUID, toGroup groupID: UUID, at index: Int) -> Bool {
        var tree = categoryTree
        guard case let (fromGroup, from)? = Self.position(of: id, in: tree),
              let target = tree.firstIndex(where: { $0.id == groupID }) else { return false }
        let category = tree[fromGroup].categories[from]
        if target != fromGroup, tree[target].categories.contains(where: { $0.name == category.name }) { return false }
        let oldPath = tree[fromGroup].name + "/" + category.name
        tree[fromGroup].categories.remove(at: from)
        tree[target].categories.insert(category, at: min(max(0, index), tree[target].categories.count))
        expenseCategories = tree
        renameManualPaths(from: oldPath, to: tree[target].name + "/" + category.name)
        return true
    }

    /// Deletes a category; its operations, rules and manual entries move to `targetID`.
    @discardableResult
    mutating func deleteExpenseCategory(_ id: UUID, mergingInto targetID: UUID) -> Bool {
        var tree = categoryTree
        guard id != targetID, case let (groupIndex, index)? = Self.position(of: id, in: tree),
              case let (targetGroup, target)? = Self.position(of: targetID, in: tree) else { return false }
        let removed = tree[groupIndex].categories[index]
        tree[targetGroup].categories[target].sources += removed.sources
        let targetPath = tree[targetGroup].name + "/" + tree[targetGroup].categories[target].name
        tree[groupIndex].categories.remove(at: index)
        expenseCategories = tree
        redirect(categoryID: id, path: tree[groupIndex].name + "/" + removed.name, to: targetID, path: targetPath)
        return true
    }

    /// Deletes a group with all its categories; everything in them moves to `targetID`, a category of another group.
    @discardableResult
    mutating func deleteExpenseGroup(_ id: UUID, mergingInto targetID: UUID) -> Bool {
        guard let group = categoryTree.first(where: { $0.id == id }),
              case let (targetGroup, _)? = Self.position(of: targetID, in: categoryTree),
              categoryTree[targetGroup].id != id else { return false }
        for category in group.categories { deleteExpenseCategory(category.id, mergingInto: targetID) }
        expenseCategories = categoryTree.filter { $0.id != id }
        return true
    }

    // MARK: Choosing the category of an operation

    /// Moves an expense to a category. `forPayee` makes a rule for every expense of the same payee, past and future;
    /// otherwise only this operation changes. A manual entry simply takes the new category.
    @discardableResult
    mutating func setExpenseCategory(_ categoryID: UUID, for operation: BankOperation, forPayee: Bool) -> Bool {
        guard case let (group, category)? = expenseCategory(id: categoryID),
              ExpenseCategoryResolver(self).resolve(operation) != nil else { return false }
        if expenseCategories == nil { expenseCategories = categoryTree }
        if let manualID = operation.manualID {
            guard let index = manualOperations?.firstIndex(where: { $0.id == manualID }) else { return false }
            manualOperations?[index].group = group.name
            manualOperations?[index].subcategory = category.name
            return true
        }
        let key = FinancialEngine.counterpartyKey(operation.description)
        if forPayee && !key.isEmpty {
            var rules = categoryRules ?? []
            if let index = rules.firstIndex(where: { $0.payeeKey == key }) { rules[index].categoryID = categoryID }
            else { rules.append(CategoryRule(payeeKey: key, title: operation.description, categoryID: categoryID)) }
            categoryRules = rules
            categoryOverrides?[operation.identity] = nil
        } else {
            var overrides = categoryOverrides ?? [:]
            overrides[operation.identity] = categoryID
            categoryOverrides = overrides
        }
        return true
    }

    /// In a tree the user edited before 41.46, moves «Переводы другим» from «Другое» into its own group «Переводы»,
    /// as the built-in tree now has it. Once only: a later move back by the user stays.
    mutating func moveTransfersToOwnGroup() {
        guard expenseCategories != nil, transfersGroupMoved != true else { return }
        transfersGroupMoved = true
        guard let group = categoryTree.first(where: { $0.name == "Другое" }),
              let transfers = group.categories.first(where: { $0.sources.contains("Другое/Переводы другим") }) else { return }
        let target = categoryTree.first(where: { $0.name == "Переводы" })?.id ?? addExpenseGroup(name: "Переводы")
        if let target { moveExpenseCategory(transfers.id, toGroup: target, at: 0) }
    }

    mutating func removeCategoryRule(_ id: UUID) {
        categoryRules?.removeAll { $0.id == id }
    }

    /// Current income category of a bank or manual income; nil for anything that is not income.
    func incomeCategory(for operation: BankOperation) -> String? {
        let input = financialInput(for: operation)
        let type = FinancialEngine.classify(input).type
        guard type == .income || type == .interestIncome else { return nil }
        return FinancialEngine.incomeCategory(for: input)
    }

    /// Moves an income to a category. `forSender` makes a rule for every income of the same sender, past and
    /// future; otherwise only this operation changes (and wins over the rule). A manual income takes it directly.
    /// Returns false, changing nothing, for anything that is not income or interest: a refund, a transfer between
    /// own accounts, Split or an unfinished operation never becomes income.
    @discardableResult
    mutating func setIncomeCategory(_ category: String, for operation: BankOperation, forSender: Bool) -> Bool {
        guard FinancialEngine.incomeSubcategoryOrder.contains(category) else { return false }
        let type = FinancialEngine.classify(operation.financialInput).type
        guard type == .income || type == .interestIncome else { return false }
        if let manualID = operation.manualID {
            guard let index = manualOperations?.firstIndex(where: { $0.id == manualID }) else { return false }
            manualOperations?[index].subcategory = category
            return true
        }
        let key = FinancialEngine.counterpartyKey(operation.description)
        if forSender && !key.isEmpty {
            var rules = incomeCategoryRules ?? []
            if let index = rules.firstIndex(where: { $0.payeeKey == key }) { rules[index].category = category }
            else { rules.append(IncomeCategoryRule(payeeKey: key, title: operation.description, category: category)) }
            incomeCategoryRules = rules
            incomeCategoryOverrides?[operation.identity] = nil
        } else {
            var overrides = incomeCategoryOverrides ?? [:]
            overrides[operation.identity] = category
            incomeCategoryOverrides = overrides
        }
        return true
    }

    mutating func removeIncomeCategoryRule(_ id: UUID) {
        incomeCategoryRules?.removeAll { $0.id == id }
    }

    private static func position(of categoryID: UUID, in tree: [ExpenseCategoryGroup]) -> (Int, Int)? {
        for (groupIndex, group) in tree.enumerated() {
            if let index = group.categories.firstIndex(where: { $0.id == categoryID }) { return (groupIndex, index) }
        }
        return nil
    }

    private mutating func renameManualPaths(from oldPath: String, to newPath: String) {
        guard oldPath != newPath, var operations = manualOperations else { return }
        let parts = newPath.split(separator: "/", maxSplits: 1).map(String.init)
        for index in operations.indices where operations[index].kind == .expense
            && "\(operations[index].group ?? "")/\(operations[index].subcategory ?? "")" == oldPath {
            operations[index].group = parts[0]
            operations[index].subcategory = parts[1]
        }
        manualOperations = operations
    }

    private mutating func redirect(categoryID: UUID, path: String, to targetID: UUID, path targetPath: String) {
        if var rules = categoryRules {
            for index in rules.indices where rules[index].categoryID == categoryID { rules[index].categoryID = targetID }
            categoryRules = rules
        }
        categoryOverrides = categoryOverrides?.mapValues { $0 == categoryID ? targetID : $0 }
        renameManualPaths(from: path, to: targetPath)
    }
}

// MARK: - The user's look of bank operations

/// Own title, icon and comment of a bank operation. Bank data is never changed; this is kept beside it.
struct OperationLook: Codable, Equatable {
    var title: String?
    var icon: String?
    var note: String?

    var isEmpty: Bool { title == nil && icon == nil && note == nil }
}

/// "Show every operation of this payee with this title and icon".
struct PayeeLookRule: Codable, Equatable, Identifiable {
    var id = UUID()
    /// `FinancialEngine.counterpartyKey` of the bank title.
    var payeeKey: String
    /// The bank title the rule was made from.
    var bankTitle: String
    var title: String?
    var icon: String?
}

extension SavedHistory {
    /// Title and icon: the choice on this operation, then the payee rule. The comment belongs to the operation only.
    func look(for operation: BankOperation) -> OperationLook {
        let own = operationLooks?[operation.identity]
        let key = FinancialEngine.counterpartyKey(operation.description)
        let rule = key.isEmpty ? nil : payeeLookRules?.first { $0.payeeKey == key }
        return OperationLook(title: own?.title ?? rule?.title, icon: own?.icon ?? rule?.icon, note: own?.note)
    }

    /// Sets the title and icon (nil or an empty title returns to the bank's). `forPayee` makes a rule for every
    /// operation of the same payee, past and future; otherwise only this operation changes and wins over the rule.
    mutating func setLook(title: String?, icon: String?, for operation: BankOperation, forPayee: Bool) {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = (cleanTitle?.isEmpty ?? true) || cleanTitle == operation.description ? nil : cleanTitle
        let key = FinancialEngine.counterpartyKey(operation.description)
        var looks = operationLooks ?? [:]
        var own = looks[operation.identity] ?? OperationLook()
        if forPayee && !key.isEmpty {
            var rules = payeeLookRules ?? []
            rules.removeAll { $0.payeeKey == key }
            if newTitle != nil || icon != nil {
                rules.append(PayeeLookRule(payeeKey: key, bankTitle: operation.description, title: newTitle, icon: icon))
            }
            payeeLookRules = rules
            own.title = nil
            own.icon = nil
        } else {
            own.title = newTitle
            own.icon = icon
        }
        looks[operation.identity] = own.isEmpty ? nil : own
        operationLooks = looks
    }

    mutating func setNote(_ note: String, for operation: BankOperation) {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var looks = operationLooks ?? [:]
        var own = looks[operation.identity] ?? OperationLook()
        own.note = clean.isEmpty ? nil : clean
        looks[operation.identity] = own.isEmpty ? nil : own
        operationLooks = looks
    }
}

/// Plain JSON copy of everything the app keeps, for the user's own backup.
enum HistoryBackup {
    static let formatVersion = 1

    private struct Envelope: Codable {
        let format: Int
        let exportedAt: Date
        let history: SavedHistory
    }

    static func encode(_ history: SavedHistory, exportedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(format: formatVersion, exportedAt: exportedAt, history: history))
    }

    static func decode(_ data: Data) throws -> SavedHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            throw AppFailure(message: "Это не резервная копия Finance Test или файл повреждён.")
        }
        guard envelope.format <= formatVersion else {
            throw AppFailure(message: "Копия сделана более новой версией приложения. Обновите приложение и повторите.")
        }
        return envelope.history
    }
}

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
