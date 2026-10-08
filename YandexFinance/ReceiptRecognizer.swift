import UIKit
import Vision

/// Reads a receipt on the phone itself, nothing leaves it: the QR code of a cash receipt and the printed text. What the
/// text means (the sum, the date, the shop) is decided by `ReceiptParser`.
enum ReceiptRecognizer {
    static func recognize(_ images: [UIImage]) async -> ParsedReceipt {
        await Task.detached(priority: .userInitiated) { read(images) }.value
    }

    nonisolated private static func read(_ images: [UIImage]) -> ParsedReceipt {
        var qr: ParsedReceipt?
        var lines: [String] = []
        var nameLines: [String] = []
        for image in images {
            guard let cgImage = image.cgImage else { continue }
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.recognitionLanguages = ["ru-RU", "en-US"]
            text.usesLanguageCorrection = false
            // The goods are words: a second pass with the correction of words reads their names better than the exact pass,
            // which is kept for the digits.
            let words = VNRecognizeTextRequest()
            words.recognitionLevel = .accurate
            words.recognitionLanguages = ["ru-RU", "en-US"]
            words.usesLanguageCorrection = true
            let codes = VNDetectBarcodesRequest()
            codes.symbologies = [.qr]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation(image.imageOrientation), options: [:])
            try? handler.perform([text, words, codes])
            if qr == nil {
                for code in codes.results ?? [] {
                    if let payload = code.payloadStringValue, let parsed = ReceiptParser.parseQR(payload) {
                        qr = parsed
                        break
                    }
                }
            }
            if qr == nil { qr = qrInParts(of: cgImage) }
            lines += rows(from: text.results ?? [])
            nameLines += rows(from: words.results ?? [])
        }
        var result = ReceiptParser.merge(qr: qr, text: ReceiptParser.parseText(lines))
        // Names from the pass with the correction of words, prices from the exact pass (the same order of goods in both). When
        // the passes found different numbers of goods, the exact pass is taken as it is: worse names, but with their prices.
        let named = ReceiptParser.itemEntries(in: nameLines)
        let priced = ReceiptParser.itemEntries(in: lines)
        if !named.isEmpty && named.count == priced.count {
            result.goods = zip(named, priced).map { ReceiptGood(name: $0.name, kopecks: $1.kopecks) }
        } else if !priced.isEmpty {
            result.goods = priced
        } else {
            result.goods = named
        }
        result.readLines = lines
        return result
    }

    /// A photographed QR code is small in a picture of a whole receipt: if it was not found in the whole picture, nine
    /// overlapping halves of it are tried, each one larger for Vision than the code is in the whole.
    nonisolated private static func qrInParts(of cgImage: CGImage) -> ParsedReceipt? {
        let width = cgImage.width, height = cgImage.height
        let partWidth = width / 2, partHeight = height / 2
        for row in 0..<3 {
            for column in 0..<3 {
                let rect = CGRect(x: column * (width - partWidth) / 2, y: row * (height - partHeight) / 2, width: partWidth, height: partHeight)
                guard let part = cgImage.cropping(to: rect) else { continue }
                let codes = VNDetectBarcodesRequest()
                codes.symbologies = [.qr]
                try? VNImageRequestHandler(cgImage: part, options: [:]).perform([codes])
                for code in codes.results ?? [] {
                    if let payload = code.payloadStringValue, let parsed = ReceiptParser.parseQR(payload) { return parsed }
                }
            }
        }
        return nil
    }

    /// The pieces of text of one printed row (a title and its sum are read apart) are joined into one line, top to bottom.
    nonisolated private static func rows(from observations: [VNRecognizedTextObservation]) -> [String] {
        let items = observations.compactMap { observation -> (y: CGFloat, x: CGFloat, text: String)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (observation.boundingBox.midY, observation.boundingBox.minX, text)
        }.sorted { $0.y > $1.y }
        var rows: [[(y: CGFloat, x: CGFloat, text: String)]] = []
        for item in items {
            if let first = rows.last?.first, abs(first.y - item.y) < 0.012 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { row in row.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
    }

    nonisolated private static func orientation(_ value: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch value {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}


/// «Собрать чеки для проверки»: the photos of the receipts with what the phone read from each, what the reading made of it and
/// what the owner saved, in one ZIP for the check of the reading. Only receipts that were not collected before.
enum ReceiptDiagnostics {
    struct Collection {
        let data: Data
        let count: Int
        let identities: [String]
    }

    @MainActor
    static func collect(history: SavedHistory) async -> Collection? {
        let done = Set(history.collectedReceiptIdentities ?? [])
        let operations = Dictionary(history.allOperations.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let resolver = ExpenseCategoryResolver(history)
        let queue = (history.receipts ?? [:]).compactMap { identity, files -> (operation: BankOperation, files: [String], date: Date)? in
            guard !done.contains(identity), !files.isEmpty, let operation = operations[identity],
                  let date = BankDateParser.parse(operation.occurredAt) else { return nil }
            return (operation, files, date)
        }.sorted { $0.date < $1.date }
        guard !queue.isEmpty else { return nil }
        var entries: [(name: String, data: Data)] = []
        var identities: [String] = []
        var totalOK = 0, dateOK = 0, untouched = 0, corrected = 0, typed = 0
        for (offset, item) in queue.enumerated() {
            let number = offset + 1
            let identity = item.operation.identity
            let images = item.files.compactMap { ReceiptStore.image(named: $0) }
            guard !images.isEmpty else { continue }
            let read: ParsedReceipt
            let source: String
            if let scan = history.receiptScans?[identity] {
                read = ParsedReceipt(totalKopecks: scan.totalKopecks, date: scan.date, merchant: scan.merchant, goods: scan.goods,
                                     readLines: scan.readLines, dateHasTime: scan.dateHasTime)
                source = "прочитано при добавлении чека"
            } else {
                read = await ReceiptRecognizer.recognize(images)
                source = "перечитано сейчас (чек добавлен раньше, чем приложение стало хранить прочитанное)"
            }
            let goods = history.receiptGoods(forIdentity: identity)
            let verdict = ReceiptCheckReport.verdict(read: read, amountKopecks: item.operation.amountKopecks, date: item.date, goods: goods)
            if verdict.totalMatches { totalOK += 1 }
            if verdict.dateMatches { dateOK += 1 }
            if verdict.goods.hasPrefix("не менялись") { untouched += 1 }
            else if verdict.goods.hasPrefix("исправлены") || verdict.goods.hasPrefix("прочитано") { corrected += 1 }
            else if verdict.goods.hasPrefix("не найдены") { typed += 1 }
            let text = ReceiptCheckReport.text(number: number, read: read, source: source, title: item.operation.description,
                                               category: resolver.resolve(item.operation)?.path, amountKopecks: item.operation.amountKopecks,
                                               date: item.date, goods: goods)
            let base = String(format: "check-%03d", number)
            entries.append((base + ".txt", Data(text.utf8)))
            for (index, file) in item.files.enumerated() {
                if let photo = try? Data(contentsOf: ReceiptStore.folder.appendingPathComponent(file)) {
                    entries.append((index == 0 ? base + ".jpg" : base + "-\(index + 1).jpg", photo))
                }
            }
            identities.append(identity)
        }
        guard !identities.isEmpty else { return nil }
        let summary = [
            "Сбор чеков для проверки чтения. Версия приложения: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
            "Чеков в сборе: \(identities.count)",
            "Сумма совпала: \(totalOK) из \(identities.count)",
            "Дата и время совпали: \(dateOK) из \(identities.count)",
            "Товары: не менялись \(untouched), исправлены вами \(corrected), введены вами без чтения \(typed)",
            "",
            "Каждый чек: check-NNN.txt (сохранено в операции, извлечённое разбором, сравнение, сырой текст) и check-NNN.jpg (фото).",
        ].joined(separator: "\n")
        entries.insert(("index.txt", Data(summary.utf8)), at: 0)
        return Collection(data: ReceiptArchive.make(entries), count: identities.count, identities: identities)
    }
}
