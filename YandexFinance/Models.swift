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
    /// Photos of receipts: operation identity -> names of the files in the receipts folder. The photos themselves stay
    /// on the device (they are not part of the JSON backup); a name whose file is missing is shown as unavailable.
    var receipts: [String: [String]]?
    /// What the owner confirmed about incoming operations the engine left «unknown»: operation identity -> "income",
    /// "refund" or "own". It never changes an operation that is already named.
    var operationNatures: [String: String]?
    /// Spending limits of the month (stage 46); nil until the first one is set.
    var budgets: [Budget]?
    /// The balances the bank page showed at the last refresh where they were found (card and Save), for the reconciliation.
    var bankBalances: BankBalanceReading?
    /// The owner's answers about regular payments that did not come on their day, by `FinancialEngine.paymentKey`.
    var paymentAnswers: [String: FinancialEngine.PaymentAnswer]?
    /// The goods of a receipt, per operation (identity): name and the final price of the line. Not the comment: the comment
    /// stays the owner's own words.
    var receiptGoods: [String: [ReceiptGood]]?
    /// What the phone read from the receipt when the operation was added (the raw text and what the reading made of it): the
    /// material for improving the reading.
    var receiptScans: [String: ReceiptScan]?
    /// Operations whose receipts were already put into a collection for the check of the reading.
    var collectedReceiptIdentities: [String]?

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
    /// Stands for the account of a manual entry that has none (never a real account).
    static let noAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

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
        if tracksSave == true {
            return FinancialEngine.saveAccountBalance(startKopecks: startBalanceKopecks, since: startDate, operations: bankOperations)
        }
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

    /// The reserve counts the accounts of the balance that are not put aside.
    func contributesToReserve(groups: [AccountGroup]) -> Bool {
        contributesToBalance(groups: groups) && (countsInReserve ?? true)
    }
}

extension SavedHistory {
    var reserveAccounts: [Account] {
        let groups = accountGroups ?? []
        return (accounts ?? []).filter { $0.contributesToReserve(groups: groups) }
    }

    /// The money the reserve starts from: the balance of the accounts it counts.
    var reserveBalanceKopecks: Int64 {
        let bank = operations.map(\.financialInput)
        let manual = manualOperations ?? []
        return reserveAccounts.reduce(0) { $0 + $1.balance(bankOperations: bank, manual: manual) }
    }

    /// Sets whether the accounts are counted in the reserve; ids that are not accounts are ignored.
    mutating func setReserveCounting(_ counts: Bool, accountIDs: Set<UUID>) {
        guard var all = accounts else { return }
        for index in all.indices where accountIDs.contains(all[index].id) { all[index].countsInReserve = counts }
        accounts = all
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
    /// Set to false for money that is put aside (a savings goal, a deposit): it stays in the balance but is not
    /// counted in the reserve until the end of the month. Missing (old data): counted.
    var countsInReserve: Bool?
    /// The Save account of Yandex Bank: its interest, the transfers with the card and the payments from it come from the
    /// bank. Missing (old data): kept by hand.
    var tracksSave: Bool?

    /// An account whose balance is moved by the bank, not by entries made by hand.
    var followsBank: Bool { tracksBankCard || tracksSave == true }

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
    private let natures: [String: String]
    private let manualAccounts: [String: UUID]
    /// The Save account kept from the bank: the rows of Save belong to it (for the account choice of the reports).
    private let saveAccountID: UUID?

    init(_ history: SavedHistory) {
        natures = history.operationNatures ?? [:]
        saveAccountID = (history.accounts ?? []).first { $0.tracksSave == true }?.id
        manualAccounts = Dictionary((history.manualOperations ?? []).map {
            (ManualOperation.identityPrefix + $0.id.uuidString, $0.accountID ?? ManualOperation.noAccountID)
        }, uniquingKeysWith: { first, _ in first })
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

    /// The engine input of an operation with what the owner confirmed about it.
    func input(_ operation: BankOperation) -> FinancialOperationInput {
        var input = operation.financialInput
        if let nature = natures[operation.identity] { input.confirmedNature = nature }
        input.accountID = manualAccounts[operation.identity]
        // A purchase with Split or with Plus points is no money of the bank card or of Save: it belongs to no money account, so the
        // report of a chosen account leaves it out (it stays in «all accounts»).
        if input.accountID == nil, FinancialEngine.isSplitOrPointsSide(input) { input.accountID = ManualOperation.noAccountID }
        if input.accountID == nil, let saveAccountID, FinancialEngine.isSaveSide(input) { input.accountID = saveAccountID }
        return input
    }

    /// The user's income category of a bank income or interest; nil for anything else or when nothing was chosen.
    func chosenIncomeCategory(_ operation: BankOperation) -> String? {
        guard !operation.isManual else { return nil }
        let type = FinancialEngine.classify(input(operation)).type
        guard type == .income || type == .interestIncome else { return nil }
        let chosen = incomeOverrides[operation.identity] ?? incomeRuleByKey[FinancialEngine.payeeRuleKey(operation.description)]
        return chosen.flatMap { FinancialEngine.incomeSubcategoryOrder.contains($0) ? $0 : nil }
    }

    /// The category of an expense or a fee; nil for income, refunds, transfers, split and unfinished operations.
    /// `id` is nil only when the path is outside the tree (an old manual entry of a deleted category).
    func resolve(_ operation: BankOperation) -> (id: UUID?, path: String)? {
        let input = self.input(operation)
        let assessment = FinancialEngine.classify(input)
        guard assessment.type == .expense || assessment.type == .commission else { return nil }
        let guess = FinancialEngine.expenseCategory(for: input, assessment: assessment)
        let guessPath = guess.group + "/" + guess.subcategory
        if operation.isManual {
            // A manual entry carries the names it was saved with; edits of the tree keep them current.
            let id = idByPath[guessPath] ?? idBySource[guessPath]
            return (id, id.flatMap { pathByID[$0] } ?? guessPath)
        }
        for id in [overrides[operation.identity], ruleByKey[FinancialEngine.payeeRuleKey(operation.description)]] {
            if let id, let path = pathByID[id] { return (id, path) }
        }
        if let id = idBySource[guessPath], let path = pathByID[id] { return (id, path) }
        return (nil, guessPath)
    }

    func financialInput(for operation: BankOperation) -> FinancialOperationInput {
        var input = self.input(operation)
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
        let key = FinancialEngine.payeeRuleKey(operation.description)
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
        let type = FinancialEngine.classify(ExpenseCategoryResolver(self).input(operation)).type
        guard type == .income || type == .interestIncome else { return false }
        if let manualID = operation.manualID {
            guard let index = manualOperations?.firstIndex(where: { $0.id == manualID }) else { return false }
            manualOperations?[index].subcategory = category
            return true
        }
        let key = FinancialEngine.payeeRuleKey(operation.description)
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
        let key = FinancialEngine.payeeRuleKey(operation.description)
        let rule = key.isEmpty ? nil : payeeLookRules?.first { $0.payeeKey == key }
        return OperationLook(title: own?.title ?? rule?.title, icon: own?.icon ?? rule?.icon, note: own?.note)
    }

    /// Sets the title and icon (nil or an empty title returns to the bank's). `forPayee` makes a rule for every
    /// operation of the same payee, past and future; otherwise only this operation changes and wins over the rule.
    mutating func setLook(title: String?, icon: String?, for operation: BankOperation, forPayee: Bool) {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = (cleanTitle?.isEmpty ?? true) || cleanTitle == operation.description ? nil : cleanTitle
        let key = FinancialEngine.payeeRuleKey(operation.description)
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

// MARK: - Account report (stage 42)

/// One operation as it moves one account: `delta` is its signed effect on that account's balance
/// (a transfer is negative for the account it leaves and positive for the one it reaches).
/// The balances read from the bank page: the card («Карта Пэй») and Save («Счёт в Сейвах»), when they were seen.
struct BankBalanceReading: Codable, Equatable {
    var cardKopecks: Int64?
    var saveKopecks: Int64?
    /// The last time anything was read.
    var readAt: Date
    /// When each balance itself was read (older copies have none: then `readAt`).
    var cardReadAt: Date?
    var saveReadAt: Date?
}

extension SavedHistory {
    /// The bank's balance of an account that follows the bank (the card or Save), from the last reading.
    func bankBalance(for account: Account) -> Int64? {
        if account.tracksBankCard { return bankBalances?.cardKopecks }
        if account.tracksSave == true { return bankBalances?.saveKopecks }
        return nil
    }

    /// When the bank's balance of `account` was read itself.
    func bankBalanceReadAt(for account: Account) -> Date? {
        guard let reading = bankBalances else { return nil }
        if account.tracksBankCard { return reading.cardKopecks == nil ? nil : (reading.cardReadAt ?? reading.readAt) }
        if account.tracksSave == true { return reading.saveKopecks == nil ? nil : (reading.saveReadAt ?? reading.readAt) }
        return nil
    }

    /// The bank's balance was read after the operations were last saved: the two describe the same moment and may be compared
    /// for aligning (an older one may miss operations of the bank or count ones we already have).
    func bankBalanceIsFresh(for account: Account) -> Bool {
        guard let read = bankBalanceReadAt(for: account) else { return false }
        return read >= (lastSync ?? .distantPast).addingTimeInterval(-60)
    }

    /// The operations of the last `days` days that move `account`, for the explanation of a difference with the bank.
    func reconciliationRows(_ account: Account, days: Int = 60, now: Date = Date()) -> [FinancialEngine.ReconciliationRow] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        return accountMovements(account).filter { $0.date >= since }.map { movement in
            FinancialEngine.ReconciliationRow(identity: movement.operation.identity, deltaKopecks: movement.delta, date: movement.date,
                                              pending: FinancialEngine.isPendingStatus(movement.operation.status),
                                              payee: FinancialEngine.counterpartyKey(movement.operation.description))
        }
    }
}

struct AccountMovement: Identifiable {
    let operation: BankOperation
    let date: Date
    let delta: Int64
    var id: String { operation.identity }
}

extension SavedHistory {
    /// Every operation that moves `account`, counted exactly as `Account.balance` counts it, newest first:
    /// for the scanned card — bank rows from its start date (without cancelled rows and without the Save side of
    /// card ↔ Save transfers); for other accounts — manual entries from its start date.
    func accountMovements(_ account: Account, includingBeforeStart: Bool = false) -> [AccountMovement] {
        var result: [AccountMovement] = []
        if account.tracksBankCard {
            let inputs = operations.map(\.financialInput)
            let otherAccountRows = FinancialEngine.saveSidePairRows(inputs)
            for (index, operation) in operations.enumerated() {
                let input = inputs[index]
                guard !FinancialEngine.isNotCardSide(input), !otherAccountRows.contains(index),
                      let date = BankDateParser.parse(operation.occurredAt), includingBeforeStart || date >= account.startDate,
                      FinancialEngine.classify(input).type != .cancelled else { continue }
                result.append(AccountMovement(operation: operation, date: date, delta: operation.amountKopecks))
            }
        } else if account.tracksSave == true {
            // The Save account: its own rows of the bank history, seen from Save.
            let inputs = operations.map(\.financialInput)
            let otherAccountRows = FinancialEngine.saveSidePairRows(inputs)
            for (index, operation) in operations.enumerated() {
                let input = inputs[index]
                guard FinancialEngine.isSaveSide(input) || otherAccountRows.contains(index),
                      let date = BankDateParser.parse(operation.occurredAt), includingBeforeStart || date >= account.startDate,
                      FinancialEngine.classify(input).type != .cancelled else { continue }
                result.append(AccountMovement(operation: operation, date: date, delta: operation.amountKopecks))
            }
        } else {
            for manual in manualOperations ?? [] where includingBeforeStart || manual.date >= account.startDate {
                let delta: Int64
                switch manual.kind {
                case .expense: delta = manual.accountID == account.id ? -manual.amountKopecks : 0
                case .income: delta = manual.accountID == account.id ? manual.amountKopecks : 0
                case .transfer:
                    delta = (manual.accountID == account.id ? -manual.amountKopecks : 0)
                        + (manual.toAccountID == account.id ? manual.amountKopecks : 0)
                }
                if manual.accountID == account.id || (manual.kind == .transfer && manual.toAccountID == account.id) {
                    result.append(AccountMovement(operation: manual.bankOperation, date: manual.date, delta: delta))
                }
            }
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    /// Balance of `account` at each moment (operations strictly before it count); before the start date it is the
    /// entered start balance. The last value for `Date.distantFuture` equals `Account.balance`.
    func accountBalances(_ account: Account, at moments: [Date]) -> [Int64] {
        let movements = accountMovements(account).sorted { $0.date < $1.date }
        return moments.map { moment in
            movements.lazy.filter { $0.date < moment }.reduce(account.startBalanceKopecks) { $0 + $1.delta }
        }
    }

    /// Balance of `account` at each moment, or nil where nothing is known. From the start date on it is the entered
    /// balance moved by the operations since (as `accountBalances`). Before it the balance is worked back from the
    /// entered one through the operations of the scanned card, and only from its first operation on; an account kept
    /// by hand has no known balance before its start date.
    func accountBalancesReconstructed(_ account: Account, at moments: [Date]) -> [Int64?] {
        let movements = accountMovements(account, includingBeforeStart: true).sorted { $0.date < $1.date }
        let firstDate = movements.first?.date
        return moments.map { moment in
            if moment >= account.startDate {
                return movements.lazy.filter { $0.date >= account.startDate && $0.date < moment }.reduce(account.startBalanceKopecks) { $0 + $1.delta }
            }
            guard account.followsBank, let firstDate, moment > firstDate else { return nil }
            return movements.lazy.filter { $0.date >= moment && $0.date < account.startDate }.reduce(account.startBalanceKopecks) { $0 - $1.delta }
        }
    }
}

// MARK: - Confirming what an unnamed incoming operation is

enum ConfirmedNature: String, CaseIterable {
    case income
    case refund
    case own

    var title: String {
        switch self {
        case .income: return "Это доход"
        case .refund: return "Возврат покупки"
        case .own: return "Перемещение между своими счетами"
        }
    }
}

extension SavedHistory {
    func confirmedNature(for operation: BankOperation) -> ConfirmedNature? {
        operationNatures?[operation.identity].flatMap(ConfirmedNature.init(rawValue:))
    }

    /// The owner says what an incoming bank operation is. Only an operation the engine leaves «unknown» takes it;
    /// `nil` takes the confirmation back (and an income category chosen for it, which makes no sense without income).
    @discardableResult
    mutating func confirmNature(_ nature: ConfirmedNature?, for operation: BankOperation) -> Bool {
        guard !operation.isManual else { return false }
        var all = operationNatures ?? [:]
        if let nature {
            guard operation.amountKopecks > 0, FinancialEngine.classify(operation.financialInput).type == .unknown else { return false }
            all[operation.identity] = nature.rawValue
        } else {
            all[operation.identity] = nil
            incomeCategoryOverrides?[operation.identity] = nil
        }
        operationNatures = all.isEmpty ? nil : all
        return true
    }
}

// MARK: - Receipt photos

extension SavedHistory {
    func receiptFiles(forIdentity identity: String) -> [String] { receipts?[identity] ?? [] }

    func hasReceipt(_ operation: BankOperation) -> Bool { !(receipts?[operation.identity] ?? []).isEmpty }

    /// Adds a photo to an operation; a name that is already there, or not made by the app, is ignored.
    mutating func addReceipt(_ file: String, toIdentity identity: String) {
        guard ReceiptLogic.isValid(fileName: file) else { return }
        var all = receipts ?? [:]
        var files = all[identity] ?? []
        guard !files.contains(file) else { return }
        files.append(file)
        all[identity] = files
        receipts = all
    }

    mutating func removeReceipt(_ file: String, fromIdentity identity: String) {
        guard var all = receipts, var files = all[identity] else { return }
        files.removeAll { $0 == file }
        all[identity] = files.isEmpty ? nil : files
        receipts = all.isEmpty ? nil : all
    }

    /// Forgets all photos of an operation (it was deleted) and returns their file names so the files can be removed.
    @discardableResult
    mutating func removeReceipts(forIdentity identity: String) -> [String] {
        setReceiptGoods([], forIdentity: identity)
        setReceiptScan(nil, forIdentity: identity)
        guard var all = receipts, let files = all[identity] else { return [] }
        all[identity] = nil
        receipts = all.isEmpty ? nil : all
        return files
    }

    func receiptGoods(forIdentity identity: String) -> [ReceiptGood] { receiptGoods?[identity] ?? [] }

    /// Keeps only the photo names made by the app (`ReceiptLogic.isValid`); an operation left without photos loses its entry.
    mutating func dropForeignReceiptNames() {
        guard let all = receipts else { return }
        var clean: [String: [String]] = [:]
        for (identity, files) in all {
            let good = files.filter { ReceiptLogic.isValid(fileName: $0) }
            if !good.isEmpty { clean[identity] = good }
        }
        receipts = clean.isEmpty ? nil : clean
    }

    mutating func setReceiptGoods(_ goods: [ReceiptGood], forIdentity identity: String) {
        var all = receiptGoods ?? [:]
        all[identity] = goods.isEmpty ? nil : goods
        receiptGoods = all.isEmpty ? nil : all
    }

    mutating func setReceiptScan(_ scan: ReceiptScan?, forIdentity identity: String) {
        var all = receiptScans ?? [:]
        all[identity] = scan
        receiptScans = all.isEmpty ? nil : all
    }
}

/// A good of a receipt: its name and the final price of its line (after the discount of the line), if it was read.
struct ReceiptGood: Codable, Equatable {
    var name: String
    var kopecks: Int64?

    init(name: String, kopecks: Int64? = nil) {
        self.name = name
        self.kopecks = kopecks
    }

    /// «Молоко — 65,00 ₽» as the owner sees and edits it.
    var line: String { kopecks.map { name + " — " + Self.rubles($0) } ?? name }

    static func rubles(_ kopecks: Int64) -> String {
        let cents = Int(kopecks % 100)
        return "\(kopecks / 100),\(cents < 10 ? "0" : "")\(cents) ₽"
    }

    /// A line of the editor: the name, and after « — » the price. A line without a readable price is a name only.
    init(line raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: " — ", options: .backwards),
           let price = Self.kopecks(String(text[range.upperBound...])) {
            self.init(name: String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces), kopecks: price)
        } else {
            self.init(name: text, kopecks: nil)
        }
    }

    /// «65,00 ₽», «1 299.50», «65» → kopecks.
    static func kopecks(_ text: String) -> Int64? {
        let clean = text.replacingOccurrences(of: "₽", with: "").filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard !clean.isEmpty, parts.count <= 2, parts[0].count <= 9, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }), !parts[0].isEmpty,
              parts.count == 1 || (1...2).contains(parts[1].count), let rubles = Int64(parts[0]) else { return nil }
        let cents = parts.count == 2 ? (Int64(parts[1]) ?? 0) * (parts[1].count == 1 ? 10 : 1) : 0
        return rubles * 100 + cents
    }
}

/// What the phone read from a receipt when it was added.
struct ReceiptScan: Codable, Equatable {
    var scannedAt: Date
    var readLines: [String]
    var totalKopecks: Int64?
    var date: Date?
    var merchant: String?
    var goods: [ReceiptGood]
    /// False when the date was read but not the time.
    var dateHasTime: Bool
}

/// Receipt photos are files in the app's own folder; these rules are the only place that decides how they look.
enum ReceiptLogic {
    struct ReceiptRestoreResult: Equatable {
        var added = 0
        var alreadyExisted = 0
        var damaged = 0
        var notWritten = 0

        var message: String {
            if added == 0 && alreadyExisted == 0 && damaged == 0 && notWritten == 0 { return "В архиве нет фото чеков" }
            if alreadyExisted == 0 && damaged == 0 && notWritten == 0 { return "Добавлено \(added) фото" }
            if added == 0 && damaged == 0 && notWritten == 0 { return "Все \(alreadyExisted) фото уже были" }
            var parts: [String] = []
            if added > 0 { parts.append("добавлено \(added)") }
            if alreadyExisted > 0 { parts.append("уже было \(alreadyExisted)") }
            if damaged > 0 { parts.append("не удалось прочитать \(damaged)") }
            if notWritten > 0 { parts.append("не удалось записать \(notWritten)") }
            let text = parts.joined(separator: ", ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    /// Files of photos that no operation points to (a form closed without saving, an operation deleted by an older version).
    static func orphanFiles(all: [String], referenced: [String: [String]]?) -> [String] {
        let used = Set((referenced ?? [:]).values.flatMap { $0 })
        return all.filter { !used.contains($0) }.sorted()
    }

    static func exportMessage(saved: Int, skipped: Int) -> String {
        if saved == 0 { return skipped > 0 ? "Не удалось прочитать \(skipped) фото. Архив не сохранён." : "Фото чеков на этом телефоне пока нет." }
        let message = "Архив сохранён: \(saved) фото."
        return skipped > 0 ? message + " Пропущено: \(skipped) (не удалось прочитать)." : message
    }

    /// The longest side of a stored photo: enough to read a receipt, small enough (about 300 KB) to keep many.
    static let maxSide = 1600.0
    /// A PDF becomes pictures of its first pages only.
    static let maxPagesPerDocument = 5

    static func fileName(id: UUID = UUID()) -> String { "receipt-\(id.uuidString.lowercased()).jpg" }

    /// Only names made by `fileName` are used for files: a name from a restored backup can never point elsewhere.
    static func isValid(fileName: String) -> Bool {
        fileName.range(of: "^receipt-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.jpg$", options: .regularExpression) != nil
    }

    /// The size of a photo fitted into `maxSide`, never enlarged.
    static func scaledSize(width: Double, height: Double) -> (width: Double, height: Double) {
        let longest = max(width, height)
        guard longest > maxSide, longest > 0 else { return (width, height) }
        let factor = maxSide / longest
        return ((width * factor).rounded(), (height * factor).rounded())
    }
}

// MARK: - App lock

/// The rules of the app lock that do not need the system: what a code is, how long the pauses after wrong codes are
/// and when the app asks for the code again.
enum AppLockLogic {
    /// Wrong codes in a row before the first pause.
    static let attemptsBeforePause = 5

    static func isValid(pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// The pause after this many wrong codes in a row: none before the fifth, then 30 s, 1 min, 5 min, 15 min.
    static func lockoutSeconds(afterFailures failures: Int) -> Int {
        if failures < attemptsBeforePause { return 0 }
        if failures == attemptsBeforePause { return 30 }
        if failures == attemptsBeforePause + 1 { return 60 }
        if failures == attemptsBeforePause + 2 { return 300 }
        return 900
    }

    /// The app locks when it was away for `afterSeconds` or longer; a clock set back counts as being away too.
    /// A negative `afterSeconds` means «only at launch»: coming back from the background never asks for the code.
    static func shouldLock(backgroundedAt: Date, now: Date, afterSeconds: Int) -> Bool {
        if afterSeconds < 0 { return false }
        let away = now.timeIntervalSince(backgroundedAt)
        return away < 0 || away >= Double(afterSeconds)
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
        // Fractions of a second are kept: an account's balance starts from an exact moment.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            // The format cuts the milliseconds off (…00.9 would be written as …00.899): half a millisecond is added first.
            try container.encode(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true).format(date.addingTimeInterval(0.0005)))
        }
        return try encoder.encode(Envelope(format: formatVersion, exportedAt: exportedAt, history: history))
    }

    static func decode(_ data: Data) throws -> SavedHistory {
        let decoder = JSONDecoder()
        // Copies made before 46.7 hold whole seconds only; both forms open.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = BankDateParser.parse(text) { return date }
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Не дата: \(text)"))
        }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            throw AppFailure(message: "Это не резервная копия Horizon или файл повреждён.")
        }
        guard envelope.format <= formatVersion else {
            throw AppFailure(message: "Копия сделана более новой версией приложения. Обновите приложение и повторите.")
        }
        // A copy from outside may name any file: only the names the app itself makes are kept (never «../» or a folder).
        var history = envelope.history
        history.dropForeignReceiptNames()
        return history
    }
}

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Budgets (stage 46)

/// A spending limit for a month: for one group of expenses or, with `group == nil`, for all expenses of the month.
struct Budget: Codable, Equatable, Identifiable {
    var id = UUID()
    /// A group name of the user's tree (`SavedHistory.categoryTree`); nil: the whole month.
    var group: String?
    var limitKopecks: Int64
    /// nil: the limit of every month. «yyyy-MM»: that month only; it wins over the limit of every month.
    var month: String?

    /// The largest amount the budgets work with: 10 trillion rubles in kopecks. Nothing real is larger, and the
    /// arithmetic on it (× 100) always fits into Int64.
    static let largestAmount: Int64 = 1_000_000_000_000_000
}

extension SavedHistory {
    /// Sets the limit of a group (nil: the whole month) for every month or for one month ("yyyy-MM").
    /// An amount that is not positive is refused and nothing changes.
    @discardableResult
    mutating func setBudget(group: String?, limitKopecks: Int64, month: String?) -> Bool {
        guard limitKopecks > 0, limitKopecks <= Budget.largestAmount else { return false }
        var all = budgets ?? []
        if let index = all.firstIndex(where: { $0.group == group && $0.month == month }) {
            all[index].limitKopecks = limitKopecks
        } else {
            all.append(Budget(group: group, limitKopecks: limitKopecks, month: month))
        }
        budgets = all
        return true
    }

    /// Removes one limit; a limit of one month leaves the limit of every month in place.
    mutating func removeBudget(group: String?, month: String?) {
        var all = budgets ?? []
        all.removeAll { $0.group == group && $0.month == month }
        budgets = all.isEmpty ? nil : all
    }
}
