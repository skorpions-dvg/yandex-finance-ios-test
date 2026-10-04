import Foundation
import CryptoKit

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
    var id: String { SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() }
    var formattedAmount: String {
        let value = Decimal(amountKopecks) / 100
        return value.formatted(.currency(code: currency))
    }
}

struct ImportBatch: Codable {
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
    let count: Int
}

struct SavedHistory: Codable {
    var operations: [BankOperation] = []
    var lastSync: Date?
    var lastStopReason: String?
}

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
