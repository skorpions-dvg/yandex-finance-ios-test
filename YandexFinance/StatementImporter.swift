import Foundation
import PDFKit
import CryptoKit

struct StatementImportResult {
    let operations: [BankOperation]
    let coverageStart: Date?
    let coverageEnd: Date?
    let ignoredAtOrAfterCutoff: Int
}

enum StatementImporter {
    // Old history comes from statements. The live WebView scanner owns this date and everything newer.
    static let archiveCutoffISO = "2026-09-30T21:00:00Z" // 01.10.2026 00:00 Moscow

    private static let moscow = TimeZone(identifier: "Europe/Moscow")!
    private static let posix = Locale(identifier: "en_US_POSIX")

    private static let operationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.timeZone = moscow
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.timeZone = moscow
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let rowRegex = try! NSRegularExpression(
        pattern: #"(?s)(.+?)\s+(\d{2}\.\d{2}\.\d{4})\s*\nв\s+(\d{2}:\d{2})\s*\n(\d{2}\.\d{2}\.\d{4})(?:\s+\*(\d{4}))?\s+([+−–-]\d[\d\u00A0 ]*,\d{2}\s*₽)\s+([+−–-]\d[\d\u00A0 ]*,\d{2}\s*₽)"#
    )

    private static let periodRegex = try! NSRegularExpression(
        pattern: #"Выписка по Договору за период с\s+(\d{2}\.\d{2}\.\d{4})\s+по\s+(\d{2}\.\d{2}\.\d{4})"#,
        options: [.caseInsensitive]
    )

    private static let holderRegex = try! NSRegularExpression(
        pattern: #"(?m)^([А-ЯЁ][А-Яа-яЁё-]+)\s+([А-ЯЁ][А-Яа-яЁё-]+)\s+([А-ЯЁ][А-Яа-яЁё-]+)\s*$\nДата рождения"#
    )

    static var archiveCutoff: Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: archiveCutoffISO)!
    }

    static func importPDF(at url: URL) throws -> StatementImportResult {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw AppFailure(message: "Не удалось открыть PDF-выписку.")
        }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        return try parsePages(pages)
    }

    // Internal on purpose: synthetic CI tests validate the parser without publishing real bank data.
    static func parsePages(_ pages: [String]) throws -> StatementImportResult {
        let fullText = pages.joined(separator: "\n")
        guard fullText.localizedCaseInsensitiveContains("Яндекс Банк"),
              fullText.localizedCaseInsensitiveContains("Выписка по Договору") else {
            throw AppFailure(message: "Это не похоже на выписку Яндекс Банка.")
        }

        let holder = parseHolder(fullText)
        let coverage = parseCoverage(fullText)
        let requiredThrough = archiveCutoff.addingTimeInterval(-86400)
        guard let coverageEnd = coverage.end, coverageEnd >= requiredThrough else {
            throw AppFailure(message: "Выписка заканчивается раньше 30.09.2026. Нужна выписка, которая покрывает архив до конца сентября.")
        }

        var rawRows: [(description: String, date: String, time: String, processed: String, card: String?, amount: Int64)] = []
        for page in pages {
            let body = transactionBody(from: page)
            guard !body.isEmpty else { continue }
            let ns = body as NSString
            let matches = rowRegex.matches(in: body, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let description = collapseWhitespace(ns.substring(with: match.range(at: 1)))
                guard !description.isEmpty,
                      let amount = parseAmount(ns.substring(with: match.range(at: 6))) else { continue }
                rawRows.append((description,
                                ns.substring(with: match.range(at: 2)),
                                ns.substring(with: match.range(at: 3)),
                                ns.substring(with: match.range(at: 4)),
                                match.range(at: 5).location == NSNotFound ? nil : ns.substring(with: match.range(at: 5)),
                                amount))
            }
        }

        guard !rawRows.isEmpty else {
            throw AppFailure(message: "В выписке не удалось найти операции.")
        }

        var seenSignatures: [String: Int] = [:]
        var operations: [BankOperation] = []
        var ignored = 0

        for row in rawRows {
            guard let date = operationDateFormatter.date(from: row.date + " " + row.time) else { continue }
            if date >= archiveCutoff {
                ignored += 1
                continue
            }

            let signature = [row.date, row.time, row.processed, row.card ?? "", String(row.amount), row.description].joined(separator: "|")
            let occurrence = seenSignatures[signature, default: 0]
            seenSignatures[signature] = occurrence + 1
            let identity = statementIdentity(signature: signature, occurrence: occurrence)
            let inferred = classify(description: row.description, amount: row.amount, holder: holder)

            operations.append(BankOperation(
                identity: identity,
                occurredAt: isoFormatter.string(from: date),
                timePrecision: "statement_minute",
                description: row.description,
                amountKopecks: row.amount,
                currency: "RUB",
                status: "Выполнено",
                category: inferred.category,
                mcc: nil,
                purpose: inferred.purpose,
                paymentMethod: row.card.map { "Карта *\($0)" } ?? "Выписка",
                providers: inferred.providers,
                kind: inferred.kind,
                components: nil,
                verifiedAt: isoFormatter.string(from: Date())
            ))
        }

        guard !operations.isEmpty else {
            throw AppFailure(message: "В выписке нет операций раньше 01.10.2026 для архивного импорта.")
        }

        operations.sort {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.identity < $1.identity
        }
        return StatementImportResult(operations: operations,
                                     coverageStart: coverage.start,
                                     coverageEnd: coverage.end,
                                     ignoredAtOrAfterCutoff: ignored)
    }

    private static func transactionBody(from page: String) -> String {
        var text = page.replacingOccurrences(of: "\r\n", with: "\n")
        let markers = ["\nДоговора\n", "\nЭСП\n"]
        if let end = markers.compactMap({ text.range(of: $0)?.upperBound }).max() {
            text = String(text[end...])
        } else {
            return ""
        }
        let footerMarkers = ["\nВходящий остаток", "\nИсходящий остаток", "\nСтраница "]
        if let start = footerMarkers.compactMap({ text.range(of: $0)?.lowerBound }).min() {
            text = String(text[..<start])
        }
        return text
    }

    private static func parseCoverage(_ text: String) -> (start: Date?, end: Date?) {
        let ns = text as NSString
        let matches = periodRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var starts: [Date] = []
        var ends: [Date] = []
        for match in matches {
            if let date = dayFormatter.date(from: ns.substring(with: match.range(at: 1))) { starts.append(date) }
            if let date = dayFormatter.date(from: ns.substring(with: match.range(at: 2))) { ends.append(date) }
        }
        return (starts.min(), ends.max())
    }

    private static func parseHolder(_ text: String) -> (surname: String, first: String, patronymic: String)? {
        let ns = text as NSString
        guard let match = holderRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: match.range(at: 1)),
                ns.substring(with: match.range(at: 2)),
                ns.substring(with: match.range(at: 3)))
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseAmount(_ raw: String) -> Int64? {
        let negative = raw.contains("−") || raw.contains("–") || raw.contains("-")
        let digits = raw.compactMap { $0.isNumber ? $0 : nil }
        guard digits.count >= 3, let absolute = Int64(String(digits)) else { return nil }
        return negative ? -absolute : absolute
    }

    private static func statementIdentity(signature: String, occurrence: Int) -> String {
        let bytes = Data("statement-v1|\(signature)|\(occurrence)".utf8)
        let digest = SHA256.hash(data: bytes)
        return "statement:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalize(_ value: String) -> String {
        collapseWhitespace(value).lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func belongsToHolder(_ description: String, holder: (surname: String, first: String, patronymic: String)?) -> Bool {
        guard let holder else { return false }
        let value = normalize(description)
        let first = normalize(holder.first)
        let patronymic = normalize(holder.patronymic)
        let surname = normalize(holder.surname)
        let initial = surname.prefix(1)
        return value.contains("\(first) \(patronymic) \(initial).") ||
               value.contains("\(surname) \(first) \(patronymic)")
    }

    private static func classify(description: String, amount: Int64,
                                 holder: (surname: String, first: String, patronymic: String)?)
        -> (category: String, kind: String, providers: [String], purpose: String?) {
        let value = normalize(description)

        if value.contains("возврат") {
            return ("Возврат", "refund", [], description)
        }
        if value.contains("ysplit") || value.contains("*split") || value.contains("сплит") {
            return ("Платежи Сплита", "installment_payment", ["bnpl"], description)
        }
        if value.contains("перевод между счетами одного клиента") ||
            value.contains("перенос денежных средств с эдс на банковский счет") ||
            value.contains("входящий перевод с карты") ||
            ((value.contains("входящий перевод сбп") || value.contains("исходящий перевод сбп")) && belongsToHolder(description, holder: holder)) ||
            value.contains("снятие налич") || value.contains("выдача налич") {
            return ("Переводы между своими счетами", "internal_transfer", [], description)
        }
        if amount < 0 && value.contains("комисси") {
            return ("Комиссии", "commission", [], description)
        }
        if amount > 0 && (value.contains("начисление процентов") || value.contains("выплата процентов") || value.contains("процентный доход")) {
            return ("Проценты", "interest_income", [], description)
        }
        if value.contains("перевод сбп") || value.hasPrefix("исходящий перевод") || value.hasPrefix("входящий перевод") {
            return ("Перевод", "transfer", [], description)
        }
        if amount > 0 {
            return ("Не определено", "unclassified_income", [], description)
        }

        let category: String
        if value.contains("магнит") || value.contains("пятероч") || value.contains("pyateroch") || value.contains("супермаркет") {
            category = "Супермаркеты"
        } else if value.contains("yandex*4121*taxi") || value.contains("такси") {
            category = "Такси"
        } else if value.contains("dns") || value.contains("цифровая техника") || value.contains("бытовая техника") {
            category = "Электроника"
        } else if value.contains("ozon") || value.contains("озон") || value.contains("wildberries") || value.contains("вайлдберриз") {
            category = "Маркетплейсы"
        } else if value.contains("аптек") {
            category = "Аптеки"
        } else if value.contains("мегафон") || value.contains("tele2") || value.contains("билайн") || value.contains("мтс") {
            category = "Связь"
        } else if value.contains("лицевой счет") || value.contains("<лси") {
            category = "ЖКХ"
        } else if value.contains("yandex*4215*dostavka") || value.contains("яндекс.доставка") {
            category = "Доставка и курьеры"
        } else {
            category = "Не определено"
        }
        return (category, "expense", [], description)
    }
}
