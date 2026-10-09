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
    /// False while the greeting of the launch is shown: Face ID is asked after it (46.46 — asked at once, it made the app
    /// inactive and the greeting ran its time unseen behind the launch screen).
    var canAskFaceID = true
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
        .task(id: lock.isLocked && canAskFaceID) { if lock.isLocked && canAskFaceID { await lock.unlockWithBiometrics() } }
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

/// The greeting of a cold launch (block 5; redrawn in 46.47 after the owner's sketch): the donut chart of the Horizon icon
/// almost across the screen, drawn segment by segment, the line of the horizon through it and the name, on the dark blue of
/// the icon (the launch screen has the same colour: no flash). It goes 0,8 s after the history is read and the screens under
/// it are drawn, not before 1,2 s; a tap closes it at once. Leaving, the ring grows and melts into the app.
/// Nothing waits for it: the app loads underneath.
@MainActor
struct SplashView: View {
    /// The history is read: the greeting may go.
    let ready: Bool
    /// The app is on the screen: the greeting begins only then (behind Face ID or the launch screen nobody sees it).
    let active: Bool
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which of the six segments are drawn.
    @State private var shown = Array(repeating: false, count: 6)
    /// 0…1: how far the line of the horizon has opened from the middle.
    @State private var horizon: CGFloat = 0
    /// The ring has turned into its place.
    @State private var settled = false
    @State private var titleShown = false
    @State private var glow = false
    @State private var leaving = false
    @State private var finished = false
    /// `ready` as it is now: a task keeps the value of the view it began with, a state is read live.
    @State private var isReady = false
    @State private var started = false

    /// The six segments of the icon clockwise from the top, as shares of the circle, with a thin gap between them.
    private static let arcs: [(from: CGFloat, to: CGFloat)] = {
        var start: CGFloat = 0
        return [0.11, 0.11, 0.14, 0.20, 0.14, 0.30].map { (share: CGFloat) -> (from: CGFloat, to: CGFloat) in
            defer { start += share }
            return (start + 0.006, start + share - 0.006)
        }
    }()
    private static let deep = Color(red: 0.02, green: 0.05, blue: 0.13)
    private static let navy = Color(red: 0.05, green: 0.15, blue: 0.38)
    private static let cyan = Color(red: 0.45, green: 0.78, blue: 1.0)
    private static let blue = Color(red: 0.16, green: 0.38, blue: 0.88)

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height) * 0.80
            let band = side * 0.15
            ZStack {
                // The background of the icon: dark blue, lighter towards the middle, a haze along the horizon.
                // Towards the corners into black: more depth (Gemini's second answer).
                RadialGradient(colors: [Self.navy, Self.deep, .black], center: .center, startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) * 0.7)
                Ellipse()
                    .fill(Self.cyan.opacity(0.16))
                    .frame(width: geometry.size.width * 1.3, height: side * 0.32)
                    .blur(radius: 36)
                    .scaleEffect(glow ? 1.08 : 1)
                    .opacity(Double(horizon))
                ring(side: side, band: band)
                    .scaleEffect(leaving ? 1.4 : (reduceMotion || settled ? 1 : 0.9))
                    .rotationEffect(.degrees(reduceMotion || settled ? 0 : -28))
                    .opacity(leaving ? 0 : 1)
                horizonLine(length: geometry.size.width, side: side, band: band)
                Text("Horizon")
                    .font(.system(size: 32, weight: .medium, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(.white)
                    .shadow(color: Self.cyan.opacity(0.5), radius: 8, y: 3)
                    .offset(y: side / 2 + band / 2 + 44 + (titleShown || reduceMotion ? 0 : 12))
                    .opacity(titleShown && !leaving ? 1 : 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Horizon")
        .onAppear {
            isReady = ready
            if active { start() }
        }
        .onChange(of: active) { _, now in if now { start() } }
        .onChange(of: ready) { _, now in isReady = now }
    }

    /// The donut chart of the icon: six segments of blue glass with light edges.
    private func ring(side: CGFloat, band: CGFloat) -> some View {
        ZStack {
            // The outline of the ring from the very first frame: while the phone is still drawing the screens underneath
            // (46.47: about 0,7 s), the greeting shows the sign instead of an empty background.
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .trim(from: Self.arcs[index].from, to: Self.arcs[index].to)
                    .stroke(Self.cyan.opacity(0.10), style: StrokeStyle(lineWidth: band, lineCap: .butt))
                    .frame(width: side, height: side)
                Circle()
                    .trim(from: Self.arcs[index].from, to: Self.arcs[index].to)
                    .stroke(Self.cyan.opacity(0.28), style: StrokeStyle(lineWidth: 1))
                    .frame(width: side + band - 1.5, height: side + band - 1.5)
            }
            ForEach(0..<6, id: \.self) { index in
                let arc = Self.arcs[index]
                let end = shown[index] ? arc.to : arc.from
                Circle()
                    .trim(from: arc.from, to: end)
                    .stroke(LinearGradient(colors: [Self.cyan.opacity(0.85), Self.blue.opacity(0.55), Self.deep.opacity(0.7)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: band, lineCap: .butt))
                    // Light adds to what is behind it, as through glass (Gemini's second answer).
                    .blendMode(.screen)
                    .frame(width: side, height: side)
                // The light edges of the glass: outside and inside.
                Circle()
                    .trim(from: arc.from, to: end)
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5))
                    .frame(width: side + band - 1.5, height: side + band - 1.5)
                Circle()
                    .trim(from: arc.from, to: end)
                    .stroke(LinearGradient(colors: [.white.opacity(0.75), Self.cyan.opacity(0.35), .clear],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 1.5))
                    .frame(width: side - band + 1.5, height: side - band + 1.5)
            }
        }
        .rotationEffect(.degrees(-90))
        .shadow(color: Self.cyan.opacity(glow ? 0.75 : 0.4), radius: glow ? 36 : 18)
    }

    /// The line of the horizon across the screen, with flares where it meets the ring.
    private func horizonLine(length: CGFloat, side: CGFloat, band: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [.clear, Self.cyan.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: length, height: 1)
            Capsule()
                .fill(Self.cyan)
                .frame(width: length * horizon, height: 8)
                .blur(radius: 8)
                .opacity(0.7)
            Capsule()
                .fill(LinearGradient(colors: [.clear, .white, .white, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: length * horizon, height: leaving ? 4 : 2)
            ForEach([-1.0, 1.0], id: \.self) { direction in
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .blur(radius: 6)
                    .shadow(color: Self.cyan, radius: 10)
                    .offset(x: direction * (side / 2 + band / 2))
                    .opacity(Double(horizon))
            }
        }
        // Leaving, the line draws in to the middle while the ring flies towards the viewer (Gemini's idea).
        .scaleEffect(x: leaving ? 0.01 : 1, y: 1, anchor: .center)
        .opacity(leaving ? 0 : 1)
    }

    /// The animation and the time of the greeting, from the moment the app is on the screen.
    private func start() {
        guard !started else { return }
        started = true
        withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.55)) { horizon = 1 }
        for index in 0..<6 {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.35).delay(0.15 + 0.1 * Double(index))) {
                shown[index] = true
            }
        }
        withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(reduceMotion ? 0 : 0.1)) { settled = true }
        withAnimation(.easeOut(duration: 0.5).delay(reduceMotion ? 0 : 0.7)) { titleShown = true }
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(0.9)) { glow = true }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            // Then the history (4 s at most in all). A task of the main actor resumes only when the main thread is free: the
            // pause after it is time the greeting is really seen, after the first heavy drawing of the screens under it
            // (46.46: the reports and the forecast took the phone for about a second, and the greeting was seen for 0,5 s).
            var waited = 1.2
            while !isReady && waited < 4 {
                try? await Task.sleep(for: .seconds(0.1))
                waited += 0.1
            }
            try? await Task.sleep(for: .seconds(0.8))
            finish()
        }
    }

    /// The ring grows and melts, the line flares, then the greeting goes.
    private func finish() {
        guard !finished else { return }
        finished = true
        if reduceMotion {
            onFinish()
            return
        }
        withAnimation(.easeIn(duration: 0.4)) { leaving = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            onFinish()
        }
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
