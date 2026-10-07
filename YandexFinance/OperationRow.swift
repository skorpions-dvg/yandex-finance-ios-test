import SwiftUI

/// SF Symbols offered for accounts and for the user's own look of an operation, grouped by theme.
enum AppSymbols {
    static let all: [(symbol: String, name: String)] = [
        // Money, cards and banks
        ("creditcard", "Карта"), ("creditcard.fill", "Карта"), ("building.columns", "Банк"), ("wallet.pass", "Кошелёк"),
        ("banknote", "Наличные"), ("dollarsign.circle", "Доллары"), ("eurosign.circle", "Евро"), ("rublesign.circle", "Рубли"),
        ("bitcoinsign.circle", "Криптовалюта"), ("lock.shield", "Сейф"), ("envelope", "Конверт"), ("chart.line.uptrend.xyaxis", "Инвестиции"),
        ("percent", "Проценты"), ("arrow.left.arrow.right", "Перевод"),
        // Goals
        ("house", "Дом"), ("car", "Автомобиль"), ("airplane", "Путешествие"), ("gift", "Подарок"), ("heart", "Сердце"),
        ("star", "Звезда"), ("flag", "Цель"), ("graduationcap", "Учёба"), ("figure.and.child.holdinghands", "Семья"),
        ("pawprint", "Питомец"), ("leaf", "Природа"), ("sun.max", "Отпуск"), ("bicycle", "Велосипед"), ("sailboat", "Лодка"),
        // Work and income
        ("briefcase", "Работа"), ("laptopcomputer", "Ноутбук"), ("hammer", "Инструменты"), ("wrench.and.screwdriver", "Ремонт"),
        // Everyday spending
        ("cart", "Покупки"), ("bag", "Сумка"), ("fork.knife", "Еда"), ("cup.and.saucer", "Кофе"), ("takeoutbag.and.cup.and.straw", "Доставка"),
        ("fuelpump", "Топливо"), ("bus", "Транспорт"), ("tram", "Метро"), ("phone", "Связь"), ("wifi", "Интернет"),
        ("tv", "Подписки"), ("gamecontroller", "Игры"), ("figure.run", "Спорт"), ("cross.case", "Здоровье"), ("pills", "Аптека"),
        ("tshirt", "Одежда"), ("scissors", "Красота"), ("book", "Книги"), ("music.note", "Музыка"), ("film", "Кино"),
        ("ticket", "Билеты"), ("bolt", "Электричество"), ("drop", "Вода"), ("shippingbox", "Посылки"), ("questionmark.circle", "Прочее"),
    ]
}

/// One operation in a list: category icon, title, category and status, signed amount.
struct OperationRow: View {
    let operation: BankOperation
    var input: FinancialOperationInput? = nil
    /// Adds the operation date to the subtitle, for lists that are not grouped by day.
    var showsDate = false
    /// The user's own title and icon, if any.
    var look: OperationLook? = nil
    /// Presentation override for an account report; other lists keep the original bank amount.
    var displayedAmountKopecks: Int64? = nil
    /// A paperclip after the title when the operation has a photo of its receipt.
    var hasReceipt = false

    var body: some View {
        let style = Self.icon(for: operation, input: input)
        HStack(spacing: 12) {
            Image(systemName: look?.icon ?? style.name)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(style.color, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(look?.title ?? operation.description)
                        .lineLimit(1)
                    if hasReceipt {
                        Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(displayedAmount)
                .foregroundStyle(displayedAmountKopecks.map { $0 > 0 ? Color.green : ($0 < 0 ? Color.primary : Color.secondary) }
                                 ?? Self.amountColor(for: operation))
        }
    }

    private var displayedAmount: String {
        guard let amount = displayedAmountKopecks else { return operation.formattedAmount }
        let prefix = amount > 0 ? "+" : ""
        return prefix + (Decimal(amount) / 100).formatted(.currency(code: operation.currency))
    }

    private var subtitle: String {
        var parts: [String] = []
        // The user's comment comes first, then the usual date and category.
        if let note = look?.note { parts.append(note) }
        if showsDate, let date = BankDateParser.parse(operation.occurredAt) {
            parts.append(date.formatted(.dateTime.day().month().year()))
        }
        let resolvedInput = input ?? operation.financialInput
        let assessment = FinancialEngine.classify(resolvedInput)
        if assessment.type == .expense || assessment.type == .commission {
            parts.append(FinancialEngine.expenseCategory(for: resolvedInput, assessment: assessment).subcategory)
        } else { parts.append(operation.category) }
        if operation.isManual { parts.append("Вручную") }
        else if operation.status != "Выполнено" { parts.append(operation.status) }
        return parts.joined(separator: " · ")
    }

    static func icon(for operation: BankOperation, input: FinancialOperationInput? = nil) -> (name: String, color: Color) {
        let resolvedInput = input ?? operation.financialInput
        let assessment = FinancialEngine.classify(resolvedInput)
        switch assessment.type {
        case .income, .interestIncome: return ("arrow.down", .green)
        case .refund: return ("arrow.uturn.backward", .green)
        case .internalTransfer: return ("arrow.left.arrow.right", .gray)
        case .split: return ("creditcard", .indigo)
        case .pending: return ("clock", .gray)
        case .cancelled: return ("xmark", .gray)
        case .unknown: return ("questionmark", .gray)
        case .expense, .commission:
            return expenseGroupIcon(FinancialEngine.expenseCategory(for: resolvedInput, assessment: assessment).group)
        }
    }

    static func expenseGroupIcon(_ group: String) -> (name: String, color: Color) {
        switch group {
        case "Еда": return ("fork.knife", .orange)
        case "Транспорт": return ("car.fill", .blue)
        case "Покупки": return ("bag.fill", .purple)
        case "Обязательные": return ("house.fill", .teal)
        case "Переводы": return ("person.2.fill", .indigo)
        default: return ("square.grid.2x2.fill", .gray)
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
