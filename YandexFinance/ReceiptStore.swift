import UIKit

/// Receipt photos as files in the app's own folder (not in the history: the history is encrypted and small).
/// The file protection keeps them unreadable while the phone is locked.
enum ReceiptStore {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Receipts", isDirectory: true)
    }

    /// Fits the photo into `ReceiptLogic.maxSide`, saves it as JPEG and returns the file name.
    static func save(_ image: UIImage) -> String? {
        let fitted = ReceiptLogic.scaledSize(width: Double(image.size.width * image.scale), height: Double(image.size.height * image.scale))
        guard fitted.width > 0, fitted.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: fitted.width, height: fitted.height)
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = scaled.jpegData(compressionQuality: 0.7) else { return nil }
        let name = ReceiptLogic.fileName()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
            return name
        } catch {
            return nil
        }
    }

    static func image(named name: String) -> UIImage? {
        guard ReceiptLogic.isValid(fileName: name) else { return nil }
        return UIImage(contentsOfFile: folder.appendingPathComponent(name).path)
    }

    static func delete(_ names: [String]) {
        for name in names where ReceiptLogic.isValid(fileName: name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
