import SwiftUI

/// One operation in a list: category icon, title, category and status, signed amount.
struct OperationRow: View {
    let operation: BankOperation
    /// Adds the operation date to the subtitle, for lists that are not grouped by day.
    var showsDate = false

    var body: some View {
        let style = Self.icon(for: operation)
        HStack(spacing: 12) {
            Image(systemName: style.name)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(style.color, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.description)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(operation.formattedAmount)
                .foregroundStyle(Self.amountColor(for: operation))
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsDate, let date = BankDateParser.parse(operation.occurredAt) {
            parts.append(date.formatted(.dateTime.day().month().year()))
        }
        parts.append(operation.category)
        if operation.status != "Выполнено" { parts.append(operation.status) }
        return parts.joined(separator: " · ")
    }

    static func icon(for operation: BankOperation) -> (name: String, color: Color) {
        switch operation.financialAssessment.type {
        case .income, .interestIncome: return ("arrow.down", .green)
        case .refund: return ("arrow.uturn.backward", .green)
        case .internalTransfer: return ("arrow.left.arrow.right", .gray)
        case .split: return ("creditcard", .indigo)
        case .pending: return ("clock", .gray)
        case .cancelled: return ("xmark", .gray)
        case .unknown: return ("questionmark", .gray)
        case .expense, .commission:
            switch FinancialEngine.expenseCategory(for: operation.financialInput, assessment: operation.financialAssessment).group {
            case "Еда": return ("fork.knife", .orange)
            case "Транспорт": return ("car.fill", .blue)
            case "Покупки": return ("bag.fill", .purple)
            case "Обязательные": return ("house.fill", .teal)
            default: return ("square.grid.2x2.fill", .gray)
            }
        }
    }

    static func amountColor(for operation: BankOperation) -> Color {
        switch operation.financialAssessment.type {
        case .income, .interestIncome, .refund: return .green
        case .pending, .cancelled, .internalTransfer, .split, .unknown: return .secondary
        default: return .primary
        }
    }
}
