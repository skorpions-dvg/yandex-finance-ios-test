import Foundation
import CryptoKit

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
    var id: String { SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() }
    var formattedAmount: String {
        let value = Decimal(amountKopecks) / 100
        return value.formatted(.currency(code: currency))
    }
}



extension BankOperation {
    var financialInput: FinancialOperationInput {
        FinancialOperationInput(occurredAt: occurredAt, description: description, amountKopecks: amountKopecks,
                                status: status, category: category, purpose: purpose, providers: providers, kind: kind,
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
}

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
