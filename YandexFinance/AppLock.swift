import SwiftUI
import CryptoKit
import LocalAuthentication
import Security

enum PinCheck: Equatable {
    case accepted
    case wrong(left: Int)
    case lockedOut(seconds: Int)
}

/// The PIN as it is kept in the Keychain: never the code itself, only a salted hash, the failed attempts and the pause.
private struct PinRecord: Codable {
    var salt: Data
    var hash: Data
    var failures: Int
    var lockedUntil: Date?
}

private enum PinKeychain {
    static let service = "FinanceTest.applock"
    static let account = "pin"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> PinRecord? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PinRecord.self, from: data)
    }

    @discardableResult
    static func save(_ record: PinRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        // Readable after the first unlock, so a launch in the background with a locked phone still finds the code.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}

/// The lock of the app: a four-digit code in the Keychain and Face ID on top of it. It locks the interface; the
/// history stays encrypted by the vault as before.
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published private(set) var hasPIN: Bool
    @Published var biometricsEnabled: Bool {
        didSet { UserDefaults.standard.set(biometricsEnabled, forKey: "lockBiometrics") }
    }
    /// Seconds in the background after which the app asks for the code again; 0 — at once, -1 — only at launch.
    @Published var lockAfterSeconds: Int {
        didSet { UserDefaults.standard.set(lockAfterSeconds, forKey: "lockAfterSeconds") }
    }
    /// True while the system asks for Face ID and shortly after: the cover for the switcher of apps must not appear then.
    @Published private(set) var coverSuppressed = false
    private var suppressTask: Task<Void, Never>?
    private var backgroundedAt: Date?

    init() {
        let stored = PinKeychain.load() != nil
        hasPIN = stored
        isLocked = stored
        biometricsEnabled = stored && UserDefaults.standard.bool(forKey: "lockBiometrics")
        // The first version asked at once after every minimize; since this one the default is «only at launch».
        if UserDefaults.standard.integer(forKey: "lockSettingsVersion") < 2 {
            UserDefaults.standard.set(-1, forKey: "lockAfterSeconds")
            UserDefaults.standard.set(2, forKey: "lockSettingsVersion")
        }
        lockAfterSeconds = UserDefaults.standard.object(forKey: "lockAfterSeconds") as? Int ?? -1
    }

    var biometricsAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private static func hash(pin: String, salt: Data) -> Data {
        var digest = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        for _ in 0..<20_000 { digest = Data(SHA256.hash(data: digest + salt)) }
        return digest
    }

    @discardableResult
    func setPIN(_ pin: String) -> Bool {
        guard AppLockLogic.isValid(pin: pin) else { return false }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        guard PinKeychain.save(PinRecord(salt: salt, hash: Self.hash(pin: pin, salt: salt), failures: 0, lockedUntil: nil)) else { return false }
        hasPIN = true
        return true
    }

    func removePIN() {
        PinKeychain.delete()
        hasPIN = false
        isLocked = false
        biometricsEnabled = false
    }

    /// Checks a code; a wrong one counts, and after several the app makes a growing pause.
    func check(_ pin: String, unlock: Bool = true) -> PinCheck {
        guard var record = PinKeychain.load() else { return .accepted }
        let now = Date()
        if let until = record.lockedUntil, until > now {
            return .lockedOut(seconds: Int(until.timeIntervalSince(now).rounded(.up)))
        }
        if Self.hash(pin: pin, salt: record.salt) == record.hash {
            record.failures = 0
            record.lockedUntil = nil
            PinKeychain.save(record)
            if unlock { isLocked = false }
            return .accepted
        }
        record.failures += 1
        let delay = AppLockLogic.lockoutSeconds(afterFailures: record.failures)
        if delay > 0 { record.lockedUntil = now.addingTimeInterval(Double(delay)) }
        PinKeychain.save(record)
        return delay > 0 ? .lockedOut(seconds: delay) : .wrong(left: max(0, AppLockLogic.attemptsBeforePause - record.failures))
    }

    private func restoreCoverSoon() {
        suppressTask?.cancel()
        suppressTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { coverSuppressed = false }
        }
    }

    func authenticate(reason: String, deviceOwner: Bool) async -> Bool {
        coverSuppressed = true
        defer { restoreCoverSoon() }
        let context = LAContext()
        let policy: LAPolicy = deviceOwner ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else { return false }
        return (try? await context.evaluatePolicy(policy, localizedReason: reason)) ?? false
    }

    func unlockWithBiometrics() async {
        guard isLocked, biometricsEnabled else { return }
        if await authenticate(reason: "Открыть Horizon", deviceOwner: false) { isLocked = false }
    }

    /// «Forgot the code»: the passcode or Face ID of the phone itself switches the code off, so access is never lost.
    func resetWithDeviceOwner() async -> Bool {
        guard await authenticate(reason: "Сбросить код приложения", deviceOwner: true) else { return false }
        removePIN()
        return true
    }

    func enteredBackground() {
        guard hasPIN else { return }
        backgroundedAt = Date()
    }

    func becameActive() {
        guard hasPIN, !isLocked, let left = backgroundedAt else { return }
        backgroundedAt = nil
        if AppLockLogic.shouldLock(backgroundedAt: left, now: Date(), afterSeconds: lockAfterSeconds) { isLocked = true }
    }
}
