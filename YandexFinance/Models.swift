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
                                componentAmountsKopecks: components?.map(\.amountKopecks) ?? [])
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
    /// Expense: one of `FinancialEngine.expenseGroupOrder`; income: nil.
    var group: String?
    /// Expense: one of `FinancialEngine.expenseSubcategoryOrder`; income: one of `FinancialEngine.incomeSubcategoryOrder`.
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
