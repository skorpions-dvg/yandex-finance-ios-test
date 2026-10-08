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
        for image in images {
            guard let cgImage = image.cgImage else { continue }
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.recognitionLanguages = ["ru-RU", "en-US"]
            text.usesLanguageCorrection = false
            let codes = VNDetectBarcodesRequest()
            codes.symbologies = [.qr]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation(image.imageOrientation), options: [:])
            try? handler.perform([text, codes])
            if qr == nil {
                for code in codes.results ?? [] {
                    if let payload = code.payloadStringValue, let parsed = ReceiptParser.parseQR(payload) {
                        qr = parsed
                        break
                    }
                }
            }
            lines += rows(from: text.results ?? [])
        }
        return ReceiptParser.merge(qr: qr, text: ReceiptParser.parseText(lines))
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
