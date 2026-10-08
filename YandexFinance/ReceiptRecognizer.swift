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
        let corrected = ReceiptParser.items(in: nameLines)
        if !corrected.isEmpty { result.items = corrected }
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
