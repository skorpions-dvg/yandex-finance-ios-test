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
    static func photoFiles() throws -> [String] {
        try ReceiptArchive.photoFileNames { try FileManager.default.contentsOfDirectory(atPath: folder.path) }
    }

    /// All photos as one ZIP, for a backup; nil when there are none.
    static func exportArchive(only: Set<String>? = nil) throws -> (data: Data, count: Int, skipped: Int)? {
        var entries: [(name: String, data: Data)] = []
        let names = try photoFiles().filter { only?.contains($0) ?? true }.sorted()
        guard !names.isEmpty else { return nil }
        for name in names {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { entries.append((name, data)) }
        }
        return (ReceiptArchive.make(entries), entries.count, names.count - entries.count)
    }

    /// Existing files stay; every entry is counted, including invalid images and failed writes.
    /// nil means the file is not a valid archive of this app.
    static func restoreArchive(_ zip: Data) -> ReceiptLogic.ReceiptRestoreResult? {
        guard let entries = ReceiptArchive.read(zip) else { return nil }
        var result = ReceiptLogic.ReceiptRestoreResult()
        for entry in entries {
            guard ReceiptLogic.isValid(fileName: entry.name) else { result.damaged += 1; continue }
            guard UIImage(data: entry.data) != nil else { result.damaged += 1; continue }
            let url = folder.appendingPathComponent(entry.name)
            if FileManager.default.fileExists(atPath: url.path) { result.alreadyExisted += 1; continue }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try entry.data.write(to: url, options: [.atomic, .completeFileProtection])
                result.added += 1
            } catch { result.notWritten += 1 }
        }
        return result
    }

    static func delete(_ names: [String]) {
        for name in names where ReceiptLogic.isValid(fileName: name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
