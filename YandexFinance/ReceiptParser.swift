import Foundation

/// What is read from a receipt: the sum, the date and the shop. A field that could not be read stays empty.
struct ParsedReceipt: Equatable {
    var totalKopecks: Int64?
    var date: Date?
    var merchant: String?
    /// The goods of the receipt with the final price of each line: the owner corrects them in the form.
    var goods: [ReceiptGood] = []
    /// The rows the phone read, top to bottom: kept with the operation for the check of the reading, never shown in the form.
    var readLines: [String] = []
    /// False when a date was read but no time with it (then the date is a guess for the time of day).
    var dateHasTime = true
    /// The date and time come from the QR code: exact, unlike the printed text, where a digit may be misread.
    var dateFromQR = false
    /// How the receipt was read (the QR code found or not, the pass that was taken, the time read again): for the check of the
    /// reading in «Собрать чеки для проверки», never shown in the form.
    var readingNotes: [String] = []

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
        let found = dateAndTime(in: lines, now: now, calendar: calendar)
        let sum = total(in: lines)
        return ParsedReceipt(totalKopecks: sum, date: found?.date, merchant: merchant(in: lines), goods: itemEntries(in: lines, expectedTotal: sum),
                             dateHasTime: found?.hasTime ?? true)
    }

    /// The QR code is exact for the sum and the date; the text gives what it lacks and the shop.
    static func merge(qr: ParsedReceipt?, text: ParsedReceipt) -> ParsedReceipt {
        ParsedReceipt(totalKopecks: qr?.totalKopecks ?? text.totalKopecks, date: qr?.date ?? text.date, merchant: text.merchant, goods: text.goods,
                      dateHasTime: qr?.date != nil ? true : text.dateHasTime, dateFromQR: qr?.date != nil)
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
            // Two or more lines of payment by card are parts of one total (two cards): the explicit total below decides.
            if isCard, lines.filter({ $0.lowercased().contains("безналичн") && !amounts(in: $0).isEmpty }).count >= 2 { continue }
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
        dateAndTime(in: lines, now: now, calendar: calendar)?.date
    }

    /// The date of the receipt and whether a time was read with it.
    static func dateAndTime(in lines: [String], now: Date, calendar: Calendar) -> (date: Date, hasTime: Bool)? {
        let datePattern = #"(?<!\d)(\d{1,2})\s?[./-]\s?(\d{1,2})\s?[./-]\s?(\d{4}|\d{2})(?!\d)"#
        let isoPattern = #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#
        let timePattern = #"(?<!\d)([01]?\d|2[0-3])\s?:\s?([0-5]\d)(?:\s?:\s?[0-5]\d)?(?!\d)"#
        let limit = now.addingTimeInterval(86_400)
        for (index, rawLine) in lines.enumerated() {
            let line = digitsFixed(rawLine)
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
                if let g = matches(timePattern, in: digitsFixed(lines[neighbour])).first, g.count == 2 {
                    time = (Int(g[0]) ?? 0, Int(g[1]) ?? 0)
                    break
                }
            }
            let hasTime = time != nil
            var date = makeDate(year: parts.year, month: parts.month, day: parts.day, hour: time?.0 ?? 12, minute: time?.1 ?? 0, calendar: calendar)
            // Without a time on a receipt of today the moment of reading is the better guess.
            if !hasTime, let day = date, calendar.isDate(day, inSameDayAs: now) { date = now }
            if let date, date <= limit { return (min(date, now), hasTime) }
        }
        return nil
    }

    /// The date of the receipt after the row of the date was read once more, alone and so larger (Gemini, 9 Oct). Only what the
    /// first reading lacks is taken: a date when none was read, a time for the same day; a re-read that gives another day changes
    /// nothing (one of the two readings is wrong, and the owner is asked to set the time anyway). nil keeps the first reading.
    static func refinedDate(first: (date: Date, hasTime: Bool)?, reread: (date: Date, hasTime: Bool)?,
                            calendar: Calendar = .current) -> (date: Date, hasTime: Bool, note: String)? {
        guard let reread else { return nil }
        guard let first else { return (reread.date, reread.hasTime, "дата дочитана по строке даты") }
        guard !first.hasTime else { return nil }
        guard calendar.isDate(first.date, inSameDayAs: reread.date) else { return nil }
        guard reread.hasTime else { return nil }
        return (reread.date, true, "время дочитано по строке даты")
    }

    /// A printed date and time are read with digits taken for letters («D8.10.26», «l8:37»): inside a token of digits and
    /// separators D, O → 0, I, l → 1, S → 5, B → 8.
    static func digitsFixed(_ line: String) -> String {
        let pattern = #"(?<!\p{L})[\dDOoIlSB]{1,4}(?:[./:\-][\dDOoIlSB]{1,4})+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        var result = ""
        var cursor = line.startIndex
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line) else { continue }
            result += line[cursor..<range.lowerBound]
            result += line[range].map { character -> Character in
                switch character {
                case "D", "O", "o": return "0"
                case "I", "l": return "1"
                case "S": return "5"
                case "B": return "8"
                default: return character
                }
            }
            cursor = range.upperBound
        }
        return result + line[cursor...]
    }

    private static let skippedLines = ["кассовый", "чек", "добро пожаловать", "приход", "товарный", "спасибо", "ккт", "смена", "инн",
                                       "цена", "кол-во", "итог",
                                       "тел.", "тел:", "tel", "www", "http", "касс", "адрес", "продажа", "оплата", "сайт", "email", "e-mail"]
    private static let chains: [(contains: String, name: String)] = [("тандер", "Магнит"), ("агроторг", "Пятёрочка")]
    /// Shops known by their name anywhere on the receipt (the head of the table or the logo may be read badly).
    private static let namedChains: [(words: [String], name: String)] = [
        (["магнит", "тандер"], "Магнит"), (["пятёрочка", "пятерочка", "агроторг"], "Пятёрочка"),
        (["перекрёсток", "перекресток"], "Перекрёсток"), (["ашан"], "Ашан"), (["дикси"], "Дикси"),
        (["вкусвилл"], "ВкусВилл"), (["лукойл"], "Лукойл"), (["спар "], "Spar"),
    ]

    /// The first line of the top of the receipt that looks like the name of a shop.
    static func merchant(in lines: [String]) -> String? {
        for line in lines {
            let lower = line.lowercased()
            if let chain = namedChains.first(where: { $0.words.contains(where: { lower.contains($0) }) }) { return chain.name }
        }
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

    // MARK: Goods

    /// The goods of a receipt: the lines between the head of the table and the first line of totals, without prices,
    /// quantities and codes. A best effort on a printed text that is often read badly: the owner sees the result and
    /// corrects it.
    static func items(in lines: [String]) -> [String] { itemEntries(in: lines).map(\.name) }

    /// The goods with the final price of the line: the last sum on the line of the good or on the line of figures after it.
    /// With `expectedTotal` (the total of the receipt) prices that do not add up to it are repaired where the figures to repair
    /// them are in the text (`reconcilePrices`).
    static func itemEntries(in lines: [String], expectedTotal: Int64? = nil) -> [ReceiptGood] {
        let endWords = ["итого", "итог", "к оплате", "безналичн", "карта", "карту", "бонус", "причин", "извин", "неудобств", "горяч",
                        "скидка", "ндс", "наличн", "сдача", "всего"]
        let serviceWords = ["кассир", "смена", "ккт", "инн", "спасибо", "место расчет", "адрес", "тел.", "тел:", "чек", "приход", "www", "http"]
        func letters(_ line: String) -> Int { line.filter { $0.isLetter }.count }
        var start = 0
        if let header = lines.firstIndex(where: { line in
            let lower = line.lowercased()
            return lower.contains("цена") && (lower.contains("кол") || lower.contains("итог") || lower.contains("сумма"))
        }) {
            start = header + 1
        } else if let firstPrice = lines.firstIndex(where: { !amounts(in: $0).isEmpty }) {
            start = (letters(lines[firstPrice]) < 3 && firstPrice > 0) ? firstPrice - 1 : firstPrice
        } else {
            return []
        }
        // A good is its name line and the lines of figures after it up to the next name. In a photo taken at an angle the right
        // column of sums can land on the name line and a row of figures can stick to the next name: all the sums of the band
        // are gathered, and `lineTotal` picks the one that is the total of this line.
        var names: [String] = []
        var bands: [[Int64]] = []
        /// Lines that repeat the line before them: the same good read twice, or two equal goods; the total decides below.
        var repeats: [Int] = []
        var index = start
        while index < lines.count {
            let line = lines[index]
            let lower = line.lowercased()
            index += 1
            if endWords.contains(where: { lower.contains($0) }) { break }
            if serviceWords.contains(where: { lower.contains($0) }) { continue }
            if let name = itemName(line) {
                let found = amounts(in: line)
                // A name written in two lines: the first has no sums, the second begins with a small letter and carries them.
                if found.isEmpty, index < lines.count, let rest = itemName(lines[index]), !amounts(in: lines[index]).isEmpty,
                   lines[index].first(where: { $0.isLetter })?.isLowercase == true {
                    names.append(tidied(name + " " + rest))
                    bands.append(amounts(in: lines[index]))
                    index += 1
                    continue
                }
                // The same line read twice: one good read twice or two equal goods (two yoghurts, 100 and 100); the total of
                // the receipt decides. The same name with other sums is another good (two notebooks, 60 and 100).
                if names.last == name, bands.last == found {
                    guard expectedTotal != nil else { continue }
                    repeats.append(names.count)
                }
                names.append(name)
                bands.append(found)
                if names.count >= 60 { break }
            } else if !bands.isEmpty {
                bands[bands.count - 1] += amounts(in: line)
            }
        }
        var goods = zip(names, bands).map { ReceiptGood(name: $0, kopecks: lineTotal($1)) }
        guard let expectedTotal else { return goods }
        if !repeats.isEmpty {
            // Kept when the total adds up with them; otherwise they are the same line read twice (as before 46.41).
            let all = goods.compactMap(\.kopecks).reduce(0, +)
            if all != expectedTotal {
                let dropped = Set(repeats)
                goods = goods.indices.filter { !dropped.contains($0) }.map { goods[$0] }
                bands = bands.indices.filter { !dropped.contains($0) }.map { bands[$0] }
            }
        }
        return reconcilePrices(goods, bands: bands, expected: expectedTotal)
    }

    /// The prices fall short of the total of the receipt by `gap`. One good without a price and the gap seen among the sums of the
    /// very next good, which has more than one sum: its row of figures stuck to the next name. All goods priced and the price of
    /// one good plus the gap seen among its own sums: it took a repeated misreading («19,99») instead of the price («73,99»);
    /// but not when the last two sums of its line are its price (the price after the discount and the sum of the line agree:
    /// the price is confirmed, the gap is a service charge or a missing good — GPT stage 55). Nothing else is guessed:
    /// receipts with a discount on the whole receipt, with service charges or incomplete ones are left as they are.
    static func reconcilePrices(_ goods: [ReceiptGood], bands: [[Int64]], expected: Int64) -> [ReceiptGood] {
        guard goods.count == bands.count, !goods.isEmpty else { return goods }
        let gap = expected - goods.compactMap(\.kopecks).reduce(0, +)
        guard gap > 0 else { return goods }
        var result = goods
        let unpriced = goods.indices.filter { goods[$0].kopecks == nil }
        if unpriced.count == 1 {
            // Only the next name can carry the row of figures of this one (a gap among the sums of a far good is a coincidence).
            let next = unpriced[0] + 1
            if next < bands.count, bands[next].count >= 2, bands[next].contains(gap) { result[unpriced[0]].kopecks = gap }
            return result
        }
        guard unpriced.isEmpty else { return goods }
        func confirmed(_ index: Int) -> Bool {
            let band = bands[index]
            guard band.count >= 2, let price = goods[index].kopecks else { return false }
            return band[band.count - 1] == price && band[band.count - 2] == price
        }
        let fixable = goods.indices.filter { index in
            !confirmed(index) && (goods[index].kopecks.map { bands[index].contains($0 + gap) } ?? false)
        }
        if fixable.count == 1, let price = goods[fixable[0]].kopecks { result[fixable[0]].kopecks = price + gap }
        return result
    }

    /// Names read with the correction of words and prices read exactly are the same goods only if the lines are alike; a pass that
    /// missed a line shifts the prices to other names, and then nothing is paired.
    /// Each name takes the price of the free line most like it, the first one of equally alike lines (46.41: two yoghurts of one
    /// brand were alike enough to be paired by their order, and their prices swapped when the passes listed them differently;
    /// two goods of the same name still pair in their order). Nothing is paired unless every name finds a line alike enough.
    static func pairGoods(named: [ReceiptGood], priced: [ReceiptGood]) -> [ReceiptGood]? {
        guard !named.isEmpty, named.count == priced.count else { return nil }
        var used = Set<Int>()
        var chosen: [Int] = []
        for good in named {
            let scores = priced.map { similarity(good.name, $0.name) }
            let free = priced.indices.filter { !used.contains($0) }
            guard let best = free.max(by: { scores[$0] < scores[$1] || (scores[$0] == scores[$1] && $0 > $1) }), scores[best] >= 0.3 else { return nil }
            used.insert(best)
            chosen.append(best)
        }
        return zip(named, chosen).map { ReceiptGood(name: $0.name, kopecks: priced[$1].kopecks) }
    }

    /// How alike two texts are, 0…1 (the share of common pairs of letters; letters and digits only, case ignored).
    static func similarity(_ first: String, _ second: String) -> Double {
        func pairs(_ text: String) -> [String] {
            let letters = Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
            return letters.count < 2 ? letters.map { String($0) } : (0..<(letters.count - 1)).map { String(letters[$0...($0 + 1)]) }
        }
        var rest = pairs(second)
        let mine = pairs(first)
        guard !mine.isEmpty, !rest.isEmpty else { return first.lowercased() == second.lowercased() ? 1 : 0 }
        var common = 0
        for pair in mine {
            if let index = rest.firstIndex(of: pair) {
                common += 1
                rest.remove(at: index)
            }
        }
        return 2 * Double(common) / Double(mine.count + pairs(second).count)
    }

    /// The total of a line of a receipt among the sums found around its name. The unit price, the price after the discount and
    /// the total are printed together: the total is a price that repeats, or a whole multiple of one («2 × 279,99 = 559,98»).
    /// Nothing repeated: a sum that is a multiple of another; nothing of that kind: the last sum.
    static func lineTotal(_ sums: [Int64]) -> Int64? {
        guard !sums.isEmpty else { return nil }
        var seen = Set<Int64>()
        var repeated = Set<Int64>()
        for sum in sums where !seen.insert(sum).inserted { repeated.insert(sum) }
        var candidates = Set<Int64>()
        for unit in repeated where unit > 0 {
            for times in 1...9 where sums.contains(unit * Int64(times)) { candidates.insert(unit * Int64(times)) }
        }
        if let best = candidates.max() { return best }
        for unit in sums where unit > 0 {
            for times in 2...9 where sums.contains(unit * Int64(times)) { candidates.insert(unit * Int64(times)) }
        }
        return candidates.max() ?? sums.last
    }

    /// Whether the prices of the goods add up to a sum, and a sentence about it for the owner; nil when there is nothing to
    /// compare (no sum, or no price at all).
    static func goodsSumNote(_ goods: [ReceiptGood], expectedKopecks: Int64?) -> (text: String, adds: Bool)? {
        guard let expected = expectedKopecks else { return nil }
        let priced = goods.compactMap(\.kopecks)
        guard !priced.isEmpty else { return nil }
        let sum = priced.reduce(0, +)
        let missing = goods.count - priced.count
        if sum == expected && missing == 0 { return ("Сумма товаров сходится с суммой операции.", true) }
        var text = "Сумма товаров \(ReceiptGood.rubles(sum)), сумма операции \(ReceiptGood.rubles(expected)): проверьте цены"
        if missing > 0 { text += " (у \(missing) без цены)" }
        return (text + ".", false)
    }

    /// A word with capitals among small letters is a misread («КОлбасКА»): it becomes «Колбаска». Words in capitals only and
    /// words that do not begin with a letter stay as they are.
    static func tidied(_ name: String) -> String {
        name.split(separator: " ", omittingEmptySubsequences: true).map { word -> String in
            let letters = word.filter { $0.isLetter }
            guard word.first?.isLetter == true, letters.contains(where: { $0.isLowercase }),
                  letters.dropFirst().contains(where: { $0.isUppercase }) else { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// The name of a good on a printed line: without the sum, the quantity, the code before the name and the number after it.
    private static func itemName(_ raw: String) -> String? {
        var text = raw
        for (pattern, replacement) in [(#"[<>‹›«»\[\]{}|~^"'`]"#, " "),
                                       (#"(?i)\d+[.,]\d+\s*(?:л|кг|г)\s+(?=\d+[.,]\d{2}\s+\d+[.,]\d{2})"#, " "),
                                       (#"\d+[.,]\d{2}"#, " "),
                                       (#"(?i)(?<![\p{L}\d])\d+\s*шт\.?"#, " "),
                                       (#"(?<![\p{L}\d])\d+\s*[xх×]\s"#, " "),
                                       (#"^\s*\d{3,}\s+"#, ""),
                                       (#"[:;]\s*\d+\s*$"#, "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;-–_*"))
        // A name is short: a long one is a line of text that is not a good.
        if text.count > 48 { text = String(text.prefix(48)).trimmingCharacters(in: .whitespaces) }
        return text.filter { $0.isLetter }.count >= 3 ? tidied(text) : nil
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

/// The text of one receipt in the collection for the check of the reading: what the phone read, what the reading made of it
/// and what the owner saved, with a verdict for each of the three. Pure text, tested on the PC.
enum ReceiptCheckReport {
    struct Verdict: Equatable {
        var total: String
        var date: String
        var goods: String
        var totalMatches: Bool
        var dateMatches: Bool
    }

    static func verdict(read: ParsedReceipt, amountKopecks: Int64, date: Date?, goods: [ReceiptGood], calendar: Calendar = .current) -> Verdict {
        let amount = abs(amountKopecks)
        var verdict = Verdict(total: "", date: "", goods: "", totalMatches: false, dateMatches: false)
        if let total = read.totalKopecks {
            verdict.totalMatches = total == amount
            verdict.total = total == amount ? "совпала" : "НЕ совпала: прочитано \(ReceiptGood.rubles(total)), в операции \(ReceiptGood.rubles(amount))"
        } else {
            verdict.total = "не прочитана"
        }
        if let found = read.date, let saved = date {
            if read.dateHasTime {
                verdict.dateMatches = abs(found.timeIntervalSince(saved)) <= 120
                verdict.date = verdict.dateMatches ? "совпала" : "НЕ совпала: прочитано \(stamp(found, calendar)), в операции \(stamp(saved, calendar))"
            } else {
                verdict.dateMatches = calendar.isDate(found, inSameDayAs: saved)
                verdict.date = verdict.dateMatches ? "день совпал, время не прочиталось" : "НЕ совпала: прочитан день \(stamp(found, calendar)), в операции \(stamp(saved, calendar))"
            }
        } else {
            verdict.date = read.date == nil ? "не прочитана" : "в операции нет даты"
        }
        let readLines = read.goods.map(\.line)
        let savedLines = goods.map(\.line)
        if readLines.isEmpty && savedLines.isEmpty { verdict.goods = "товаров нет" }
        else if readLines.isEmpty { verdict.goods = "не найдены телефоном, введены вами: \(savedLines.count)" }
        else if savedLines.isEmpty { verdict.goods = "прочитано \(readLines.count), вы удалили все" }
        else if readLines == savedLines { verdict.goods = "не менялись (\(readLines.count))" }
        else { verdict.goods = "исправлены вами: прочитано \(readLines.count), сохранено \(savedLines.count)" }
        return verdict
    }

    private static func stamp(_ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: date)
    }

    static func text(number: Int, read: ParsedReceipt, source: String, title: String, category: String?, amountKopecks: Int64,
                     date: Date?, goods: [ReceiptGood], calendar: Calendar = .current) -> String {
        let judged = Self.verdict(read: read, amountKopecks: amountKopecks, date: date, goods: goods, calendar: calendar)
        var lines: [String] = ["Чек № \(number)", "Источник текста: \(source)", ""]
        lines.append("== Сохранено в операции ==")
        lines.append("Название: \(title)")
        lines.append("Сумма: \(ReceiptGood.rubles(abs(amountKopecks)))")
        lines.append("Дата: \(date.map { stamp($0, calendar) } ?? "—")")
        lines.append("Категория: \(category ?? "—")")
        lines.append("Товары (\(goods.count)):")
        lines += goods.map { "  " + $0.line }
        lines += ["", "== Что извлёк разбор из текста =="]
        lines.append("Сумма: \(read.totalKopecks.map { ReceiptGood.rubles($0) } ?? "не прочитана")")
        lines.append("Дата: \(read.date.map { stamp($0, calendar) + (read.dateHasTime ? "" : " (время не прочиталось)") } ?? "не прочитана")")
        lines.append("Магазин: \(read.merchant ?? "не определён")")
        if !read.readingNotes.isEmpty { lines.append("Как читалось: " + read.readingNotes.joined(separator: "; ")) }
        lines.append("Товары (\(read.goods.count)):")
        lines += read.goods.map { "  " + $0.line }
        lines += ["", "== Сравнение =="]
        lines.append("Сумма: \(judged.total)")
        lines.append("Дата: \(judged.date)")
        lines.append("Товары: \(judged.goods)")
        lines += ["", "== Прочитанный телефоном текст, строки сверху вниз =="]
        lines += read.readLines.isEmpty ? ["(текст не сохранён)"] : read.readLines
        return lines.joined(separator: "\n")
    }
}

// MARK: - Receipt and bank operation

/// A bank operation the receipt may belong to: its identity in the history and what the engine reads from it.
struct ReceiptMatchCandidate {
    let identity: String
    let input: FinancialOperationInput
}

enum ReceiptMatchOutcome: Equatable {
    /// One operation clearly leads; `timeFix` is its time when the receipt has a time and the two differ by 15 minutes at most.
    case confirmed(identity: String, timeFix: Date?)
    /// Several are close: the owner chooses (at most five, the best first).
    case ambiguous([String])
    case none
}

/// Which bank purchase a receipt is (GPT stage 58 contract, DeepSeek's answer of 9 Oct). The sum leads: the same in kopecks,
/// or one digit misread by the pairs 3↔2, 8↔6, 5↔6, 1↔7; the day of the receipt or the next/previous one; the time only
/// refines. The sum of the receipt is never changed.
enum ReceiptBankMatch {
    /// The digits the reading of a receipt mixes up (either way).
    static let digitSwaps: Set<String> = ["32", "23", "86", "68", "56", "65", "17", "71"]

    static func match(totalKopecks: Int64?, date: Date?, hasTime: Bool, candidates: [ReceiptMatchCandidate],
                      calendar: Calendar = .current) -> ReceiptMatchOutcome {
        guard let total = totalKopecks, total > 0, let date else { return .none }
        let receiptDay = calendar.startOfDay(for: date)
        var ranked: [(identity: String, date: Date, score: Double)] = []
        for candidate in candidates {
            let input = candidate.input
            // A purchase of the bank: not a manual entry, not cancelled; a purchase still «в обработке» counts.
            // The cheap checks first: the form asks on every change of its fields, over the whole history.
            guard !candidate.identity.hasPrefix(ManualOperation.identityPrefix), input.amountKopecks < 0, input.amountKopecks != Int64.min,
                  let amountScore = amountScore(receipt: total, bank: -input.amountKopecks),
                  let when = BankDateParser.parse(input.occurredAt),
                  let days = calendar.dateComponents([.day], from: receiptDay, to: calendar.startOfDay(for: when)).day,
                  abs(days) <= 1 else { continue }
            let type = FinancialEngine.classify(input).type
            guard type == .expense || type == .pending else { continue }
            let timeScore = hasTime ? max(0, 60 - abs(when.timeIntervalSince(date)) / 60) : 0
            ranked.append((candidate.identity, when, amountScore + (days == 0 ? 50 : 20) + timeScore))
        }
        ranked.sort { $0.score == $1.score ? $0.identity < $1.identity : $0.score > $1.score }
        guard let best = ranked.first else { return .none }
        if ranked.count == 1 || best.score - ranked[1].score >= 20 {
            let fix = hasTime && abs(best.date.timeIntervalSince(date)) <= 15 * 60 ? best.date : nil
            return .confirmed(identity: best.identity, timeFix: fix)
        }
        return .ambiguous(Array(ranked.prefix(5).map(\.identity)))
    }

    /// 100 for the same sum, 40 for one digit misread by a known pair (in the same number of digits), nil otherwise.
    static func amountScore(receipt: Int64, bank: Int64) -> Double? {
        if receipt == bank { return 100 }
        let left = Array(String(receipt)), right = Array(String(bank))
        guard left.count == right.count else { return nil }
        let differing = left.indices.filter { left[$0] != right[$0] }
        guard differing.count == 1, let at = differing.first, digitSwaps.contains(String([left[at], right[at]])) else { return nil }
        return 40
    }
}
