import Foundation

/// What is read from a receipt: the sum, the date and the shop. A field that could not be read stays empty.
struct ParsedReceipt: Equatable {
    var totalKopecks: Int64?
    var date: Date?
    var merchant: String?
    /// The rows the phone read from the pictures, top to bottom: shown in the form so that a wrong reading can be seen.
    var readLines: [String] = []

    var isEmpty: Bool { totalKopecks == nil && date == nil && merchant == nil }
}

/// Reading a receipt: the QR code of a Russian cash receipt (date and sum, exact) and the printed text (the same, less
/// sure, and the shop). Pure text and numbers, no camera: it is checked by tests on the PC.
enum ReceiptParser {
    // MARK: Money

    /// Sums written with two decimals: «1 234,56», «1234.56». The thousands may be separated by a space.
    static func amounts(in line: String) -> [Int64] {
        var result: [Int64] = []
        let pattern = #"(?<![\d.,])(\d{1,3}(?:[  ]\d{3})+|\d+)[.,](\d{2})(?!\d)"#
        for groups in matches(pattern, in: line) where groups.count == 2 {
            let whole = groups[0].filter { $0.isNumber }
            guard whole.count <= 9, let rubles = Int64(whole), let cents = Int64(groups[1]) else { continue }
            result.append(rubles * 100 + cents)
        }
        if result.isEmpty {
            // «1500 руб», «1 500 ₽»
            let whole = #"(?<![\d.,])(\d{1,3}(?:[  ]\d{3})+|\d+)\s*(?:₽|руб|р\b)"#
            for groups in matches(whole, in: line) where groups.count == 1 {
                let digits = groups[0].filter { $0.isNumber }
                if digits.count <= 9, let rubles = Int64(digits) { result.append(rubles * 100) }
            }
        }
        return result
    }

    /// «175.50» or «175,5» → kopecks.
    static func kopecks(fromDecimal text: String) -> Int64? {
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty, whole.count <= 9, whole.allSatisfy({ $0.isNumber }),
              let rubles = Int64(whole) else { return nil }
        var cents: Int64 = 0
        if parts.count == 2 {
            let fraction = String(parts[1])
            guard fraction.count <= 2, fraction.allSatisfy({ $0.isNumber }) else { return nil }
            cents = Int64(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        }
        return rubles * 100 + cents
    }

    // MARK: QR code of a cash receipt

    /// «t=20261008T1425&s=175.50&fn=…&i=…&fp=…&n=1»: nil when the text is not a receipt.
    static func parseQR(_ payload: String, calendar: Calendar = .current) -> ParsedReceipt? {
        var fields: [String: String] = [:]
        for part in payload.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0]).lowercased()] = String(pair[1]) }
        }
        guard fields["fn"] != nil, let when = fields["t"], let sum = fields["s"] else { return nil }
        var receipt = ParsedReceipt()
        receipt.totalKopecks = kopecks(fromDecimal: sum)
        let digits = when.filter { $0.isNumber }
        if digits.count == 12 || digits.count == 14 {
            let n = Array(digits).map { Int(String($0)) ?? 0 }
            func number(_ from: Int, _ count: Int) -> Int { n[from..<(from + count)].reduce(0) { $0 * 10 + $1 } }
            receipt.date = makeDate(year: number(0, 4), month: number(4, 2), day: number(6, 2), hour: number(8, 2), minute: number(10, 2),
                                    second: digits.count == 14 ? number(12, 2) : 0, calendar: calendar)
        }
        return receipt.isEmpty ? nil : receipt
    }

    // MARK: Printed text

    /// The lines of a receipt from top to bottom, as they were read.
    static func parseText(_ lines: [String], now: Date = Date(), calendar: Calendar = .current) -> ParsedReceipt {
        ParsedReceipt(totalKopecks: total(in: lines), date: date(in: lines, now: now, calendar: calendar), merchant: merchant(in: lines))
    }

    /// The QR code is exact for the sum and the date; the text gives what it lacks and the shop.
    static func merge(qr: ParsedReceipt?, text: ParsedReceipt) -> ParsedReceipt {
        ParsedReceipt(totalKopecks: qr?.totalKopecks ?? text.totalKopecks, date: qr?.date ?? text.date, merchant: text.merchant)
    }

    /// What is looked for, in order: the sum to pay, what was paid by card (it is what the bank charges), the total.
    private static let totalKeywords: [[String]] = [["к оплате"], ["безналичн"], ["итого", "итог"], ["сумма"], ["всего", "total"]]
    /// «скидок» (in «итог без скидок») has other letters than «скидк»: both are listed.
    private static let notATotal = ["ндс", "налог", "скидк", "скидок", "без скид", "до скид", "бонус", "сдач", "наличн", "получен", "аванс", "налич"]

    static func total(in lines: [String]) -> Int64? {
        for keywords in totalKeywords {
            // «Paid by card» holds the word «налич» itself; the totals are searched from the end: the last «ИТОГ» is the one
            // after the discounts.
            let isCard = keywords == ["безналичн"]
            let fromEnd = keywords.contains("итог")
            let order = fromEnd ? Array(lines.indices.reversed()) : Array(lines.indices)
            for index in order {
                let lower = lines[index].lowercased()
                guard keywords.contains(where: { lower.contains($0) }), isCard || !notATotal.contains(where: { lower.contains($0) }) else { continue }
                var found = amounts(in: lines[index])
                if found.isEmpty, index + 1 < lines.count { found = amounts(in: lines[index + 1]) }
                if let best = found.max(), best > 0 { return best }
            }
        }
        return nil
    }

    /// The first valid date; its time is on the same line or next to it. A date from the future is not a receipt date.
    static func date(in lines: [String], now: Date, calendar: Calendar) -> Date? {
        let datePattern = #"(?<!\d)(\d{1,2})\s?[./-]\s?(\d{1,2})\s?[./-]\s?(\d{4}|\d{2})(?!\d)"#
        let isoPattern = #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#
        let timePattern = #"(?<!\d)([01]?\d|2[0-3])\s?:\s?([0-5]\d)(?:\s?:\s?[0-5]\d)?(?!\d)"#
        let limit = now.addingTimeInterval(86_400)
        for (index, line) in lines.enumerated() {
            var parts: (year: Int, month: Int, day: Int)?
            if let g = matches(isoPattern, in: line).first, g.count == 3 {
                parts = (Int(g[0]) ?? 0, Int(g[1]) ?? 0, Int(g[2]) ?? 0)
            } else if let g = matches(datePattern, in: line).first, g.count == 3 {
                let year = Int(g[2]) ?? 0
                parts = (g[2].count == 2 ? 2000 + year : year, Int(g[1]) ?? 0, Int(g[0]) ?? 0)
            }
            guard let parts, parts.year >= 2000 else { continue }
            var time: (Int, Int)?
            for neighbour in [index, index + 1, index - 1] where neighbour >= 0 && neighbour < lines.count {
                if let g = matches(timePattern, in: lines[neighbour]).first, g.count == 2 {
                    time = (Int(g[0]) ?? 0, Int(g[1]) ?? 0)
                    break
                }
            }
            let hasTime = time != nil
            var date = makeDate(year: parts.year, month: parts.month, day: parts.day, hour: time?.0 ?? 12, minute: time?.1 ?? 0, calendar: calendar)
            // Without a time on a receipt of today the moment of reading is the better guess.
            if !hasTime, let day = date, calendar.isDate(day, inSameDayAs: now) { date = now }
            if let date, date <= limit { return min(date, now) }
        }
        return nil
    }

    private static let skippedLines = ["кассовый", "чек", "добро пожаловать", "приход", "товарный", "спасибо", "ккт", "смена", "инн",
                                       "тел.", "тел:", "tel", "www", "http", "касс", "адрес", "продажа", "оплата", "сайт", "email", "e-mail"]
    private static let chains: [(contains: String, name: String)] = [("тандер", "Магнит"), ("агроторг", "Пятёрочка")]

    /// The first line of the top of the receipt that looks like the name of a shop.
    static func merchant(in lines: [String]) -> String? {
        for raw in lines.prefix(8) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            let letters = line.filter { $0.isLetter }.count
            let digits = line.filter { $0.isNumber }.count
            guard letters >= 3, digits <= 2, !skippedLines.contains(where: { lower.contains($0) }),
                  !lower.contains("ул.") , !lower.hasPrefix("г.") , !lower.contains("пр-т"), !lower.contains("д.") else { continue }
            if let chain = chains.first(where: { lower.contains($0.contains) }) { return chain.name }
            return cleanMerchant(line)
        }
        return nil
    }

    static func cleanMerchant(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ООО", "ОАО", "ЗАО", "ПАО", "АО", "ИП"] where text.uppercased().hasPrefix(prefix + " ") || text.uppercased().hasPrefix(prefix + "\"") || text.uppercased().hasPrefix(prefix + "«") {
            text = String(text.dropFirst(prefix.count))
            break
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"«»“”'`.,:;-"))
        if text.uppercased() == text, text.contains(where: { $0.isLetter }) { text = text.lowercased().capitalized }
        return text
    }

    // MARK: Category guess by words

    /// A group and a category of the built-in tree by words of the shop name; the caller keeps it only if the user's
    /// tree has it.
    static func keywordCategory(merchant: String, text: String = "") -> (group: String, subcategory: String)? {
        let haystack = (merchant + " " + text).lowercased()
        let table: [(words: [String], group: String, subcategory: String)] = [
            (["магнит", "пятероч", "пятёроч", "перекрест", "перекрёст", "лента", "ашан", "дикси", "вкусвилл", "азбука вкуса", "окей",
              "spar", "продукт", "гастроном", "супермаркет", "хлеб"], "Еда", "Супермаркеты"),
            (["кафе", "ресторан", "кофе", "пицц", "бургер", "суши", "столов", "пекарн", "шаурм", "kfc", "mcdonald", "макдоналдс",
              "вкусно и точка"], "Еда", "Кафе и рестораны"),
            (["азс", "бензин", "топлив", "лукойл", "газпромнефть", "роснефть", "shell", "татнефть"], "Транспорт", "Топливо"),
            (["такси"], "Транспорт", "Такси"),
            (["аптек", "ригла", "планета здоровья", "горздрав"], "Обязательные", "Здоровье"),
            (["леруа", "касторама", "икеа", "hoff", "хозтовар"], "Покупки", "Дом и быт"),
            (["днс", "dns", "м.видео", "эльдорадо", "ситилинк"], "Покупки", "Электроника"),
            (["одежд", "обув", "спортмастер", "zara", "h&m"], "Покупки", "Одежда"),
        ]
        for row in table where row.words.contains(where: { haystack.contains($0) }) { return (row.group, row.subcategory) }
        return nil
    }

    // MARK: Helpers

    private static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0, calendar: Calendar) -> Date? {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return back.year == year && back.month == month && back.day == day && back.hour == hour && back.minute == minute && back.second == second ? date : nil
    }

    /// The capture groups of every match of the pattern.
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }
}

// MARK: - What a recognised receipt may fill in the form of a manual operation

extension SavedHistory {
    /// The category for a purchase in this shop: the rule of the user, then the category of the latest earlier operation
    /// with the same payee, then words of the name (only if the user's tree has that category).
    func suggestedExpenseCategory(forMerchant merchant: String, text: String = "") -> (group: String, subcategory: String)? {
        let key = FinancialEngine.payeeRuleKey(merchant)
        if !key.isEmpty {
            if let rule = categoryRules?.first(where: { $0.payeeKey == key }), let pair = expenseCategory(id: rule.categoryID) {
                return (pair.group.name, pair.category.name)
            }
            var latest: (date: Date, operation: BankOperation)?
            for operation in operations where FinancialEngine.payeeRuleKey(operation.description) == key {
                guard let when = BankDateParser.parse(operation.occurredAt) else { continue }
                if latest == nil || when > latest!.date { latest = (when, operation) }
            }
            if let operation = latest?.operation, let id = expenseCategoryID(for: operation), let pair = expenseCategory(id: id) {
                return (pair.group.name, pair.category.name)
            }
        }
        if let guess = ReceiptParser.keywordCategory(merchant: merchant, text: text),
           categoryTree.contains(where: { $0.name == guess.group && $0.categories.contains { $0.name == guess.subcategory } }) {
            return guess
        }
        return nil
    }

    /// The account of the latest manual operation, if it still exists and is kept by hand.
    var lastManualAccountID: UUID? {
        guard let id = manualOperations?.last(where: { $0.accountID != nil })?.accountID,
              (accounts ?? []).contains(where: { $0.id == id && !$0.followsBank }) else { return nil }
        return id
    }
}
