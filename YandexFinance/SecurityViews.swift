import SwiftUI

/// A key: it darkens and shrinks a little while it is pressed.
struct PinKeyStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.34 : (filled ? 0.10 : 0))))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Moves the view from side to side; every whole step of `shakes` is one shake.
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 12
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(shakes * .pi * 4), y: 0))
    }
}

/// A round keypad for four digits; the caller decides what a complete code means.
struct PinPad: View {
    let title: String
    var message: String? = nil
    var showsFaceID = false
    var onFaceID: () -> Void = {}
    /// Grows with every wrong code: the dots shake and the phone vibrates.
    var errorCount = 0
    let onComplete: (String) -> Void
    @State private var entry = ""
    @State private var shake: CGFloat = 0

    var body: some View {
        VStack(spacing: 24) {
            Text(title).font(.title3.weight(.semibold))
            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < entry.count ? Color.primary : Color.primary.opacity(0.2))
                        .frame(width: 14, height: 14)
                        .scaleEffect(index < entry.count ? 1.25 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: entry.count)
                }
            }
            .modifier(ShakeEffect(shakes: shake))
            Text(message ?? " ")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(height: 36)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 18), count: 3), spacing: 14) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9"], id: \.self) { digit in key(digit) }
                if showsFaceID {
                    Button(action: onFaceID) {
                        Image(systemName: "faceid").font(.title2).frame(width: 76, height: 76)
                    }
                    .buttonStyle(PinKeyStyle(filled: false))
                    .accessibilityLabel("Войти по Face ID")
                } else {
                    Color.clear.frame(width: 76, height: 76)
                }
                key("0")
                Button {
                    if !entry.isEmpty {
                        entry.removeLast()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                } label: {
                    Image(systemName: "delete.left").font(.title3).frame(width: 76, height: 76)
                }
                .buttonStyle(PinKeyStyle(filled: false))
                .accessibilityLabel("Стереть последнюю цифру")
            }
        }
        .onChange(of: errorCount) { _, _ in
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            withAnimation(.linear(duration: 0.45)) { shake += 1 }
        }
    }

    private func key(_ digit: String) -> some View {
        Button { press(digit) } label: {
            Text(digit)
                .font(.title)
                .frame(width: 76, height: 76)
        }
        .buttonStyle(PinKeyStyle())
    }

    private func press(_ digit: String) {
        guard entry.count < 4 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        entry.append(digit)
        guard entry.count == 4 else { return }
        let code = entry
        // The fourth dot is seen for a moment before the code is checked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            entry = ""
            onComplete(code)
        }
    }
}

/// Covers the whole app while it is locked: the code, or Face ID if it is on.
@MainActor
struct LockScreenView: View {
    @ObservedObject var lock: AppLock
    @State private var message: String?
    @State private var errors = 0

    var body: some View {
        ZStack {
            LockBackground()
            VStack(spacing: 28) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                PinPad(title: "Введите код", message: message,
                       showsFaceID: lock.biometricsEnabled && lock.biometricsAvailable,
                       onFaceID: { Task { await lock.unlockWithBiometrics() } },
                       errorCount: errors,
                       onComplete: { code in
                    switch lock.check(code) {
                    case .accepted:
                        message = nil
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    case .wrong(let left):
                        message = "Неверный код. Осталось попыток до паузы: \(left)"
                        errors += 1
                    case .lockedOut(let seconds):
                        message = "Слишком много попыток. Подождите \(seconds) с."
                        errors += 1
                    case .unavailable:
                        message = unavailableMessage
                        errors += 1
                    }
                })
                Button("Забыли код?") {
                    Task { if await lock.resetWithDeviceOwner() { message = nil } else { message = "Код телефона не подтверждён." } }
                }
                .font(.footnote)
            }
            .padding(24)
        }
        .environment(\.colorScheme, .dark)
        // Face ID is asked at once, and again every time the app locks.
        .task(id: lock.isLocked) { if lock.isLocked { await lock.unlockWithBiometrics() } }
        .onAppear { if lock.needsReset { message = unavailableMessage } }
    }

    private var unavailableMessage: String {
        lock.needsReset ? "Запись кода повреждена. Нажмите «Забыли код?» и подтвердите кодом телефона."
                        : "Код сейчас недоступен. Разблокируйте телефон и откройте приложение снова или нажмите «Забыли код?»."
    }
}

/// The wallpaper of the app, dimmed, behind the code and in the switcher of apps.
struct LockBackground: View {
    var body: some View {
        ZStack {
            WallpaperBackground()
            Color.black.opacity(0.35).ignoresSafeArea()
        }
    }
}

/// What the switcher of apps shows while the app is not active and a code is set: nothing of the finances.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            LockBackground()
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Set, change or switch off the code: the old code is asked first, a new one twice.
@MainActor
struct PinFlowView: View {
    enum Flow: String, Identifiable {
        case setup, change, disable
        var id: String { rawValue }
    }

    @ObservedObject var lock: AppLock
    let flow: Flow
    @Environment(\.dismiss) private var dismiss
    private enum Step { case old, new, confirm }
    @State private var step: Step
    @State private var firstEntry = ""
    @State private var message: String?
    @State private var errors = 0

    init(lock: AppLock, flow: Flow) {
        self.lock = lock
        self.flow = flow
        _step = State(initialValue: flow == .setup ? .new : .old)
    }

    private var title: String {
        switch step {
        case .old: return flow == .disable ? "Введите код, чтобы выключить" : "Введите текущий код"
        case .new: return "Введите новый код"
        case .confirm: return "Повторите код"
        }
    }

    var body: some View {
        NavigationStack {
            PinPad(title: title, message: message, errorCount: errors, onComplete: handle)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .navigationTitle("Код-пароль")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Отмена", systemImage: "xmark") { dismiss() } }
                }
        }
    }

    private func handle(_ pin: String) {
        switch step {
        case .old:
            switch lock.check(pin, unlock: false) {
            case .accepted:
                if flow == .disable {
                    lock.removePIN()
                    dismiss()
                } else {
                    step = .new
                    message = nil
                }
            case .wrong(let left):
                message = "Неверный код. Осталось попыток до паузы: \(left)"
                errors += 1
            case .lockedOut(let seconds):
                message = "Слишком много попыток. Подождите \(seconds) с."
                errors += 1
            case .unavailable:
                message = "Код сейчас недоступен. Закройте и откройте приложение снова."
                errors += 1
            }
        case .new:
            firstEntry = pin
            step = .confirm
            message = nil
        case .confirm:
            if pin == firstEntry {
                if lock.setPIN(pin) { dismiss() } else { message = "Не удалось сохранить код." }
            } else {
                firstEntry = ""
                step = .new
                message = "Коды не совпали, введите заново."
                errors += 1
            }
        }
    }
}

/// «Настройки → Безопасность».
@MainActor
struct SecuritySettingsView: View {
    @ObservedObject var lock: AppLock
    @State private var flow: PinFlowView.Flow?

    private var faceID: Binding<Bool> {
        Binding(get: { lock.biometricsEnabled }, set: { enabled in
            if enabled {
                Task { if await lock.authenticate(reason: "Включить Face ID для Horizon", deviceOwner: false) { lock.biometricsEnabled = true } }
            } else {
                lock.biometricsEnabled = false
            }
        })
    }

    var body: some View {
        List {
            Section {
                if lock.hasPIN {
                    Button("Сменить код") { flow = .change }
                    Button("Выключить код", role: .destructive) { flow = .disable }
                } else {
                    Button("Включить код из 4 цифр") { flow = .setup }
                }
            } header: {
                Text("Код-пароль")
            } footer: {
                Text(lock.hasPIN ? "Код спрашивается при открытии приложения. Забыли код — на экране ввода есть «Забыли код?»: приложение попросит код или Face ID самого телефона."
                                 : "Приложение будет спрашивать код при открытии и скрывать содержимое в переключателе приложений.")
            }.glassRows()
            if lock.hasPIN {
                Section {
                    Toggle("Face ID", isOn: faceID).disabled(!lock.biometricsAvailable)
                    Picker("Блокировать", selection: $lock.lockAfterSeconds) {
                        Text("Только при запуске").tag(-1)
                        Text("Сразу").tag(0)
                        Text("Через 1 минуту").tag(60)
                        Text("Через 5 минут").tag(300)
                        Text("Через 15 минут").tag(900)
                    }
                } footer: {
                    Text("Face ID открывает приложение вместо кода; если он не узнал, можно ввести код. «Блокировать» — через сколько после выхода из приложения снова спрашивать код.")
                }.glassRows()
            }
        }
        .appSurface()
        .navigationTitle("Безопасность")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $flow) { PinFlowView(lock: lock, flow: $0) }
    }
}
