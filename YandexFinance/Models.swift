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
}

struct AccountGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
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
