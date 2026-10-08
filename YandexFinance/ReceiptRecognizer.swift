import UIKit
import Vision
import CoreImage

/// Reads a receipt on the phone itself, nothing leaves it: the QR code of a cash receipt and the printed text. What the
/// text means (the sum, the date, the shop) is decided by `ReceiptParser`.
enum ReceiptRecognizer {
    static func recognize(_ images: [UIImage]) async -> ParsedReceipt {
        await Task.detached(priority: .userInitiated) { read(images) }.value
    }

    /// What one reading of a picture gave: the QR code, the rows of the exact pass, the rows of the pass with the correction of words.
    private struct Reading {
        var qr: ParsedReceipt?
        var lines: [String]
        var nameLines: [String]
    }

    nonisolated private static func read(_ images: [UIImage]) -> ParsedReceipt {
        var chosen: [Reading] = []
        for image in images {
            guard let cgImage = image.cgImage else { continue }
            let direction = orientation(image.imageOrientation)
            var best = reading(of: cgImage, orientation: direction)
            // A photo is also read after the receipt is found in it and straightened (as the scanner does): the one that gives
            // more (sum, date and time, prices that add up, QR) is taken; the original wins a tie.
            if let flat = straightened(cgImage, orientation: direction) {
                let other = reading(of: flat, orientation: .up)
                if score(other) > score(best) { best = other }
            }
            chosen.append(best)
        }
        return assemble(Reading(qr: chosen.compactMap(\.qr).first, lines: chosen.flatMap(\.lines), nameLines: chosen.flatMap(\.nameLines)))
    }

    nonisolated private static func reading(of cgImage: CGImage, orientation: CGImagePropertyOrientation) -> Reading {
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
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try? handler.perform([text, words, codes])
        var qr: ParsedReceipt?
        for code in codes.results ?? [] {
            if let payload = code.payloadStringValue, let parsed = ReceiptParser.parseQR(payload) {
                qr = parsed
                break
            }
        }
        if qr == nil { qr = qrInParts(of: cgImage) }
        return Reading(qr: qr, lines: rows(from: text.results ?? []), nameLines: rows(from: words.results ?? []))
    }

    /// Names from the pass with the correction of words, prices from the exact pass (the same order of goods in both). When the
    /// passes found different numbers of goods, the exact pass is taken as it is: worse names, but with their prices.
    nonisolated private static func assemble(_ reading: Reading) -> ParsedReceipt {
        var result = ReceiptParser.merge(qr: reading.qr, text: ReceiptParser.parseText(reading.lines))
        let named = ReceiptParser.itemEntries(in: reading.nameLines)
        let priced = ReceiptParser.itemEntries(in: reading.lines, expectedTotal: result.totalKopecks)
        if let paired = ReceiptParser.pairGoods(named: named, priced: priced) {
            result.goods = paired
        } else if !priced.isEmpty {
            result.goods = priced
        } else {
            result.goods = named
        }
        result.readLines = reading.lines
        return result
    }

    /// How much a reading gave: the QR code, the sum, the date with its time, the prices, and above all prices that add up to the sum.
    nonisolated private static func score(_ reading: Reading) -> Int {
        let parsed = assemble(reading)
        var points = 0
        if reading.qr != nil { points += 5 }
        if parsed.totalKopecks != nil { points += 3 }
        if parsed.date != nil { points += parsed.dateHasTime ? 3 : 1 }
        points += min(parsed.goods.filter { $0.kopecks != nil }.count, 6)
        if ReceiptParser.goodsSumNote(parsed.goods, expectedKopecks: parsed.totalKopecks)?.adds == true { points += 10 }
        return points
    }

    /// The receipt found in a photo and straightened, or nil when none was found. A photo taken at an angle puts the right column
    /// of sums at the height of other rows and makes the QR code small and skew.
    nonisolated private static func straightened(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        let request = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:]).perform([request])
        guard let found = request.results?.first, found.confidence > 0.5 else { return nil }
        let image = CIImage(cgImage: cgImage).oriented(orientation)
        let extent = image.extent
        func point(_ corner: CGPoint) -> CIVector {
            CIVector(x: extent.origin.x + corner.x * extent.width, y: extent.origin.y + corner.y * extent.height)
        }
        let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(found.topLeft), "inputTopRight": point(found.topRight),
            "inputBottomLeft": point(found.bottomLeft), "inputBottomRight": point(found.bottomRight),
        ])
        guard corrected.extent.width >= 300, corrected.extent.height >= 300 else { return nil }
        return CIContext().createCGImage(corrected, from: corrected.extent)
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
            // Only names the app itself makes are read from the receipts folder.
            let valid = files.filter { ReceiptLogic.isValid(fileName: $0) }
            guard !done.contains(identity), !valid.isEmpty, let operation = operations[identity],
                  let date = BankDateParser.parse(operation.occurredAt) else { return nil }
            return (operation, valid, date)
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
