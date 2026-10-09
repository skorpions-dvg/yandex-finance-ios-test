import SwiftUI
import CryptoKit
import LocalAuthentication
import Security

enum PinCheck: Equatable {
    case accepted
    case wrong(left: Int)
    case lockedOut(seconds: Int)
    /// The record of the code cannot be read now (an error of the Keychain) or is lost or damaged: the code is not accepted.
    case unavailable
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

    /// «No record» only for errSecItemNotFound: any other error of the Keychain is not a missing code.
    static func read() -> (state: PinStoreRead, record: PinRecord?) {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return (.notFound, nil) }
        guard status == errSecSuccess, let data = item as? Data else { return (.unavailable, nil) }
        guard let record = try? JSONDecoder().decode(PinRecord.self, from: data) else { return (.damaged, nil) }
        return (.found, record)
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
    /// The Face ID request in progress; it is cancelled when the code is entered first, or it would pop up over the app.
    private var biometricContext: LAContext?
    /// The record of the code is lost or damaged: only «Забыли код?» (the phone's own passcode) opens the app.
    @Published private(set) var needsReset = false
    /// The Keychain did not answer (for example the app was started before the first unlock): read it again on coming back.
    private var needsRetry = false
    /// A code was set on this phone; kept apart from the Keychain, so a lost record is not taken for «no code».
    private static let pinFlag = "pinWasSet"

    init() {
        let start = Self.readStart()
        hasPIN = start.hasPIN
        isLocked = start.locked
        needsRetry = start.needsRetry
        needsReset = start.needsReset
        biometricsEnabled = start.hasPIN && UserDefaults.standard.bool(forKey: "lockBiometrics")
        // The first version asked at once after every minimize; since this one the default is «only at launch».
        if UserDefaults.standard.integer(forKey: "lockSettingsVersion") < 2 {
            UserDefaults.standard.set(-1, forKey: "lockAfterSeconds")
            UserDefaults.standard.set(2, forKey: "lockSettingsVersion")
        }
        lockAfterSeconds = UserDefaults.standard.object(forKey: "lockAfterSeconds") as? Int ?? -1
    }

    /// Reads the Keychain and decides (`AppLockLogic.start`); a found record also marks that a code is set (the versions
    /// before 46.39 kept no such mark).
    private static func readStart() -> LockStart {
        let read = PinKeychain.read()
        if read.state == .found { UserDefaults.standard.set(true, forKey: pinFlag) }
        return AppLockLogic.start(store: read.state, pinWasSet: UserDefaults.standard.bool(forKey: pinFlag))
    }

    /// The Keychain did not answer at launch: read it again. It opens the app only when there is truly no code.
    private func retryStore() {
        let start = Self.readStart()
        needsRetry = start.needsRetry
        needsReset = start.needsReset
        hasPIN = start.hasPIN
        if !start.locked { isLocked = false }
        let biometrics = start.hasPIN && UserDefaults.standard.bool(forKey: "lockBiometrics")
        if biometricsEnabled != biometrics { biometricsEnabled = biometrics }
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
        UserDefaults.standard.set(true, forKey: Self.pinFlag)
        hasPIN = true
        needsReset = false
        needsRetry = false
        return true
    }

    func removePIN() {
        PinKeychain.delete()
        UserDefaults.standard.set(false, forKey: Self.pinFlag)
        needsReset = false
        needsRetry = false
        hasPIN = false
        isLocked = false
        biometricsEnabled = false
    }

    /// Checks a code; a wrong one counts, and after several the app makes a growing pause.
    func check(_ pin: String, unlock: Bool = true) -> PinCheck {
        let read = PinKeychain.read()
        guard read.state == .found, var record = read.record else {
            // Until 46.39 a record that could not be read accepted any code.
            if AppLockLogic.checkWithoutRecord(store: read.state, pinWasSet: UserDefaults.standard.bool(forKey: Self.pinFlag)) {
                if unlock { isLocked = false }
                return .accepted
            }
            if read.state == .unavailable { needsRetry = true } else { needsReset = true }
            return .unavailable
        }
        let now = Date()
        if let until = record.lockedUntil, until > now {
            return .lockedOut(seconds: Int(until.timeIntervalSince(now).rounded(.up)))
        }
        if Self.hash(pin: pin, salt: record.salt) == record.hash {
            record.failures = 0
            record.lockedUntil = nil
            PinKeychain.save(record)
            if unlock {
                cancelBiometrics()
                isLocked = false
            }
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
        if !deviceOwner { biometricContext = context }
        let accepted = (try? await context.evaluatePolicy(policy, localizedReason: reason)) ?? false
        if biometricContext === context { biometricContext = nil }
        return accepted
    }

    func cancelBiometrics() {
        biometricContext?.invalidate()
        biometricContext = nil
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
        if needsRetry { retryStore() }
        guard hasPIN, !isLocked, let left = backgroundedAt else { return }
        backgroundedAt = nil
        if AppLockLogic.shouldLock(backgroundedAt: left, now: Date(), afterSeconds: lockAfterSeconds) { isLocked = true }
    }
}
