import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct YandexFinanceApp: App {
    @StateObject private var browser = BankBrowser()
    @StateObject private var wallpaper = WallpaperStore()
    @StateObject private var lock = AppLock()
    @AppStorage("appearanceTheme") private var appearanceTheme = AppTheme.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(browser: browser)
                    .environmentObject(wallpaper)
                    .environmentObject(lock)
                if lock.isLocked {
                    LockScreenView(lock: lock).environmentObject(wallpaper)
                } else if lock.hasPIN && scenePhase != .active && !lock.coverSuppressed {
                    PrivacyCover().environmentObject(wallpaper)
                }
            }
            .preferredColorScheme(AppTheme(rawValue: appearanceTheme)?.colorScheme)
            .onAppear { if scenePhase == .active { browser.becameActive() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    lock.becameActive()
                    browser.becameActive()
                } else {
                    if phase == .background { lock.enteredBackground() }
                    browser.becameInactive()
                }
            }
        }
    }
}

@MainActor
struct ContentView: View {
    @ObservedObject var browser: BankBrowser
    /// Horizontal page: 0 — accounts drawer, 1 — Операции, 2 — Отчёты, 3 — Настройки.
    @State private var page: Int? = 1
    @State private var selectedTab = 1
    @State private var settingsReset = 0
    @State private var presentation = FinancePresentationCache()
    /// Live page position for the tab bar lens. A reference, so scrolling never re-evaluates this view or its pages.
    @State private var tabProgress = TabBarProgress()
    @State private var tabSelection = TabBarSelection()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Height the floating tab bar takes at the bottom of every page.
    static let barSpace: CGFloat = 56
    var body: some View {
        ZStack(alignment: .top) {
            // The bank page stays in the window behind the tabs so scanning keeps running while it is hidden.
            BankWebView(browser: browser)
                .padding(.top, browser.bankPageVisible ? (browser.signInRequested ? 110 : 52) : 0)
                .allowsHitTesting(browser.bankPageVisible)
                .accessibilityHidden(!browser.bankPageVisible)
            // One opaque wallpaper covers the mounted bank page without hiding its WebView.
            WallpaperBackground()
                .opacity(browser.bankPageVisible ? 0 : 1)
            // The pages run under the tab bar, which floats over them, so their content shows through its glass.
            ZStack(alignment: .bottom) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let drawerWidth = NavigationMotion.drawerWidth(width)
                    // A native paging scroll view moves the screens with the finger on the render server: no SwiftUI
                    // update per frame, and UIKit itself decides between this horizontal swipe and a list's vertical scroll.
                    ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            // Clear Liquid Glass: the wallpaper and the edge of the page show through, nothing is dimmed.
                            AccountsView(browser: browser, onClose: closeAccounts, usesGlass: true)
                                .frame(width: drawerWidth, height: max(0, height - Self.barSpace - 16), alignment: .top)
                                // Clear glass with a grey haze: the wallpaper shows through, the rows stay readable.
                                .glassEffect(.clear.tint(colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.28)), in: .rect(cornerRadius: 28))
                                .clipShape(.rect(cornerRadius: 28))
                                .padding(.horizontal, 8)
                                .padding(.top, 4)
                                .frame(height: height, alignment: .top)
                                .id(0)
                            OperationsHomeView(browser: browser, presentation: presentation, onAccounts: openAccounts,
                                               onHorizontalPan: { _, _, _ in })
                                // Lists scroll under the floating bar and stop with their last row above it.
                                .environment(\.bottomBarSpace, Self.barSpace)
                                .frame(width: width, height: height)
                                .overlay {
                                    // While the accounts are open, a tap on the visible edge of the page closes them.
                                    if page == 0 {
                                        Color.clear.contentShape(Rectangle()).onTapGesture(perform: closeAccounts)
                                    }
                                }
                                .id(1)
                            ReportsView(browser: browser, presentation: presentation)
                                // Lists scroll under the floating bar and stop with their last row above it.
                                .environment(\.bottomBarSpace, Self.barSpace)
                                .frame(width: width, height: height)
                                .id(2)
                            SettingsView(browser: browser, presentation: presentation, resetToken: settingsReset,
                                         onHorizontalPan: { _, _, _ in })
                                // Lists scroll under the floating bar and stop with their last row above it.
                                .environment(\.bottomBarSpace, Self.barSpace)
                                .frame(width: width, height: height)
                                .id(3)
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                    .scrollPosition(id: $page, anchor: .leading)
                    .scrollIndicators(.hidden)
                    .onChange(of: page) { _, newPage in
                        if let newPage, newPage >= 1 { selectedTab = newPage }
                    }
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                        let pagesStart = drawerWidth + 16
                        let value = min(3, max(1, (x - pagesStart) / max(1, width) + 1))
                        tabProgress.value = value
                        let tab = Int(value.rounded())
                        if tabSelection.active != tab { tabSelection.active = tab }
                    }
                    // The first layout starts at the leading edge (the accounts); open on the selected tab instead.
                    .onAppear { proxy.scrollTo(selectedTab, anchor: .leading) }
                    }
                }

                // Close to the bottom edge, just above the home indicator, as in Telegram.
                LensTabBar(progress: tabProgress, selection: tabSelection, reduceMotion: reduceMotion, select: selectTab)
                    .padding(.horizontal, 40)
                    .padding(.bottom, -14)
            }
            .opacity(browser.bankPageVisible ? 0 : 1)
            .allowsHitTesting(!browser.bankPageVisible)
            if browser.bankPageVisible {
                VStack(spacing: 0) {
                    HStack {
                        Button("Готово") { browser.finishSignIn() }.fontWeight(.semibold)
                        Spacer()
                        Text(browser.host).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("История") { browser.openHistory() }.disabled(browser.busy)
                    }
                    .padding(.horizontal)
                    .frame(height: 52)
                    if browser.signInRequested {
                        Label("Банк просит войти. Введите код из SMS — iPhone подскажет его над клавиатурой. После входа страница закроется сама.",
                              systemImage: "key.fill")
                            .font(.footnote)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    }
                }
                .background(.bar)
            }
        }
        .onChange(of: browser.busy) { _, busy in
            // Automatic refresh can start before the sign-in watcher gets its next turn.
            // Hide the login page while leaving the same WebView mounted for scanning.
            if busy && browser.signInRequested { browser.finishSignIn() }
        }
    }
    private func animate(_ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3), changes)
    }

    private func openAccounts() { animate { page = 0 } }

    private func closeAccounts() { animate { page = 1 } }

    private func selectTab(_ tab: Int) {
        if selectedTab == tab && tab == 3 { settingsReset += 1 }
        selectedTab = tab
        if page == tab {
            // The saved position can stay at a page the pager is no longer on; a repeated value would do nothing.
            page = nil
            DispatchQueue.main.async { animate { page = tab } }
        } else {
            animate { page = tab }
        }
    }
}

@MainActor
final class TabBarProgress: ObservableObject {
    /// 1…3, fractional while the pages move.
    @Published var value: CGFloat = 1
}

@MainActor
final class TabBarSelection: ObservableObject {
    /// The tab the pages are on, changed only when it really changes (not on every scrolled frame).
    @Published var active = 1
}

/// Finger position of the held lens, observed only by the bubble so a drag never redraws the bar.
@MainActor
final class LensDrag: ObservableObject {
    @Published var position: CGFloat = 1
    @Published var velocity: CGFloat = 0
}

private let tabItems: [(title: String, symbol: String)] = [
    ("Операции", "list.bullet.rectangle"), ("Отчёты", "chart.pie"), ("Настройки", "gearshape")
]

/// Bottom tabs like Telegram: frosted glass bar, a light capsule under the chosen tab that follows the pages, and a
/// clear glass drop while the finger holds it, magnifying the tab under it. Each layer observes only what it shows.
@MainActor
private struct LensTabBar: View {
    let progress: TabBarProgress
    let selection: TabBarSelection
    let reduceMotion: Bool
    let select: (Int) -> Void
    @State private var drag = LensDrag()
    @State private var held = false
    @Environment(\.colorScheme) private var colorScheme
    private let inset: CGFloat = 6

    var body: some View {
        GeometryReader { bar in
            let segment = bar.size.width / 3
            ZStack(alignment: .leading) {
                IdleCapsule(progress: progress, segment: segment, height: bar.size.height)
                    .opacity(held ? 0 : 1)
                TabLabels(selection: selection, held: held, select: select)
                    // Under the drop only its magnified copy shows: the real labels are cut out there, no doubling.
                    .mask { LabelCutout(drag: drag, held: held, segment: segment, outerHeight: bar.size.height + inset * 2) }
            }
            .contentShape(Rectangle())
            // One gesture for the whole bar: a tap selects the tab under the finger, a drag carries the lens.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let position = min(3, max(1, value.location.x / max(1, segment) + 0.5))
                        if !held && abs(value.translation.width) > 6 {
                            drag.position = position
                            drag.velocity = 0
                            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.6)) { held = true }
                        } else if held {
                            drag.position = position
                            drag.velocity = value.velocity.width
                        }
                    }
                    .onEnded { value in
                        let tab = Int(min(3, max(1, value.location.x / max(1, segment) + 0.5)).rounded())
                        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.7)) {
                            held = false
                            drag.position = CGFloat(tab)
                            drag.velocity = 0
                        }
                        select(tab)
                    }
            )
        }
        .frame(height: 50)
        .padding(inset)
        // Frosted glass with a dark haze, so a bright wallpaper or list under the bar does not wash out the labels.
        .glassEffect(.regular.tint(colorScheme == .dark ? Color.black.opacity(0.38) : Color.white.opacity(0.22)), in: .capsule)
        .overlay { BubbleLayer(drag: drag, held: held, inset: inset, reduceMotion: reduceMotion) }
    }
}

/// The light capsule under the chosen tab; the only part of the bar that moves while the pages scroll.
private struct IdleCapsule: View {
    @ObservedObject var progress: TabBarProgress
    let segment: CGFloat
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.1))
            .frame(width: segment, height: height)
            .offset(x: (progress.value - 1) * segment)
    }
}

/// Icons and titles. They redraw only when the chosen tab changes, and then the new icon plays its animation.
private struct TabLabels: View {
    @ObservedObject var selection: TabBarSelection
    /// While the drop is held only its copy is blue; the real labels light up again where it lands.
    let held: Bool
    let select: (Int) -> Void
    @State private var plays = [0, 0, 0]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                let active = !held && selection.active == index + 1
                VStack(spacing: 4) {
                    icon(index)
                        .font(.title3)
                        .symbolVariant(active ? .fill : .none)
                    Text(tabItems[index].title).font(.caption2.weight(.medium))
                }
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(active ? [.isSelected, .isButton] : [.isButton])
                .accessibilityAction { select(index + 1) }
            }
        }
        .onChange(of: selection.active) { _, tab in
            if (1...3).contains(tab) { plays[tab - 1] += 1 }
        }
    }

    // Операции and Отчёты bounce, the Settings gear turns, as Telegram's tab icons come alive when chosen.
    @ViewBuilder private func icon(_ index: Int) -> some View {
        let image = Image(systemName: tabItems[index].symbol)
        if index == 2 {
            image.symbolEffect(.rotate, value: plays[index])
        } else {
            image.symbolEffect(.bounce, value: plays[index])
        }
    }
}

/// Everything but the drop: the mask that hides the real labels where the held drop is. Only this tiny view follows
/// the finger, so the labels themselves are not redrawn.
private struct LabelCutout: View {
    @ObservedObject var drag: LensDrag
    let held: Bool
    let segment: CGFloat
    let outerHeight: CGFloat

    var body: some View {
        GeometryReader { area in
            Rectangle()
                .overlay {
                    Capsule()
                        .frame(width: segment * 1.12, height: outerHeight * 1.3)
                        .position(x: (drag.position - 0.5) * segment, y: area.size.height / 2)
                        .opacity(held ? 1 : 0)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}

/// The held drop: clear glass over a magnified, tinted copy of the tabs, so the tab under it looks seen through a lens.
private struct BubbleLayer: View {
    @ObservedObject var drag: LensDrag
    let held: Bool
    let inset: CGFloat
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { outer in
            let width = outer.size.width
            let height = outer.size.height
            let segment = (width - inset * 2) / 3
            let centerX = inset + (drag.position - 0.5) * segment
            // A fast finger stretches the drop along the way and flattens it a little.
            let stretch = min(abs(drag.velocity) / 2600, 0.16)
            let bubbleWidth = segment * 1.12
            let bubbleHeight = height * 1.3
            ZStack {
                ZStack {
                    Capsule().fill(Color.black.opacity(0.15))
                        .frame(width: bubbleWidth, height: bubbleHeight)
                        .position(x: centerX, y: height / 2)
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { index in
                            VStack(spacing: 4) {
                                Image(systemName: tabItems[index].symbol).font(.title3).symbolVariant(.fill)
                                Text(tabItems[index].title).font(.caption2.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(inset)
                    .frame(width: width, height: height)
                    .scaleEffect(1.22, anchor: UnitPoint(x: centerX / max(1, width), y: 0.5))
                }
                .mask {
                    Capsule().frame(width: bubbleWidth, height: bubbleHeight).position(x: centerX, y: height / 2)
                }
                LensBubble()
                    .frame(width: bubbleWidth, height: bubbleHeight)
                    .position(x: centerX, y: height / 2)
            }
            .scaleEffect(x: 1 + stretch, y: 1 - stretch * 0.45, anchor: UnitPoint(x: centerX / max(1, width), y: 0.5))
            .scaleEffect(held ? 1 : 0.55, anchor: UnitPoint(x: centerX / max(1, width), y: 0.5))
            .opacity(held ? 1 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: stretch)
        }
        .allowsHitTesting(false)
    }
}

/// A clear glass drop: refracting glass with a light top, a darker lower rim and a thin rainbow edge, so it reads
/// as round rather than flat. No shadows: they would be re-rendered on every frame of the drag.
private struct LensBubble: View {
    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.04))
            .glassEffect(.clear, in: .capsule)
            .overlay(
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.04), .clear, .black.opacity(0.16)],
                                              startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                Capsule().strokeBorder(
                    AngularGradient(colors: [.white.opacity(0.95), .cyan.opacity(0.6), .purple.opacity(0.45), .white.opacity(0.25),
                                             .orange.opacity(0.45), .yellow.opacity(0.35), .white.opacity(0.95)],
                                    center: .center),
                    lineWidth: 1.5)
            )
            .overlay(
                Capsule().inset(by: 3).strokeBorder(Color.white.opacity(0.3), lineWidth: 0.8)
            )
    }
}

/// Full card of one saved operation: amounts, components, category, financial type and bank details.
struct OperationDetailView: View {
    @ObservedObject var browser: BankBrowser
    let operation: BankOperation
    @State private var noteDraft = ""
    @State private var noteLoaded = false
    @FocusState private var noteFocused: Bool
    var body: some View {
        let look = browser.history.look(for: operation)
        Form {
            LabeledContent(operation.components == nil ? "Сумма" : "Итог группы", value: operation.formattedAmount)
            HStack(alignment: .firstTextBaseline) {
                Text("Комментарий")
                TextField("Добавить", text: $noteDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .focused($noteFocused)
                    .submitLabel(.done)
                    .onChange(of: noteDraft) { _, value in
                        // Return finishes the comment instead of starting a new line.
                        if value.contains("\n") { noteDraft = value.replacingOccurrences(of: "\n", with: ""); noteFocused = false }
                    }
            }
            .onChange(of: noteFocused) { _, focused in if !focused { saveNote() } }
            Section {
                NavigationLink {
                    OperationLookView(browser: browser, operation: operation)
                } label: {
                    HStack(spacing: 12) {
                        let style = OperationRow.icon(for: operation, input: browser.history.financialInput(for: operation))
                        Image(systemName: look.icon ?? style.name)
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(style.color, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(look.title ?? operation.description).lineLimit(2)
                            if look.title != nil {
                                Text("В банке: \(operation.description)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            } footer: {
                Text("Своё название и иконка").font(.caption2)
            }
            ReceiptSection(browser: browser, identity: operation.identity)
            if let components = operation.components {
                Section("Составляющие") {
                    ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(component.amountKopecks < 0 ? "Списание" : "Поступление")
                                Spacer()
                                Text(component.formattedAmount)
                            }
                            Text(component.displayDate).font(.caption)
                        }
                    }
                    Text("Итог группы — сумма этих составляющих, не дополнительная операция. Вид поступления пока не определён.").font(.footnote)
                }.glassRows()
            }
            if let id = browser.history.expenseCategoryID(for: operation),
               let pair = browser.history.expenseCategory(id: id) {
                NavigationLink {
                    OperationExpenseCategoryView(browser: browser, operation: operation)
                } label: {
                    LabeledContent("Категория", value: pair.group.name + " / " + pair.category.name)
                }
                LabeledContent("Категория банка", value: operation.category)
            } else if let income = browser.history.incomeCategory(for: operation) {
                NavigationLink {
                    OperationIncomeCategoryView(browser: browser, operation: operation)
                } label: {
                    LabeledContent("Категория дохода", value: income)
                }
                LabeledContent("Категория банка", value: operation.category)
            } else { LabeledContent("Категория", value: operation.category) }
            LabeledContent("Финансовый тип", value: operation.financialAssessment.type.title)
            if let route = FinancialEngine.saveTransferDirection(for: operation.financialInput) {
                LabeledContent("Счета", value: route)
            }
            Text(operation.financialAssessment.reason).font(.footnote).foregroundStyle(.secondary)
            LabeledContent("Статус", value: operation.status)
            LabeledContent("Дата UTC", value: operation.occurredAt)
            LabeledContent("Точность", value: operation.timePrecision == "source_timestamp" ? "Время банка" : "До минуты")
            if let mcc = operation.mcc { LabeledContent("MCC", value: mcc) }
            if let purpose = operation.purpose { LabeledContent("Назначение", value: purpose) }
            if let method = operation.paymentMethod { LabeledContent("Способ оплаты", value: method) }
        }
        .appSurface()
        .navigationTitle(look.title ?? operation.description)
        .onAppear {
            guard !noteLoaded else { return }
            noteLoaded = true
            noteDraft = look.note ?? ""
        }
        .onDisappear { saveNote() }
    }

    private func saveNote() {
        let current = browser.history.look(for: operation).note ?? ""
        guard noteDraft.trimmingCharacters(in: .whitespacesAndNewlines) != current else { return }
        _ = browser.updateUserData { $0.setNote(noteDraft, for: operation) }
    }
}

/// The user's own title, icon and comment of a bank operation; the bank's data stays as it is.
struct OperationLookView: View {
    @ObservedObject var browser: BankBrowser
    let operation: BankOperation
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var icon: String?
    @State private var forPayee = true
    @State private var error: String?

    init(browser: BankBrowser, operation: BankOperation) {
        self.browser = browser
        self.operation = operation
        let look = browser.history.look(for: operation)
        _title = State(initialValue: look.title ?? "")
        _icon = State(initialValue: look.icon)
    }

    var body: some View {
        let style = OperationRow.icon(for: operation, input: browser.history.financialInput(for: operation))
        Form {
            Section {
                TextField(operation.description, text: $title)
            } header: { Text("Название") } footer: { Text("Пусто — название банка: «\(operation.description)».") }
                .glassRows()
            Section("Иконка") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    Button { icon = nil } label: {
                        Image(systemName: style.name)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .foregroundStyle(icon == nil ? Color.accentColor : .secondary)
                            .background(icon == nil ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Как у категории")
                    ForEach(AppSymbols.all, id: \.symbol) { item in
                        Button { icon = item.symbol } label: {
                            Image(systemName: item.symbol)
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .foregroundStyle(icon == item.symbol ? Color.accentColor : .secondary)
                                .background(icon == item.symbol ? Color.accentColor.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).accessibilityLabel(item.name)
                    }
                }
                .padding(.vertical, 4)
            }.glassRows()
            Section {
                Toggle("Для всех операций „\(operation.description)“", isOn: $forPayee)
            } footer: {
                Text("Название и иконка применятся к прошлым и будущим операциям этого получателя. Комментарий пишется прямо в карточке операции.")
            }.glassRows()
        }
        .tint(.accentColor)
        .appSurface()
        .navigationTitle("Оформление")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Сохранить", systemImage: "checkmark") { save() }
            }
        }
        .alert("Не удалось сохранить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save() {
        let ok = browser.updateUserData { history in
            history.setLook(title: title, icon: icon, for: operation, forPayee: forPayee)
        }
        if ok { dismiss() } else { error = browser.message }
    }
}

/// Bank connection, sync, statement import and storage, moved here from the former bank tab.
@MainActor
struct SettingsView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    var resetToken: Int
    @AppStorage("appearanceTheme") private var appearanceTheme = AppTheme.system.rawValue
    @State private var navigationPath = NavigationPath()
    var onHorizontalPan: (CGFloat, CGFloat, Bool) -> Void
    @EnvironmentObject private var lock: AppLock
    @State private var confirmStorageReset = false
    @AppStorage("historyAlwaysExpanded") private var historyAlwaysExpanded = false
    @State private var exportedBackup: BackupDocument?
    @State private var showBackupImporter = false
    @State private var showCategoryImporter = false
    @State private var importedCategoryPlan: ExpenseCategoryImport?
    @State private var categoryImportError: String?
    @State private var pendingRestore: URL?
    var body: some View {
        let _ = presentation.prepare(browser.history)
        let pendingCount = presentation.value("pending:\(Calendar.current.startOfDay(for: Date()))") { browser.stalePendingCount }
        NavigationStack(path: $navigationPath) {
            List {
                if let storageError = browser.storageError {
                    Section("Хранилище недоступно") {
                        Label(storageError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                        Button("Повторить открытие") { browser.retryOpenStorage() }
                            .disabled(browser.busy)
                        if browser.storageRetryFailed {
                            Text("Повторная попытка не помогла. Сброс удалит только локальную историю и ключ шифрования. После сброса сначала импортируйте PDF-выписку для архива до 01.10.2026, затем обновите новые операции.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Сбросить локальное хранилище", role: .destructive) { confirmStorageReset = true }
                                .disabled(browser.busy)
                        }
                    }.glassRows()
                }
                Section {
                    Picker("Тема", selection: $appearanceTheme) {
                        ForEach(AppTheme.allCases) { theme in Text(theme.title).tag(theme.rawValue) }
                    }
                    Toggle("История всегда развёрнута", isOn: $historyAlwaysExpanded)
                    Text("Иначе список операций на главном экране открывается по нажатию на «Операции».")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Обои", destination: WallpaperSettingsView())
                } header: { Text("Отображение") }.glassRows()
                Section {
                    NavigationLink("Категории расходов") { ExpenseCategoriesView(browser: browser, presentation: presentation) }
                    NavigationLink("Запас до конца месяца") { ReserveAccountsView(browser: browser) }
                    NavigationLink("Безопасность") { SecuritySettingsView(lock: lock) }
                }.glassRows()
                Section {
                    Button("Страница банка") { browser.bankPageVisible = true }
                    Text("Откройте, чтобы войти в банк или посмотреть, что происходит при проверке. Обычно страница скрыта: проверка идёт без неё.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Банк") }.glassRows()
                Section {
                    if browser.busy {
                        HStack { ProgressView(); Text("Обновление операций…"); Spacer(); Button("Остановить") { browser.cancel() } }
                    } else {
                        Button("Обновить новые операции") { browser.refreshNewOperations() }
                            .disabled(!browser.storageAvailable)
                        Button("Прочитать открытую карточку") { browser.read(mode: "card", lookbackDays: nil) }
                            .disabled(!browser.storageAvailable)
                        if browser.canResume {
                            Button("Продолжить загрузку истории") { browser.continueInitialHistory() }.disabled(!browser.storageAvailable)
                        }
                    }
                    if !browser.message.isEmpty {
                        Text(browser.message).font(.footnote).accessibilityIdentifier("syncStatus")
                    }
                    if let date = browser.history.lastCompletedSync {
                        Text("Последнее сканирование новых операций: \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Сканирование новых операций ещё не завершалось успешно")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Обновлять при открытии", isOn: $browser.autoUpdate).disabled(browser.busy)
                    if !browser.autoUpdate {
                        Text("Автообновление выключено. Новые операции не будут проверяться при открытии приложения. После сброса хранилища это делается специально; включите его после ручной синхронизации.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: { Text("Обновление") }.glassRows()
                Section {
                    Text("Сохранено операций: \(browser.history.operations.count)")
                    if let imported = browser.history.statementImportedAt {
                        Text("Архив из выписки: до 30.09.2026")
                        Text("Импортировано из выписки: \(browser.history.statementOperationCount ?? 0) операций · \(imported.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Архив до 01.10.2026: выписка ещё не импортирована")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let date = browser.history.lastSync {
                        Text("Последнее сохранение: \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Text(browser.bootstrapComplete ? "Архив и текущая история подготовлены" : "Архив до 01.10.2026 ещё не импортирован")
                    Text("Не разобрано: \(browser.history.unresolvedIssues?.count ?? 0)")
                    if let date = browser.history.lastCompletedSync {
                        Text("Проверено: \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if pendingCount > 0 {
                        Text("Старых операций в обработке старше \(IncrementalSyncPolicy.pendingWatchDays) дней: \(pendingCount). Они не растягивают автообновление; при необходимости проверьте их вручную.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Архив до 01.10.2026 берётся из PDF-выписки и повторно через сайт не сканируется. История с 01.10.2026 и новее проверяется через банк; после успешной проверки автообновление использует короткое окно с запасом. При закрытом приложении обновление не гарантируется.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Журнал проверок") }.glassRows()
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Button("Экспортировать резервную копию (JSON)") {
                            do { exportedBackup = BackupDocument(data: try browser.backupData()) }
                            catch { browser.message = "Не удалось подготовить копию: \(error.localizedDescription)" }
                        }
                        .disabled(!browser.storageAvailable || browser.busy)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text("Операции, счета и правила в JSON.").font(.caption2).foregroundStyle(.secondary)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Button("Восстановить из копии (JSON)") { showBackupImporter = true }
                            .disabled(browser.busy)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text("Восстановить данные из JSON.").font(.caption2).foregroundStyle(.secondary)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Button("Импортировать PDF-выписки") { browser.syncSixMonthsHistory() }
                            .disabled(!browser.storageAvailable || browser.busy)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text("Одна или несколько выписок.").font(.caption2).foregroundStyle(.secondary)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Button("Импортировать разметку категорий") { showCategoryImporter = true }
                            .disabled(!browser.storageAvailable || browser.busy)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text("Категории из JSON с просмотром.").font(.caption2).foregroundStyle(.secondary)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                } header: { Text("Файлы и данные") }
                .font(.subheadline)
                .environment(\.defaultMinListRowHeight, 40)
                .glassRows()
                    if let issues = browser.history.unresolvedIssues, !issues.isEmpty {
                        Section("Не удалось прочитать") {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(issue.rowSummary ?? "Операция из предыдущей версии").font(.headline)
                                    if let month = issue.monthOrdinal {
                                        Text("Месяц сканера (не дата платежа): \(String(month % 12 + 1)).\(String(month / 12))").font(.caption)
                                    }
                                    if let date = issue.bankDate {
                                        Text("Дата из данных банка: " + date).font(.caption)
                                    } else { Text("Дата платежа пока не определена").font(.caption) }
                                    if let identity = issue.identity {
                                        Text("Идентификатор: " + identity).font(.caption2).textSelection(.enabled)
                                    }
                                    Text(issue.reason).font(.footnote)
                                    Button(issue.operationURL == nil ? "Найти и перечитать" : "Перечитать эту операцию") { browser.retry(issue) }
                                        .disabled(browser.busy)
                                    if issue.operationURL == nil {
                                        Text("У старой записи нет ссылки: поиск пройдёт только по сохранённому месяцу. Откройте «Страница банка» → «История» перед поиском.").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 4)
                            }
                        }.glassRows()
                    }
                Section {
                    Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · сборка \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }.listRowBackground(Color.clear)
            }
            .appSurface()
            .navigationTitle("Настройки")
            // Large titles lose their leading margin inside the horizontal pages; inline matches «Операции».
            .navigationBarTitleDisplayMode(.inline)
        }
        // View-destination links (Обои, Категории) are not part of the path, so a new identity is what
        // reliably returns to the root when the Settings tab is tapped again.
        .id(resetToken)
        .onChange(of: resetToken) { _, _ in navigationPath = NavigationPath() }
        .fileExporter(isPresented: Binding(get: { exportedBackup != nil }, set: { if !$0 { exportedBackup = nil } }),
                      document: exportedBackup, contentType: .json,
                      defaultFilename: "FinanceTest-\(Date().formatted(.iso8601.year().month().day()))") { result in
            if case .success = result { browser.message = "Резервная копия сохранена." }
        }
        .alert("Импорт PDF-выписок", isPresented: Binding(get: { browser.statementPreview != nil }, set: { _ in })) {
            Button("Применить") { browser.applyStatementImport() }
            Button("Отмена", role: .cancel) { browser.cancelStatementImport() }
        } message: { Text(browser.statementPreview?.summary ?? "") }
        .fileImporter(isPresented: $showCategoryImporter, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let plan: ExpenseCategoryImport
                do { plan = try ExpenseCategoryImport.read(from: url) }
                catch { throw AppFailure(message: "«\(url.lastPathComponent)»\n\(error.localizedDescription)") }
                _ = try plan.preview(browser.history)
                importedCategoryPlan = plan
            } catch { categoryImportError = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { importedCategoryPlan != nil }, set: { if !$0 { importedCategoryPlan = nil } })) {
            if let plan = importedCategoryPlan { ExpenseCategoryImportPreview(browser: browser, plan: plan) }
        }
        .alert("Не удалось импортировать разметку", isPresented: Binding(get: { categoryImportError != nil }, set: { if !$0 { categoryImportError = nil } })) {
            Button("OK", role: .cancel) { categoryImportError = nil }
        } message: { Text(categoryImportError ?? "") }
        .fileImporter(isPresented: $showBackupImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { pendingRestore = url }
        }
        .confirmationDialog("Восстановить из копии?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Заменить данные копией", role: .destructive) {
                if let url = pendingRestore { browser.restoreBackup(from: url) }
                pendingRestore = nil
            }
            Button("Отмена", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Текущие операции, счета и группы на этом iPhone заменятся содержимым файла. Если хранилище недоступно, сначала сбросьте его.")
        }
        .confirmationDialog("Сбросить локальное хранилище?", isPresented: $confirmStorageReset, titleVisibility: .visible) {
            Button("Сбросить и удалить локальную историю", role: .destructive) { browser.resetLocalStorage() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Используйте это только после неудачной повторной попытки открыть хранилище. Действие необратимо для локальной копии; автообновление после сброса будет выключено.")
        }
    }
}

enum FinanceOperationSelection: Hashable {
    case expense(group: String, subcategory: String)
    case income(subcategory: String)
    case refund
    case split
    case movement(subcategory: String)
    /// A whole group of expenses, all expenses or all income of the period, one payee (by its rule key).
    case expenseGroup(String)
    case allExpenses
    case allIncome
    case payee(key: String, income: Bool, title: String)

    var title: String {
        switch self {
        case .expense(_, let subcategory), .income(let subcategory), .movement(let subcategory): return subcategory
        case .refund: return "Возвраты"
        case .split: return "Сплит"
        case .expenseGroup(let group): return group
        case .allExpenses: return "Все расходы"
        case .allIncome: return "Все доходы"
        case .payee(_, _, let title): return title
        }
    }

    var parentTitle: String {
        switch self {
        case .expense(let group, _): return group
        case .income, .allIncome: return "Доходы"
        case .refund, .split, .expenseGroup, .allExpenses: return "Расходы"
        case .movement: return "Перемещения"
        case .payee(_, let income, _): return income ? "Доходы" : "Расходы"
        }
    }

    func matches(_ input: FinancialOperationInput) -> Bool {
        let assessment = FinancialEngine.classify(input)
        switch self {
        case .expense(let group, let subcategory):
            guard assessment.type == .expense || assessment.type == .commission else { return false }
            let path = FinancialEngine.expenseCategory(for: input, assessment: assessment)
            return path.group == group && path.subcategory == subcategory
        case .income(let subcategory):
            guard assessment.type == .income || assessment.type == .interestIncome else { return false }
            return FinancialEngine.incomeCategory(for: input, assessment: assessment) == subcategory
        case .refund:
            return assessment.type == .refund
        case .split:
            return assessment.type == .split
        case .movement(let subcategory):
            guard assessment.type == .internalTransfer else { return false }
            return FinancialEngine.movementCategory(for: input) == subcategory
        case .expenseGroup(let group):
            guard assessment.type == .expense || assessment.type == .commission else { return false }
            return FinancialEngine.expenseCategory(for: input, assessment: assessment).group == group
        case .allExpenses:
            return assessment.expenseContributionKopecks > 0
        case .allIncome:
            return assessment.incomeContributionKopecks > 0
        case .payee(let key, let income, _):
            let isIncome = assessment.type == .income || assessment.type == .interestIncome
            let isExpense = assessment.type == .expense || assessment.type == .commission
            guard income ? isIncome : isExpense else { return false }
            let payee = FinancialEngine.payeeRuleKey(input.description)
            return (payee.isEmpty ? "—" : payee) == key
        }
    }

    func contribution(_ operation: BankOperation) -> Int64 {
        let assessment = operation.financialAssessment
        switch self {
        case .expense, .expenseGroup, .allExpenses:
            return assessment.expenseContributionKopecks
        case .income, .allIncome:
            return assessment.incomeContributionKopecks
        case .payee(_, let income, _):
            return income ? assessment.incomeContributionKopecks : assessment.expenseContributionKopecks
        case .refund:
            return assessment.refundContributionKopecks
        case .split, .movement:
            return abs(assessment.originalAmountKopecks)
        }
    }
}

@MainActor
struct FinanceCategoryOperationsView: View {
    @ObservedObject var browser: BankBrowser
    let interval: DateInterval
    let selection: FinanceOperationSelection
    /// The filter of the report this list was opened from: the list holds exactly the operations behind the sum.
    var filter: ReportFilter = .none
    @State private var editedManualOperation: ManualOperation?

    private var operations: [BankOperation] {
        zip(browser.history.allOperations, browser.history.financialInputs)
            .filter { operation, input in
                guard let date = BankDateParser.parse(operation.occurredAt), date >= interval.start && date < interval.end else { return false }
                return selection.matches(input) && ReportEngine.isAllowed(input, by: filter)
            }
            .map { $0.0 }
            .sorted { lhs, rhs in
                let left = BankDateParser.parse(lhs.occurredAt) ?? .distantPast
                let right = BankDateParser.parse(rhs.occurredAt) ?? .distantPast
                if left != right { return left > right }
                return lhs.identity < rhs.identity
            }
    }

    private func rubles(_ kopecks: Int64) -> String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }

    var body: some View {
        let visibleOperations = operations
        let visibleTotal = visibleOperations.reduce(Int64(0)) { $0 + selection.contribution($1) }
        List {
            Section {
                LabeledContent("Итого", value: selection == .refund ? "−" + rubles(visibleTotal) : rubles(visibleTotal))
                LabeledContent("Операций", value: String(visibleOperations.count))
                LabeledContent("Раздел", value: selection.parentTitle)
                Text("Период: \(interval.start.formatted(date: .abbreviated, time: .omitted)) — \(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }.glassRows()

            Section("Операции") {
                if visibleOperations.isEmpty {
                    Text("Операций в этой категории за выбранный период нет.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleOperations, id: \.identity) { operation in
                        if operation.isManual {
                            Button {
                                editedManualOperation = browser.history.manualOperations?.first { $0.id == operation.manualID }
                            } label: {
                                operationRow(operation)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                OperationDetailView(browser: browser, operation: operation)
                            } label: {
                                operationRow(operation)
                            }
                        }
                    }
                }
            }.glassRows()
        }
        .appSurface()
        .navigationTitle(selection.title)
        .sheet(item: $editedManualOperation) { ManualOperationFormView(browser: browser, operation: $0) }
    }

    private func operationRow(_ operation: BankOperation) -> some View {
        let input = browser.history.financialInput(for: operation)
        let assessment = FinancialEngine.classify(input)
        let category = assessment.type == .expense || assessment.type == .commission
            ? FinancialEngine.expenseCategory(for: input, assessment: assessment).subcategory : operation.category
        let look = browser.history.look(for: operation)
        let title = look.title ?? (operation.description.isEmpty ? "Операция без названия" : operation.description)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(operation.formattedAmount).foregroundStyle(.primary)
            }
            HStack {
                Text(BankDateParser.parse(operation.occurredAt)?.formatted(date: .abbreviated, time: .omitted) ?? operation.occurredAt)
                if let note = look.note { Text("· \(note)").lineLimit(1) }
                Spacer()
                Text(category.isEmpty ? "Без категории" : category)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
