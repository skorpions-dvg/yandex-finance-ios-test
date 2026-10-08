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

    /// The names of the photo files on this phone.
    static var allFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { ReceiptLogic.isValid(fileName: $0) }
    }

    /// All photos as one ZIP, for a backup; nil when there are none.
    static func exportArchive() -> (data: Data, count: Int)? {
        var entries: [(name: String, data: Data)] = []
        for name in allFiles.sorted() {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { entries.append((name, data)) }
        }
        return entries.isEmpty ? nil : (ReceiptArchive.make(entries), entries.count)
    }

    /// Puts the photos of an archive back; files that are already here stay. Returns how many were added, nil when the
    /// file is not an archive of this app.
    static func restoreArchive(_ zip: Data) -> Int? {
        guard let entries = ReceiptArchive.read(zip) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var added = 0
        for entry in entries where ReceiptLogic.isValid(fileName: entry.name) && UIImage(data: entry.data) != nil {
            let url = folder.appendingPathComponent(entry.name)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            if (try? entry.data.write(to: url, options: [.atomic, .completeFileProtection])) != nil { added += 1 }
        }
        return added
    }

    static func delete(_ names: [String]) {
        for name in names where ReceiptLogic.isValid(fileName: name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
