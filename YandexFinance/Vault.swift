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

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func keychainKey() -> (code: OSStatus, bytes: Data?) {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        guard code == errSecSuccess, let bytes = result as? Data, bytes.count == 32 else { return (code, nil) }
        return (code, bytes)
    }

    private func recoveryKey() -> Data? {
        guard let url = try? recoveryKeyURL(), let bytes = try? Data(contentsOf: url), bytes.count == 32 else { return nil }
        return bytes
    }

    /// Keys worth trying for the existing history: the container copy first, because it survives
    /// re-signing in AltStore, then the Keychain item, which belongs to the signing identity.
    private func candidateKeys() -> [Data] {
        var keys: [Data] = []
        for bytes in [recoveryKey(), keychainKey().bytes].compactMap({ $0 }) where !keys.contains(bytes) {
            keys.append(bytes)
        }
        return keys
    }

    /// Called only after a key has actually decrypted the history: keep both copies on that key.
    private func remember(_ bytes: Data) {
        if recoveryKey() != bytes, let url = try? recoveryKeyURL() {
            try? bytes.write(to: url, options: [.atomic, .completeFileProtection])
        }
        let stored = keychainKey()
        if stored.bytes == bytes { return }
        if stored.code == errSecItemNotFound {
            var add = keychainQuery
            add[kSecValueData as String] = bytes
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        } else {
            SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        }
    }

    private func key(create: Bool) throws -> SymmetricKey {
        // Never overwrite a stored key here: a key is only copied over after it has opened the history.
        if let bytes = recoveryKey() ?? keychainKey().bytes {
            return SymmetricKey(data: bytes)
        }
        let code = keychainKey().code

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
        let candidates = candidateKeys()
        guard !candidates.isEmpty else {
            throw AppFailure(message: "Ключ хранилища недоступен. Код: \(keychainKey().code). Существующая локальная история сохранена и не будет перезаписана.")
        }
        for bytes in candidates {
            guard let decoded = try? AES.GCM.open(box, using: SymmetricKey(data: bytes)) else { continue }
            remember(bytes)
            return try JSONDecoder().decode(SavedHistory.self, from: decoded)
        }
        throw AppFailure(message: "Ни один сохранённый ключ не подходит к локальной истории (проверено ключей: \(candidates.count)). История сохранена и не будет перезаписана. Обычно так бывает после установки через AltStore под другим Apple ID: установите приложение под прежним Apple ID, и ключ вернётся. Не сбрасывайте хранилище, если история нужна.")
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
