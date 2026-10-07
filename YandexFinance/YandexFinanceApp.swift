import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct YandexFinanceApp: App {
    @StateObject private var browser = BankBrowser()
    @StateObject private var wallpaper = WallpaperStore()
    @AppStorage("appearanceTheme") private var appearanceTheme = AppTheme.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(browser: browser)
                .environmentObject(wallpaper)
                .preferredColorScheme(AppTheme(rawValue: appearanceTheme)?.colorScheme)
                .onAppear { if scenePhase == .active { browser.becameActive() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { browser.becameActive() }
                    else { browser.becameInactive() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let drawerWidth = NavigationMotion.drawerWidth(width)
                    // A native paging scroll view moves the screens with the finger on the render server: no SwiftUI
                    // update per frame, and UIKit itself decides between this horizontal swipe and a list's vertical scroll.
                    ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            AccountsView(browser: browser, onClose: closeAccounts, usesGlass: true)
                                .frame(width: drawerWidth, height: max(0, height - 24), alignment: .top)
                                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                                .clipShape(.rect(cornerRadius: 24))
                                .padding(.horizontal, 8)
                                .frame(height: height, alignment: .top)
                                .id(0)
                            OperationsHomeView(browser: browser, presentation: presentation, onAccounts: openAccounts,
                                               onHorizontalPan: { _, _, _ in })
                                .frame(width: width, height: height)
                                .overlay {
                                    // While the accounts are open, a tap on the visible edge of the page closes them.
                                    if page == 0 {
                                        Color.clear.contentShape(Rectangle()).onTapGesture(perform: closeAccounts)
                                    }
                                }
                                .id(1)
                            FinanceDashboardView(browser: browser, presentation: presentation,
                                                 onHorizontalPan: { _, _, _ in })
                                .frame(width: width, height: height)
                                .id(2)
                            SettingsView(browser: browser, presentation: presentation, resetToken: settingsReset,
                                         onHorizontalPan: { _, _, _ in })
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
                        tabProgress.value = min(3, max(1, (x - pagesStart) / max(1, width) + 1))
                    }
                    // The first layout starts at the leading edge (the accounts); open on the selected tab instead.
                    .onAppear { proxy.scrollTo(selectedTab, anchor: .leading) }
                    }
                }

                LensTabBar(progress: tabProgress, reduceMotion: reduceMotion, select: selectTab)
                    .padding(6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 8)
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
        animate { page = tab }
    }
}

@MainActor
final class TabBarProgress: ObservableObject {
    /// 1…3, fractional while the pages move.
    @Published var value: CGFloat = 1
}

/// Bottom tabs with a glass lens like Telegram: the lens follows the pages while they scroll, can be dragged along
/// the bar with a finger (it grows while held) and settles on the nearest tab.
@MainActor
private struct LensTabBar: View {
    @ObservedObject var progress: TabBarProgress
    let reduceMotion: Bool
    let select: (Int) -> Void
    @State private var dragged: CGFloat?

    private let tabs: [(title: String, symbol: String)] = [
        ("Операции", "list.bullet.rectangle"), ("Отчёты", "chart.pie"), ("Настройки", "gearshape")
    ]

    var body: some View {
        GeometryReader { bar in
            let segment = bar.size.width / 3
            let position = dragged ?? progress.value
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .glassEffect(.regular, in: .capsule)
                    .frame(width: segment, height: bar.size.height)
                    .scaleEffect(x: dragged == nil ? 1 : 1.18, y: dragged == nil ? 1 : 1.22)
                    .offset(x: (position - 1) * segment)
                    .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.68), value: dragged == nil)
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        let tab = index + 1
                        let active = Int(position.rounded()) == tab
                        Button { select(tab) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: tabs[index].symbol).font(.title3)
                                Text(tabs[index].title).font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(active ? Color.accentColor : Color.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(active ? [.isSelected] : [])
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { drag in
                        dragged = min(3, max(1, drag.location.x / max(1, segment) + 0.5))
                    }
                    .onEnded { drag in
                        let tab = Int(min(3, max(1, drag.location.x / max(1, segment) + 0.5)).rounded())
                        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8)) { dragged = nil }
                        select(tab)
                    }
            )
        }
        .frame(height: 50)
    }
}

/// Full card of one saved operation: amounts, components, category, financial type and bank details.
struct OperationDetailView: View {
    @ObservedObject var browser: BankBrowser
    let operation: BankOperation
    var body: some View {
        Form {
            LabeledContent(operation.components == nil ? "Сумма" : "Итог группы", value: operation.formattedAmount)
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
        }.appSurface().navigationTitle(operation.description)
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
    @AppStorage("reserveBufferRubles") private var reserveBufferRubles = 25_000
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
                    Stepper(value: $reserveBufferRubles, in: 0...500_000, step: 5_000) {
                        Text("Запас «впритык» ниже: \(reserveBufferRubles.formatted(.number.locale(Locale(identifier: "ru_RU")))) ₽")
                    }
                    Text("Ниже этой суммы запас до конца месяца показывается жёлтым.")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Обои", destination: WallpaperSettingsView())
                } header: { Text("Отображение") }.glassRows()
                Section {
                    NavigationLink("Категории расходов") { ExpenseCategoriesView(browser: browser, presentation: presentation) }
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
            .contentMargins(.bottom, 16, for: .scrollContent)
            .appSurface()
            .navigationTitle("Настройки")
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

    var title: String {
        switch self {
        case .expense(_, let subcategory), .income(let subcategory), .movement(let subcategory): return subcategory
        case .refund: return "Возвраты"
        case .split: return "Сплит"
        }
    }

    var parentTitle: String {
        switch self {
        case .expense(let group, _): return group
        case .income: return "Доходы"
        case .refund, .split: return "Расходы"
        case .movement: return "Перемещения"
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
        }
    }

    func contribution(_ operation: BankOperation) -> Int64 {
        let assessment = operation.financialAssessment
        switch self {
        case .expense:
            return assessment.expenseContributionKopecks
        case .income:
            return assessment.incomeContributionKopecks
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
    @State private var editedManualOperation: ManualOperation?

    private var operations: [BankOperation] {
        zip(browser.history.allOperations, browser.history.financialInputs)
            .filter { operation, input in
                guard let date = BankDateParser.parse(operation.occurredAt), date >= interval.start && date < interval.end else { return false }
                return selection.matches(input)
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
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(operation.description.isEmpty ? "Операция без названия" : operation.description).foregroundStyle(.primary)
                Spacer()
                Text(operation.formattedAmount).foregroundStyle(.primary)
            }
            HStack {
                Text(BankDateParser.parse(operation.occurredAt)?.formatted(date: .abbreviated, time: .omitted) ?? operation.occurredAt)
                Spacer()
                Text(category.isEmpty ? "Без категории" : category)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

}

@MainActor
struct FinanceDashboardView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    var onHorizontalPan: (CGFloat, CGFloat, Bool) -> Void
    // Selected month start date (first day of the month). Defaults to current month.
    @State private var selectedMonthStart: Date = monthStart(of: Date())

    // Helper to go to previous month.
    private func previousMonth() {
        if let newDate = Calendar.current.date(byAdding: .month, value: -1, to: selectedMonthStart) {
            selectedMonthStart = newDate
        }
    }

    // Helper to go to next month (not into future months).
    private func nextMonth() {
        if let newDate = nextMonthIfAllowed(selectedStart: selectedMonthStart) {
            selectedMonthStart = newDate
        }
    }

    private func rubles(_ kopecks: Int64) -> String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }

    private func signed(_ kopecks: Int64) -> String {
        let prefix = kopecks > 0 ? "+" : ""
        return prefix + rubles(kopecks)
    }

    private func relativeText(_ change: FinancialEngine.MonthlyChange) -> String {
        switch change.relative {
        case .percent(let value):
            return (value / 100).formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always()))
        case .new:
            return "новое"
        case .notApplicable:
            return "—"
        }
    }

    private func periodText(_ period: DateInterval) -> String {
        let last = period.end.addingTimeInterval(-1)
        return "\(period.start.formatted(.dateTime.day().month())) — \(last.formatted(.dateTime.day().month()))"
    }

    private enum ComparisonStyle { case moreIsBetter, lessIsBetter, total }

    private func wholeRubles(_ kopecks: Int64) -> String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB").precision(.fractionLength(0)))
    }

    private func comparisonRow(_ title: String, _ change: FinancialEngine.MonthlyChange, style: ComparisonStyle) -> some View {
        let delta = change.delta
        let amount = wholeRubles(abs(delta))
        let better: Bool
        let words: String
        switch style {
        case .moreIsBetter:
            better = delta > 0; words = delta > 0 ? "▲ больше на \(amount)" : "▼ меньше на \(amount)"
        case .lessIsBetter:
            better = delta < 0; words = delta > 0 ? "▲ больше на \(amount)" : "▼ меньше на \(amount)"
        case .total:
            better = delta > 0; words = delta > 0 ? "лучше на \(amount)" : "хуже на \(amount)"
        }
        // Rounded to whole rubles, a few kopecks are no change.
        let unchanged = abs(delta) < 100
        return VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.subheadline)
                Spacer(minLength: 0)
                Text(wholeRubles(change.current)).font(.subheadline.weight(.semibold))
                    .frame(width: 104, alignment: .trailing)
                Text(wholeRubles(change.previous)).font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 104, alignment: .trailing)
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(unchanged ? "без изменений" : words)
                .font(.caption.weight(.medium))
                .foregroundStyle(unchanged ? Color.secondary : (better ? Color.green : Color.red))
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
    }

    private func changeRow(_ title: String, _ change: FinancialEngine.MonthlyChange) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(rubles(change.current))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .font(.subheadline)
            Text("было \(rubles(change.previous)) · \(signed(change.delta)) · \(relativeText(change))")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
    }



    var body: some View {
        // Compute the interval based on the selected month.
        let monthStart = selectedMonthStart
        let interval = DateInterval(start: monthStart, end: Calendar.current.date(byAdding: .month, value: 1, to: monthStart)!)
        let _ = presentation.prepare(browser.history)
        let inputs = presentation.inputs(browser.history)
        let report = presentation.report(browser.history, interval: interval)
        let periods = monthComparisonPeriods(selectedStart: monthStart)
        let comparison = presentation.value("comparison:\(periods.current):\(periods.previous)") {
            FinancialEngine.compareReports(inputs, currentInterval: periods.current, previousInterval: periods.previous, taxonomy: browser.history.expenseTaxonomy)
        }
        NavigationStack {
            List {
                    HStack {
                        Button(action: previousMonth) { Image(systemName:"chevron.left") }
                        Text(selectedMonthStart.formatted(.dateTime.month().year()))
                            .fontWeight(.semibold)
                        Button(action: nextMonth) { Image(systemName:"chevron.right") }
                            .disabled(nextMonthIfAllowed(selectedStart: selectedMonthStart) == nil)
                    }
                    // In a List row every default-style button fires on any tap in the row.
                    .buttonStyle(.borderless)
                Section("Расходы по категориям") {
                    CategoryExpenseChart(groups: FinancialEngine.expenseByGroup(report), refundsKopecks: report.refundsKopecks)
                }.glassRows()

                // Income and expenses open straight into subcategories and operations.
                incomeBlock(report, interval: interval)
                expenseBlock(report, interval: interval)

                if !report.movementLines.isEmpty {
                    movementBlock(report, interval: interval)
                }
                if !report.incompleteLines.isEmpty {
                    incompleteBlock(report)
                }

                Section("Итог месяца") {
                    LabeledContent("Разница", value: signed(report.differenceKopecks))
                    LabeledContent("Операций", value: String(report.operationCount))
                    if report.invalidDateCount > 0 {
                        LabeledContent("Не распознано дат в базе", value: String(report.invalidDateCount))
                            .foregroundStyle(.orange)
                    }
                    Text("Период: \(interval.start.formatted(date: .abbreviated, time: .omitted)) — \(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }.glassRows()

                Section {
                    // Two plain columns and the change in words: «now», «before», «more/less by».
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Text(periods.isPartial ? periodText(periods.current) : "Сейчас")
                            .frame(width: 104, alignment: .trailing)
                        Text(periods.isPartial ? periodText(periods.previous) : "Было")
                            .frame(width: 104, alignment: .trailing)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 2, trailing: 20))
                    comparisonRow("Доходы", comparison.income, style: .moreIsBetter)
                    comparisonRow("Расходы", comparison.netExpense, style: .lessIsBetter)
                    comparisonRow("Итог", comparison.difference, style: .total)
                    if let growth = comparison.topExpenseGrowth {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Больше всего выросли").font(.caption).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline) {
                                Text(growth.subcategory).font(.subheadline.weight(.semibold))
                                Text(growth.group).font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 6)
                                Text("\(wholeRubles(growth.change.current)), было \(wholeRubles(growth.change.previous))")
                                    .font(.subheadline).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                    }
                } header: {
                    Text("Сравнение с \(periodText(periods.previous))")
                }.glassRows()

                Section("Полнота данных") {
                    if !browser.bootstrapComplete {
                        Text("Архив до 01.10.2026 ещё не импортирован. Итоги за старые месяцы будут неполными до импорта PDF-выписки.")
                    }
                    let issues = browser.history.unresolvedIssues?.count ?? 0
                    if issues > 0 { Text("Не прочитано операций: \(issues). Итоги могут быть неполными.").foregroundStyle(.orange) }
                    if browser.busy { ProgressView("Обновление данных…") }
                    Text("Разница доходов и расходов не является остатком на банковских счетах.")
                }.glassRows().font(.footnote)

                Section("Сверка с банком") {
                    LabeledContent("Банковские списания", value: rubles(report.bankDebitKopecks))
                    LabeledContent("Банковские поступления", value: rubles(report.bankCreditKopecks))
                    Text("Это оборот сохранённых карточек за период: все завершённые и находящиеся в обработке движения по знаку суммы, кроме отменённых. Сводные карточки здесь учитываются по общему итогу; их внутренние списания и поступления могут отличаться от оборота банка. Этот показатель помогает при сверке и не равен финансовым доходам/расходам: сюда могут входить свои переводы, снятие наличных, Сплит и возвраты.")
                        .font(.caption).foregroundStyle(.secondary)
                    if report.invalidDateCount > 0 {
                        Text("В базе есть операции с нераспознанной датой. Их нельзя надёжно отнести к этому месяцу, поэтому сверка с банком может быть неполной.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.glassRows()

                Section("Правила") {
                    Text("Возвраты уменьшают расходы и не считаются доходом. Переводы Карта ↔ Сейв и другие подтверждённые переводы между своими счетами относятся к перемещениям; проценты по Сейву считаются доходом.")
                    Text("Сплит показывается отдельно и пока не входит в итог расходов, пока исходная покупка и платежи не связаны — так мы не создаём двойной расход.")
                    Text("Старое завершённое списание без современного типа считается расходом. Непонятное положительное поступление автоматически доходом не назначается.")
                }.glassRows().font(.footnote).foregroundStyle(.secondary)
            }
            .appSurface()
            .navigationTitle("Отчёты")
        }
    }

    private var reviewGroups: [ReviewGroup] {
        presentation.value("uncategorized") { UncategorizedReview.groups(browser.history) }
    }

    private func needsExpenseReview(group: String, category: String) -> Bool {
        guard let pair = browser.history.expenseCategory(id: UncategorizedReview.otherExpenseID) else { return false }
        return pair.group.name == group && pair.category.name == category && reviewGroups.contains { $0.kind == .expense }
    }

    private func incomeBlock(_ report: FinanceReport, interval: DateInterval) -> some View {
        Section {
            DisclosureGroup {
                if report.incomeLines.isEmpty {
                    Text("Доходов за месяц нет.").foregroundStyle(.secondary)
                } else {
                    ForEach(report.incomeLines) { line in
                        NavigationLink {
                            if (line.title == "Прочие доходы" || line.title == "Не определено"), reviewGroups.contains(where: { $0.kind == .income }) {
                                UncategorizedReviewView(browser: browser, presentation: presentation)
                            } else {
                                FinanceCategoryOperationsView(browser: browser, interval: interval, selection: .income(subcategory: line.title))
                            }
                        } label: {
                            simpleFinanceRow(line, amount: rubles(line.amountKopecks))
                        }
                    }
                }
            } label: {
                blockLabel("Доходы", value: rubles(report.incomeKopecks))
            }
        }.glassRows()
    }

    private func expenseBlock(_ report: FinanceReport, interval: DateInterval) -> some View {
        Section {
            DisclosureGroup {
                if report.expenseLines.isEmpty {
                    Text("Расходов за месяц нет.").foregroundStyle(.secondary)
                } else {
                    ForEach(report.expenseLines) { line in
                        expenseLine(line, interval: interval)
                    }
                    Text("Итог расходов уже уменьшен на возвраты.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                blockLabel("Расходы", value: rubles(report.netExpenseKopecks))
            }
        }.glassRows()
    }

    private func movementBlock(_ report: FinanceReport, interval: DateInterval) -> some View {
        Section {
            DisclosureGroup {
                ForEach(report.movementLines) { line in
                    NavigationLink {
                        FinanceCategoryOperationsView(browser: browser, interval: interval, selection: .movement(subcategory: line.title))
                    } label: {
                        simpleFinanceRow(line, amount: rubles(line.amountKopecks))
                    }
                }
                Text("Перемещения не входят ни в доходы, ни в расходы. Показанная сумма — оборот перемещений.")
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                blockLabel("Перемещения", value: rubles(report.movementKopecks))
            }
        }.glassRows()
    }

    private func incompleteBlock(_ report: FinanceReport) -> some View {
        Section {
            DisclosureGroup {
                ForEach(report.incompleteLines) { line in
                    if line.children.isEmpty {
                        incompleteRow(line)
                    } else {
                        DisclosureGroup {
                            ForEach(line.children) { child in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(child.title)
                                        Spacer()
                                        Text(signed(child.amountKopecks))
                                    }
                                    if let note = child.note {
                                        Text(note).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        } label: {
                            incompleteRow(line)
                        }
                    }
                }
            } label: {
                blockLabel("Не завершено", value: "\(incompleteCount(report)) оп.")
            }
        }.glassRows()
    }

    private func incompleteCount(_ report: FinanceReport) -> Int {
        report.incompleteLines.reduce(0) { $0 + $1.count }
    }

    private func incompleteRow(_ line: FinanceLine) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(line.title)
                Spacer()
                Text(signed(line.amountKopecks))
            }
            Text("Операций: \(line.count)").font(.caption).foregroundStyle(.secondary)
            if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func expenseAmount(_ line: FinanceLine) -> String {
        line.title == "Возвраты" ? "−" + rubles(line.amountKopecks) : rubles(line.amountKopecks)
    }

    @ViewBuilder
    private func expenseLine(_ line: FinanceLine, interval: DateInterval) -> some View {
        if line.title == "Возвраты" {
            NavigationLink {
                FinanceCategoryOperationsView(browser: browser, interval: interval, selection: .refund)
            } label: {
                simpleFinanceRow(line, amount: expenseAmount(line))
            }
        } else if line.title == "Сплит" {
            NavigationLink {
                FinanceCategoryOperationsView(browser: browser, interval: interval, selection: .split)
            } label: {
                simpleFinanceRow(line, amount: expenseAmount(line))
            }
        } else if line.children.isEmpty {
            simpleFinanceRow(line, amount: expenseAmount(line))
        } else {
            DisclosureGroup {
                if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                ForEach(line.children) { child in
                    NavigationLink {
                        if needsExpenseReview(group: line.title, category: child.title) {
                            UncategorizedReviewView(browser: browser, presentation: presentation)
                        } else {
                            FinanceCategoryOperationsView(browser: browser, interval: interval, selection: .expense(group: line.title, subcategory: child.title))
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(child.title)
                                Text("Операций: \(child.count)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(rubles(child.amountKopecks))
                        }
                        .font(.subheadline)
                    }
                }
            } label: {
                financeRowLabel(line, amount: expenseAmount(line))
            }
        }
    }

    private func simpleFinanceRow(_ line: FinanceLine, amount: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            financeRowLabel(line, amount: amount)
            if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func financeRowLabel(_ line: FinanceLine, amount: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                Text("Операций: \(line.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(amount)
        }
    }

    private func blockLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text(value).font(.headline)
        }
    }
}

/// JSON backup file for the system "Save to Files" panel.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
