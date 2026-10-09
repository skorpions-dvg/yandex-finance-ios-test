# Задание для Gemini — экран приветствия Horizon (блок 5)

Скопируйте весь текст ниже в Gemini и приложите картинку значка `AppIcon.png`
(в папке проекта: `YandexFinance/Assets.xcassets/AppIcon.appiconset/AppIcon.png`).

---

Ты — дизайнер анимации и iOS-разработчик (SwiftUI). Нужен экран приветствия для личного финансового приложения Horizon (iPhone, iOS 26–27, тёмная тема). Приложение на картинке — его значок: стеклянная кольцевая диаграмма из шести сегментов разной длины на тёмно-синем фоне и яркая линия горизонта через центр со вспышками по краям.

Пожелания владельца: «диаграмма с иконки почти на весь экран, анимированная; анимации при открытии и при закрытии приветствия; фон из иконки с горизонтом». Посмотри, как делают вход банки и похожие приложения (Тинькофф/Т-Банк, Сбер, Revolut, Monzo, Apple Wallet) — возьми лучшее, но без копирования чужого стиля.

Ограничения:
1. Только SwiftUI из коробки (Shape, Circle().trim, градиенты, blur, shadow, blendMode, TimelineView/Canvas — если нужно); без сторонних библиотек, без Lottie, без картинок кроме самого значка (лучше рисовать кодом).
2. Одна структура `SplashView: View` с тем же интерфейсом: `init(ready: Bool, active: Bool, onFinish: @escaping () -> Void)`. `active` — приложение на экране (анимация начинается только тогда); `ready` — данные прочитаны; закрыть — вызвать `onFinish()` (сверху приложение плавно уберёт экран). Касание закрывает сразу.
3. Время: приветствие не короче 1,2 с; после `ready` — ещё ~0,8 с видимого показа; анимация ухода ≤ 0,4 с. Важно: при запуске телефон около секунды занят отрисовкой экранов под приветствием — длинные анимации на старте могут «подвиснуть», ставь главное после первых 0,3–0,5 с.
4. «Уменьшение движения» (`accessibilityReduceMotion`): без движения, только плавное появление.
5. Цвета — из значка (тёмно-синий фон ≈ RGB 0.02/0.05/0.13, синие и голубые стёкла, белая линия). Экран запуска приложения уже такого же тёмно-синего цвета.
6. Название «Horizon» на экране есть (шрифт можно предложить).

Что прислать:
1. Короткое описание концепции и раскадровку по времени (что происходит на 0,0 / 0,3 / 0,6 / 1,0 с … и при уходе).
2. Полный код `SplashView` (Swift, компилируется без правок), с комментариями.
3. Что в нашем текущем варианте (ниже) хуже твоего и почему.

Наш текущий вариант (для сравнения, его можно улучшать):

```swift
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
                RadialGradient(colors: [Self.navy, Self.deep], center: .center, startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) * 0.65)
                Ellipse()
                    .fill(Self.cyan.opacity(0.16))
                    .frame(width: geometry.size.width * 1.3, height: side * 0.32)
                    .blur(radius: 36)
                    .opacity(Double(horizon))
                ring(side: side, band: band)
                    .scaleEffect(leaving ? 1.4 : (reduceMotion || settled ? 1 : 0.9))
                    .rotationEffect(.degrees(reduceMotion || settled ? 0 : -28))
                    .opacity(leaving ? 0 : 1)
                horizonLine(length: geometry.size.width, side: side, band: band)
                Text("Horizon")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)
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
            ForEach(0..<6, id: \.self) { index in
                let arc = Self.arcs[index]
                let end = shown[index] ? arc.to : arc.from
                Circle()
                    .trim(from: arc.from, to: end)
                    .stroke(LinearGradient(colors: [Self.cyan.opacity(0.55), Self.blue.opacity(0.35)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: band, lineCap: .butt))
                    .frame(width: side, height: side)
                // The light edges of the glass: outside and inside.
                Circle()
                    .trim(from: arc.from, to: end)
                    .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.5))
                    .frame(width: side + band - 1.5, height: side + band - 1.5)
                Circle()
                    .trim(from: arc.from, to: end)
                    .stroke(Self.cyan.opacity(0.55), style: StrokeStyle(lineWidth: 1))
                    .frame(width: side - band + 1, height: side - band + 1)
            }
        }
        .rotationEffect(.degrees(-90))
        .shadow(color: Self.cyan.opacity(glow ? 0.55 : 0.2), radius: glow ? 32 : 14)
    }

    /// The line of the horizon across the screen, with flares where it meets the ring.
    private func horizonLine(length: CGFloat, side: CGFloat, band: CGFloat) -> some View {
        ZStack {
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
                    .offset(x: direction * (side / 2 + band / 2))
                    .opacity(Double(horizon))
            }
        }
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
```
