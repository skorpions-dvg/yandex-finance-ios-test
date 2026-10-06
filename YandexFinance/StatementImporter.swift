import Foundation
import PDFKit
import CryptoKit

struct StatementImportResult {
    enum Source: Hashable { case account, save }
    let source: Source
    let operations: [BankOperation]
    let coverageStart: Date?
    let coverageEnd: Date?
    let ignoredAtOrAfterCutoff: Int
}

/// A word in physical page coordinates (points, top-left origin).
struct StatementCell {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct StatementImportPreview {
    let history: SavedHistory
    let replaced: Int
    let corrected: Int
    let transferred: Int
    let ambiguousChoices: Int
    let accountCount: Int
    let saveCount: Int
    let ignored: Int
    let unchanged: Bool
    var summary: String {
        "Будет заменено записей: \(replaced)\nИз них исправлены названия: \(corrected)\nВыборов категорий перенесено: \(transferred)\nНе перенесено (неоднозначно): \(ambiguousChoices)\n\nИмпортировано: \(accountCount) операций платёжного счёта, \(saveCount) операций Сейва. Операций с 01.10.2026 оставлено сканеру: \(ignored)." + (unchanged ? " Операций новых нет." : "")
    }
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
        let geometry = (0..<document.pageCount).map { document.page(at: $0).map(cells(from:)) ?? [] }
        if geometry.allSatisfy({ $0.isEmpty }) { return try parsePages(pages) }
        return try parseRows(geometry, metadata: pages.joined(separator: "\n"))
    }

    private struct Row {
        let description: String
        let date: String
        let time: String
        let processed: String
        let card: String?
        let amount: Int64
    }

    // Text fixtures retain the historical parsing order; real PDFs use physical cells.
    static func parsePages(_ pages: [String]) throws -> StatementImportResult {
        let fullText = pages.joined(separator: "\n")
        let source = try sourceType(fullText)
        var rows: [Row] = []
        let saveRegex = try NSRegularExpression(pattern: #"(?s)(.+?)\s+(\d{2}\.\d{2}\.\d{4})\s+([+−–-]\s*\d[\d\u00A0 ]*,\d{2}\s*₽)"#)
        for (pageIndex, page) in pages.enumerated() {
            let body = transactionBody(from: page), ns = transactionBody(from: page) as NSString
            let regex = source == .account ? rowRegex : saveRegex
            for (rowIndex, match) in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)).enumerated() {
                let description = collapseWhitespace(ns.substring(with: match.range(at: 1)))
                try validateDescription(description, row: rowIndex + 1, page: pageIndex + 1)
                guard let amount = parseAmount(ns.substring(with: match.range(at: source == .account ? 6 : 3))) else {
                    throw ambiguous(row: rowIndex + 1, page: pageIndex + 1)
                }
                rows.append(Row(description: description, date: ns.substring(with: match.range(at: 2)),
                    time: source == .account ? ns.substring(with: match.range(at: 3)) : "12:00",
                    processed: source == .account ? ns.substring(with: match.range(at: 4)) : "",
                    card: source == .account && match.range(at: 5).location != NSNotFound ? ns.substring(with: match.range(at: 5)) : nil,
                    amount: amount))
            }
        }
        return try makeResult(rows, source: source, fullText: fullText)
    }

    private static func sourceType(_ text: String) throws -> StatementImportResult.Source {
        guard text.localizedCaseInsensitiveContains("Яндекс Банк"), text.localizedCaseInsensitiveContains("Выписка по Договору") else {
            throw AppFailure(message: "Это не похоже на выписку Яндекс Банка.")
        }
        return text.localizedCaseInsensitiveContains("банковского вклада") ? .save : .account
    }

    private static func makeResult(_ rows: [Row], source: StatementImportResult.Source, fullText: String) throws -> StatementImportResult {
        let holder = parseHolder(fullText), coverage = parseCoverage(fullText)
        if source == .account {
            guard let end = coverage.end, end >= archiveCutoff.addingTimeInterval(-86400) else {
                throw AppFailure(message: "Выписка заканчивается раньше 30.09.2026. Нужна выписка, которая покрывает архив до конца сентября.")
            }
        }
        guard !rows.isEmpty else { throw AppFailure(message: "В выписке не удалось найти операции.") }
        var seen: [String: Int] = [:], operations: [BankOperation] = []
        var ignored = 0
        for row in rows {
            guard let date = operationDateFormatter.date(from: row.date + " " + row.time) else {
                throw AppFailure(message: "Не удалось определить дату строки выписки.")
            }
            if date >= archiveCutoff { ignored += 1; continue }
            let signature = source == .account
                ? [row.date, row.time, row.processed, row.card ?? "", String(row.amount), row.description].joined(separator: "|")
                : [row.date, String(row.amount), row.description].joined(separator: "|")
            let occurrence = seen[signature, default: 0]; seen[signature] = occurrence + 1
            let identity: String
            let inferred: (category: String, kind: String, providers: [String], purpose: String?)
            if source == .account {
                identity = statementIdentity(signature: signature, occurrence: occurrence)
                inferred = classify(description: row.description, amount: row.amount, holder: holder)
            } else {
                let value = normalize(row.description), interest = normalize(row.description).contains("процент")
                let digest = SHA256.hash(data: Data("statement-save-v1|\(signature)|\(occurrence)".utf8))
                identity = "statement-save:" + digest.map { String(format: "%02x", $0) }.joined()
                if interest { inferred = ("Проценты", "interest_income", [], row.description) }
                else if value.contains("перевод между счетами") || value.contains("пополнение") || value.contains("вывод") {
                    inferred = ("Переводы между своими счетами", "internal_transfer", [], row.description)
                } else { inferred = classify(description: row.description, amount: row.amount, holder: holder) }
            }
            operations.append(BankOperation(identity: identity, occurredAt: isoFormatter.string(from: date),
                timePrecision: source == .account ? "statement_minute" : "statement_day", description: row.description,
                amountKopecks: row.amount, currency: "RUB", status: "Выполнено", category: inferred.category,
                mcc: nil, purpose: inferred.purpose,
                paymentMethod: source == .save ? "Сейв (выписка)" : (row.card.map { "Карта *\($0)" } ?? "Выписка"),
                providers: inferred.providers, kind: inferred.kind, verifiedAt: isoFormatter.string(from: Date())))
        }
        guard !operations.isEmpty else { throw AppFailure(message: "В выписке нет операций раньше 01.10.2026 для архивного импорта.") }
        operations.sort { $0.occurredAt == $1.occurredAt ? $0.identity < $1.identity : $0.occurredAt > $1.occurredAt }
        return StatementImportResult(source: source, operations: operations, coverageStart: coverage.start,
            coverageEnd: coverage.end, ignoredAtOrAfterCutoff: ignored)
    }

    private static func ambiguous(row: Int, page: Int) -> AppFailure {
        AppFailure(message: "Строка \(row) страницы \(page) разобрана неоднозначно. Импорт отменён.")
    }

    private static func validateDescription(_ text: String, row: Int, page: Int) throws {
        // A card number inside a meaningful description (a card top-up) is valid;
        // an isolated card cell, date/time or signed money is never a description.
        let contamination = #"\d{2}\.\d{2}\.\d{4}|\bв\s+\d{2}:\d{2}|[+−–-]\s*\d[\d\s]*,\d{2}\s*₽|^\*\d{4}$"#
        guard !text.isEmpty, text.range(of: contamination, options: .regularExpression) == nil else {
            throw ambiguous(row: row, page: page)
        }
    }

    /// Coordinates are in page points, x rightwards, y downwards from the page top.
    static func parseRows(_ pages: [[StatementCell]], metadata: String? = nil) throws -> StatementImportResult {
        let pageLines = pages.map(physicalLines)
        let fullText = metadata ?? pageLines.map { $0.map { lineText($0) }.joined(separator: "\n") }.joined(separator: "\n")
        let source = try sourceType(fullText)
        var rows: [Row] = []
        for (pageIndex, lines) in pageLines.enumerated() {
            let headers = lines.indices.filter { lineText(lines[$0]).contains("Описание операции") && lineText(lines[$0]).contains("Дата") }
            for (headerIndex, start) in headers.enumerated() {
                let header = lines[start].sorted { $0.x < $1.x }
                let dates = header.filter { $0.text.hasPrefix("Дата") }
                let sums = header.filter { $0.text.hasPrefix("Сумма") }
                let card = header.first { $0.text.hasPrefix("Карта") }
                guard dates.count == (source == .account ? 2 : 1), sums.count == (source == .account ? 2 : 1),
                      source == .save || card != nil else { throw ambiguous(row: 0, page: pageIndex + 1) }
                let seeds = source == .save ? [dates[0], sums[0]] : [dates[0], dates[1], card!, sums[0], sums[1]]
                let end = headerIndex + 1 < headers.count ? headers[headerIndex + 1] : lines.count
                let body = Array(lines[(start + 1)..<end])
                // A centered multiline heading can start farther right than its values
                // ("Дата" above "обработки"). Use the whole header, not its first word.
                let headingEnd = body.firstIndex { line in line.contains { $0.text.range(of: #"^\d{2}\.\d{2}\.\d{4}$"#, options: .regularExpression) != nil } } ?? body.count
                let headingCells = (header + body[..<headingEnd].flatMap { $0 }).filter { $0.x >= seeds[0].x - 8 }
                var starts = seeds.map(\.x)
                for cell in headingCells {
                    let center = cell.x + cell.width / 2
                    let nearest = seeds.indices.min { abs(seeds[$0].x + seeds[$0].width / 2 - center) < abs(seeds[$1].x + seeds[$1].width / 2 - center) }!
                    starts[nearest] = min(starts[nearest], cell.x)
                }
                let cuts = starts.map { $0 - 3 }
                func column(_ cells: [StatementCell], _ index: Int) -> [StatementCell] {
                    cells.filter { cell in
                        let center = cell.x + cell.width / 2
                        return (index == 0 || center >= cuts[index - 1]) && (index == cuts.count || center < cuts[index])
                    }
                }
                let anchors = body.indices.filter { index in
                    column(body[index], 1).contains { $0.text.range(of: #"^\d{2}\.\d{2}\.\d{4}$"#, options: .regularExpression) != nil }
                }
                for (rowIndex, anchor) in anchors.enumerated() {
                    let next = rowIndex + 1 < anchors.count ? anchors[rowIndex + 1] : body.count
                    var band = Array(body[anchor..<next])
                    if let footer = band.firstIndex(where: { line in
                        let text = lineText(line)
                        return text.hasPrefix("Входящий остаток") || text.hasPrefix("Исходящий остаток") || text.hasPrefix("Страница ") || text.hasPrefix("Продолжение ")
                    }) { band = Array(band[..<footer]) }
                    func value(_ index: Int) -> String { collapseWhitespace(band.map { lineText(column($0, index)) }.joined(separator: " ")) }
                    let description = value(0), date = lineText(column(body[anchor], 1))
                    try validateDescription(description, row: rowIndex + 1, page: pageIndex + 1)
                    let datePattern = #"^\d{2}\.\d{2}\.\d{4}$"#
                    let moneyPattern = #"^[+−–-]\s*\d[\d\s]*,\d{2}\s*₽$"#
                    let amountText = value(source == .save ? 2 : 4)
                    guard date.range(of: datePattern, options: .regularExpression) != nil,
                          amountText.range(of: moneyPattern, options: .regularExpression) != nil,
                          let amount = parseAmount(amountText) else { throw ambiguous(row: rowIndex + 1, page: pageIndex + 1) }
                    var time = "12:00", processed = "", cardNumber: String?
                    if source == .account {
                        let timing = value(1), cardText = value(3)
                        guard let timeRange = timing.range(of: #"\b\d{2}:\d{2}\b"#, options: .regularExpression),
                              value(2).range(of: datePattern, options: .regularExpression) != nil,
                              value(5).range(of: moneyPattern, options: .regularExpression) != nil,
                              cardText.isEmpty || cardText.range(of: #"^\*\d{4}$"#, options: .regularExpression) != nil else {
                            throw ambiguous(row: rowIndex + 1, page: pageIndex + 1)
                        }
                        time = String(timing[timeRange]); processed = value(2)
                        cardNumber = cardText.isEmpty ? nil : String(cardText.dropFirst())
                    }
                    rows.append(Row(description: description, date: date, time: time, processed: processed, card: cardNumber, amount: amount))
                }
            }
        }
        return try makeResult(rows, source: source, fullText: fullText)
    }

    private static func lineText(_ cells: [StatementCell]) -> String {
        cells.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
    }

    private static func physicalLines(_ cells: [StatementCell]) -> [[StatementCell]] {
        let sorted = cells.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        var lines: [[StatementCell]] = []
        for cell in sorted {
            if let last = lines.last, let first = last.first,
               abs((first.y + first.height / 2) - (cell.y + cell.height / 2)) <= max(2, min(first.height, cell.height) * 0.3) {
                lines[lines.count - 1].append(cell)
            } else { lines.append([cell]) }
        }
        return lines
    }

    static func cells(from page: PDFPage) -> [StatementCell] {
        guard let raw = page.string else { return [] }
        let text = raw as NSString, bounds = page.bounds(for: .mediaBox)
        var words: [StatementCell] = [], word: StatementCell?
        // Keep explicit spaces: some fonts have a space narrower than a glyph's
        // bounding-box tolerance. Page text order is irrelevant once words have coordinates.
        for index in 0..<min(page.numberOfCharacters, text.length) {
            let range = NSRange(location: index, length: 1)
            // PDFKit may insert reading-order separators in page.string. A one-character
            // selection uses the same character index as characterBounds, including ligatures.
            let character = page.selection(for: range)?.string ?? text.substring(with: range)
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let word { words.append(word) }; word = nil
                continue
            }
            let rect = page.characterBounds(at: index)
            guard rect.width > 0, rect.height > 0 else { continue }
            let glyph = StatementCell(text: character, x: rect.minX, y: bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
            if let current = word,
               abs(current.y + current.height - (glyph.y + glyph.height)) <= max(3, glyph.height * 0.5),
               glyph.x >= current.x, glyph.x - (current.x + current.width) < max(5, glyph.height * 0.7) {
                word = StatementCell(text: current.text + character, x: current.x, y: min(current.y, glyph.y),
                    width: max(current.width, glyph.x + glyph.width - current.x),
                    height: max(current.y + current.height, glyph.y + glyph.height) - min(current.y, glyph.y))
            } else {
                if let word { words.append(word) }; word = glyph
            }
        }
        if let word { words.append(word) }
        return words
    }

    /// Parse the entire selection before preparing a single atomic history replacement.
    static func importPDFs(_ urls: [URL]) throws -> [StatementImportResult] {
        try urls.map { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { return try importPDF(at: url) }
            catch { throw AppFailure(message: "\(url.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    static func merging(_ results: [StatementImportResult], into original: SavedHistory) throws -> SavedHistory {
        guard !results.isEmpty else { throw AppFailure(message: "Выписки не выбраны.") }
        let sources = Set(results.map(\.source))
        var next = original
        next.operations.removeAll { operation in
            if operation.identity.hasPrefix("statement-save:") { return sources.contains(.save) }
            return sources.contains(.account) && (BankDateParser.parse(operation.occurredAt).map { $0 < archiveCutoff } ?? false)
        }
        var byID = Dictionary(next.operations.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        for result in results {
            for operation in result.operations {
                guard operation.currency == "RUB", !operation.identity.isEmpty, !operation.description.isEmpty,
                      BankDateParser.parse(operation.occurredAt) != nil else {
                    throw AppFailure(message: "Часть операций выписки не прошла проверку. Архив не сохранён.")
                }
                if let old = original.operations.first(where: { $0.identity == operation.identity }), old.sameFinancialContent(as: operation) {
                    byID[operation.identity] = old
                } else { byID[operation.identity] = operation }
            }
        }
        next.operations = byID.values.sorted { $0.occurredAt == $1.occurredAt ? $0.identity < $1.identity : $0.occurredAt > $1.occurredAt }
        if sources.contains(.account) {
            next.unresolvedIssues = (next.unresolvedIssues ?? []).filter { issue in
                if let raw = issue.bankDate, let date = BankDateParser.parse(raw) { return date >= archiveCutoff }
                if let month = issue.monthOrdinal { return month >= 2026 * 12 + 9 }
                return true
            }
            next.bootstrapCompleted = true; next.bootstrapResumeMonth = nil
        }
        next.statementArchiveThrough = archiveCutoff.addingTimeInterval(-1)
        next.statementImportedAt = Date()
        next.statementOperationCount = next.operations.filter { $0.identity.hasPrefix("statement:") || $0.identity.hasPrefix("statement-save:") }.count
        next.lastStopReason = "statement_archive_imported"; next.lastSync = Date()
        return next
    }

    private struct MigrationKey: Hashable {
        let date: String
        let amount: Int64
        let method: String?
        init(_ operation: BankOperation) {
            date = operation.occurredAt; amount = operation.amountKopecks; method = operation.paymentMethod
        }
    }

    /// Preview is a value copy. No category choice is guessed and storage is not touched.
    static func preview(_ results: [StatementImportResult], into original: SavedHistory) throws -> StatementImportPreview {
        var next = try merging(results, into: original)
        let hasAccount = results.contains { $0.source == .account }
        let hasSave = results.contains { $0.source == .save }
        let replaced = original.operations.filter { operation in
            if operation.identity.hasPrefix("statement-save:") { return hasSave }
            return hasAccount && (BankDateParser.parse(operation.occurredAt).map { $0 < archiveCutoff } ?? false)
        }.count
        let newAccount = next.operations.filter { $0.identity.hasPrefix("statement:") }
        let newIDs = Set(newAccount.map(\.identity))
        let oldRows = hasAccount ? original.operations.filter { $0.identity.hasPrefix("statement:") && !newIDs.contains($0.identity) } : []
        let candidates = Dictionary(grouping: newAccount, by: MigrationKey.init)
        let oldKeys = Dictionary(grouping: oldRows, by: MigrationKey.init)
        var occupied = Set(original.operations.filter { newIDs.contains($0.identity) }.map(\.identity))
        var corrected = 0, transferred = 0, ambiguousChoices = 0
        for old in oldRows.sorted(by: { $0.identity < $1.identity }) {
            let matches = candidates[MigrationKey(old)] ?? []
            let expense = original.categoryOverrides?[old.identity]
            let income = original.incomeCategoryOverrides?[old.identity]
            let choices = (expense == nil ? 0 : 1) + (income == nil ? 0 : 1)
            guard matches.count == 1, oldKeys[MigrationKey(old)]?.count == 1,
                  let match = matches.first, !occupied.contains(match.identity),
                  next.categoryOverrides?[match.identity] == nil, next.incomeCategoryOverrides?[match.identity] == nil else {
                ambiguousChoices += choices
                continue
            }
            occupied.insert(match.identity)
            if old.description != match.description { corrected += 1 }
            if let expense {
                if next.categoryOverrides == nil { next.categoryOverrides = [:] }
                next.categoryOverrides?[match.identity] = expense
                next.categoryOverrides?.removeValue(forKey: old.identity)
                transferred += 1
            }
            if let income {
                if next.incomeCategoryOverrides == nil { next.incomeCategoryOverrides = [:] }
                next.incomeCategoryOverrides?[match.identity] = income
                next.incomeCategoryOverrides?.removeValue(forKey: old.identity)
                transferred += 1
            }
        }
        return StatementImportPreview(history: next, replaced: replaced, corrected: corrected, transferred: transferred,
            ambiguousChoices: ambiguousChoices,
            accountCount: Set(results.filter { $0.source == .account }.flatMap { $0.operations.map(\.identity) }).count,
            saveCount: Set(results.filter { $0.source == .save }.flatMap { $0.operations.map(\.identity) }).count,
            ignored: results.reduce(0) { $0 + $1.ignoredAtOrAfterCutoff }, unchanged: original.operations == next.operations)
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
