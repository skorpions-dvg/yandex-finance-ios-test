import Foundation
import CryptoKit
import Security

// A separate iPhone vault; Windows DPAPI databases cannot be copied here.
struct Vault {
    private let service = "YandexFinance.LocalVault.v1"
    private let account = "encryption-key"

    private func supportFolder() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        var folder = base.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }

    private func recoveryKeyURL() throws -> URL {
        try supportFolder().appendingPathComponent("vault-key.bin")
    }

    private func fileURL() throws -> URL {
        try supportFolder().appendingPathComponent("operations.encrypted")
    }

    private func key(create: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecSuccess, let bytes = result as? Data {
            guard bytes.count == 32 else { throw AppFailure(message: "Неверный ключ хранилища.") }
            try? bytes.write(to: recoveryKeyURL(), options: [.atomic, .completeFileProtection])
            return SymmetricKey(data: bytes)
        }

        let recoveryURL = try recoveryKeyURL()
        if let bytes = try? Data(contentsOf: recoveryURL), bytes.count == 32 {
            return SymmetricKey(data: bytes)
        }

        guard code == errSecItemNotFound, create else {
            throw AppFailure(message: "Ключ хранилища недоступен. Код: \(code).")
        }
        let existingHistory = try fileURL()
        if FileManager.default.fileExists(atPath: existingHistory.path) {
            throw AppFailure(message: "Ключ хранилища отсутствует. Существующая локальная история сохранена и не будет перезаписана.")
        }
        let newKey = SymmetricKey(size: .bits256)
        let bytes = newKey.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account,
                                  kSecValueData as String: bytes,
                                  kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw AppFailure(message: "Не удалось сохранить ключ. Код: \(added).") }
        try bytes.write(to: recoveryKeyURL(), options: [.atomic, .completeFileProtection])
        return newKey
    }

    func load() throws -> SavedHistory {
        let file = try fileURL()
        guard FileManager.default.fileExists(atPath: file.path) else { return SavedHistory() }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
        let decoded = try AES.GCM.open(box, using: key(create: false))
        return try JSONDecoder().decode(SavedHistory.self, from: decoded)
    }


    func reset() throws {
        let file = try fileURL()
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        let recoveryURL = try recoveryKeyURL()
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            try FileManager.default.removeItem(at: recoveryURL)
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let code = SecItemDelete(query as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else {
            throw AppFailure(message: "Не удалось удалить ключ хранилища. Код: \(code).")
        }
    }

    func save(_ history: SavedHistory) throws {
        let bytes = try JSONEncoder().encode(history)
        let box = try AES.GCM.seal(bytes, using: key(create: true))
        guard let combined = box.combined else { throw AppFailure(message: "Ошибка шифрования.") }
        try combined.write(to: fileURL(), options: [.atomic, .completeFileProtection])
    }
}
