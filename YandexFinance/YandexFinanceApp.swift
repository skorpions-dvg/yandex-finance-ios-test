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
    @State private var selectedTab = 1
    @State private var settingsReset = 0
    @State private var presentation = FinancePresentationCache()
    @State private var pageMotion = NavigationTranslation()
    @State private var drawerOpen = false
    @State private var drawerTranslation: CGFloat = 0
    @State private var drawerMounted = false
    @State private var panSession = NavigationPanSession()
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
                let drawerWidth = NavigationMotion.drawerWidth(width)
                let drawerPosition = NavigationMotion.drawerPosition(translation: drawerTranslation, width: drawerWidth, wasOpen: drawerOpen)
                ZStack(alignment: .leading) {
                    MovingPages(motion: pageMotion, tab: selectedTab, width: width) {
                        HStack(spacing: 0) {
                            OperationsHomeView(browser: browser, presentation: presentation, onAccounts: openAccounts,
                                               onHorizontalPan: { pan($0, $1, $2, width: width) })
                                .frame(width: width, height: geometry.size.height)
                                .allowsHitTesting(selectedTab == 1)
                                .accessibilityHidden(selectedTab != 1)
                            FinanceDashboardView(browser: browser, presentation: presentation,
                                                 onHorizontalPan: { pan($0, $1, $2, width: width) })
                                .frame(width: width, height: geometry.size.height)
                                .allowsHitTesting(selectedTab == 2)
                                .accessibilityHidden(selectedTab != 2)
                            SettingsView(browser: browser, presentation: presentation, resetToken: settingsReset,
                                         onHorizontalPan: { pan($0, $1, $2, width: width) })
                                .frame(width: width, height: geometry.size.height)
                                .allowsHitTesting(selectedTab == 3)
                                .accessibilityHidden(selectedTab != 3)
                        }
                    }
                    .allowsHitTesting(!drawerOpen)
                    if drawerMounted {
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .frame(width: max(0, width - drawerPosition))
                                .contentShape(Rectangle())
                                .onTapGesture { closeAccounts() }
                                .gesture(HorizontalPanCapture(onPan: { translation, velocity, ended in
                                    if ended {
                                        animate {
                                            drawerOpen = NavigationMotion.drawerShouldOpen(translation: translation, velocity: velocity,
                                                                                           width: drawerWidth, wasOpen: true)
                                            drawerTranslation = 0
                                        }
                                    } else { drawerTranslation = min(0, translation) }
                                }, excludesHorizontalScrollViews: false))
                                .offset(x: drawerPosition)
                            AccountsView(browser: browser, onClose: closeAccounts, usesGlass: true,
                                         onHorizontalPan: { translation, velocity, ended in
                                        if ended {
                                            animate {
                                                drawerOpen = NavigationMotion.drawerShouldOpen(translation: translation, velocity: velocity,
                                                                                               width: drawerWidth, wasOpen: true)
                                                drawerTranslation = 0
                                            }
                                        } else { drawerTranslation = min(0, translation) }
                                    })
                                .frame(width: drawerWidth, height: max(0, geometry.size.height - 24), alignment: .top)
                                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                                .clipShape(.rect(cornerRadius: 24))
                                .offset(x: -(drawerWidth + 8) + drawerPosition)
                        }
                        .frame(width: width, height: geometry.size.height, alignment: .topLeading)
                        .allowsHitTesting(drawerOpen)
                        .accessibilityHidden(!drawerOpen)
                    }
                }
                .frame(width: width, height: geometry.size.height, alignment: .leading)
                .clipped()
            }

                HStack(spacing: 4) {
                    tabButton(1, title: "Операции", symbol: "list.bullet.rectangle")
                    tabButton(2, title: "Отчёты", symbol: "chart.pie")
                    tabButton(3, title: "Настройки", symbol: "gearshape")
                }
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

    private func openAccounts() {
        drawerMounted = true
        animate { drawerOpen = true; drawerTranslation = 0 }
    }

    private func closeAccounts() { animate { drawerOpen = false; drawerTranslation = 0 } }

    private func pan(_ translation: CGFloat, _ velocity: CGFloat, _ ended: Bool, width: CGFloat) {
        if panSession.route == 0 && translation != 0 { panSession.route = selectedTab == 1 && translation > 0 ? 1 : 2 }
        if ended {
            animate {
                if panSession.route == 1 {
                    drawerOpen = NavigationMotion.drawerShouldOpen(translation: translation, velocity: velocity,
                                                                  width: NavigationMotion.drawerWidth(width), wasOpen: false)
                } else if panSession.route == 2 {
                    selectedTab = NavigationMotion.pageTarget(current: selectedTab, translation: translation, velocity: velocity, width: width)
                }
                drawerTranslation = 0
                pageMotion.offset = 0
            }
            panSession.route = 0
        } else if panSession.route == 1 {
            drawerMounted = true
            drawerTranslation = max(0, translation)
        } else {
            let beyondLastPage = selectedTab == 3 && translation < 0
            pageMotion.offset = beyondLastPage ? translation * 0.15 : translation
        }
    }

    private func tabButton(_ tab: Int, title: String, symbol: String) -> some View {
        Button {
            if selectedTab == tab && tab == 3 { settingsReset += 1 }
            panSession.route = 0
            animate { selectedTab = tab; pageMotion.offset = 0; drawerOpen = false; drawerTranslation = 0 }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(selectedTab == tab ? Color.blue : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(selectedTab == tab ? Color.primary.opacity(0.08) : Color.clear, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
    }
}

@MainActor
private final class NavigationPanSession {
    var route = 0 // 1: drawer, 2: pages; gesture bookkeeping does not invalidate screens.
}

/// Only transform layers observe live finger movement. The screens remain stable between pan events.
@MainActor
private final class NavigationTranslation: ObservableObject {
    @Published var offset: CGFloat = 0
}

@MainActor
private struct MovingPages<Content: View>: View {
    @ObservedObject private var motion: NavigationTranslation
    let tab: Int
    let width: CGFloat
    let content: Content

    init(motion: NavigationTranslation, tab: Int, width: CGFloat, @ViewBuilder content: () -> Content) {
        self.motion = motion
        self.tab = tab
        self.width = width
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: width * 3, alignment: .leading)
            .offset(x: -CGFloat(tab - 1) * width + motion.offset)
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
                }.listRowBackground(GlassRowBackground())
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
                    }.listRowBackground(GlassRowBackground())
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
                } header: { Text("Отображение") }.listRowBackground(GlassRowBackground())
                Section {
                    NavigationLink("Категории расходов") { ExpenseCategoriesView(browser: browser, presentation: presentation) }
                }.listRowBackground(GlassRowBackground())
                Section {
                    Button("Страница банка") { browser.bankPageVisible = true }
                    Text("Откройте, чтобы войти в банк или посмотреть, что происходит при проверке. Обычно страница скрыта: проверка идёт без неё.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Банк") }.listRowBackground(GlassRowBackground())
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
                } header: { Text("Обновление") }.listRowBackground(GlassRowBackground())
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
                } header: { Text("Журнал проверок") }.listRowBackground(GlassRowBackground())
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
                .listRowBackground(GlassRowBackground())
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
                        }.listRowBackground(GlassRowBackground())
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
            .gesture(HorizontalPanCapture(onPan: onHorizontalPan))
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
            }.listRowBackground(GlassRowBackground())

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
            }.listRowBackground(GlassRowBackground())
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

    private func changeRow(_ title: String, _ change: FinancialEngine.MonthlyChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            VStack(alignment: .trailing, spacing: 2) {
                Text(rubles(change.current))
                Text("было \(rubles(change.previous)) · \(signed(change.delta)) · \(relativeText(change))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }



    var body: some View {
        // Compute the interval based on the selected month.
        let monthStart = selectedMonthStart
        let interval = DateInterval(start: monthStart, end: Calendar.current.date(byAdding: .month, value: 1, to: monthStart)!)
        let _ = presentation.prepare(browser.history)
        let inputs = presentation.inputs(browser.history)
        let report = presentation.report(browser.history, interval: interval)
        let save = presentation.value("save:\(interval.start):\(interval.end)") { FinancialEngine.saveAccountSummary(inputs, in: interval) }
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
                }.listRowBackground(GlassRowBackground())

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
                }.listRowBackground(GlassRowBackground())

                Section("К предыдущему месяцу") {
                    if periods.isPartial {
                        Text("Месяц неполный: \(periodText(periods.current)) против \(periodText(periods.previous))")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    changeRow("Доходы", comparison.income)
                    changeRow("Расходы", comparison.netExpense)
                    changeRow("Разница", comparison.difference)
                    if let growth = comparison.topExpenseGrowth {
                        changeRow("Рост: \(growth.group) › \(growth.subcategory)", growth.change)
                    } else {
                        LabeledContent("Рост расходов", value: "—")
                    }
                }.listRowBackground(GlassRowBackground())

                Section("Полнота данных") {
                    if !browser.bootstrapComplete {
                        Text("Архив до 01.10.2026 ещё не импортирован. Итоги за старые месяцы будут неполными до импорта PDF-выписки.")
                    }
                    let issues = browser.history.unresolvedIssues?.count ?? 0
                    if issues > 0 { Text("Не прочитано операций: \(issues). Итоги могут быть неполными.").foregroundStyle(.orange) }
                    if browser.busy { ProgressView("Обновление данных…") }
                    Text("Разница доходов и расходов не является остатком на банковских счетах.")
                }.listRowBackground(GlassRowBackground()).font(.footnote)

                Section("Сейв") {
                    LabeledContent("В Сейв", value: rubles(save.toSaveKopecks))
                    LabeledContent("Из Сейва", value: rubles(save.fromSaveKopecks))
                    LabeledContent("Чистое пополнение", value: signed(save.netTransferKopecks))
                    if save.interestIncomeKopecks > 0 {
                        LabeledContent("Начисленные проценты", value: "+" + rubles(save.interestIncomeKopecks))
                    }
                    Text("Это движение по Сейву за выбранный месяц, а не текущий остаток на счёте. Переводы Карта ↔ Сейв не входят в доходы и расходы; начисленные банком проценты входят в доходы.")
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(GlassRowBackground())


                Section("Сверка с банком") {
                    LabeledContent("Банковские списания", value: rubles(report.bankDebitKopecks))
                    LabeledContent("Банковские поступления", value: rubles(report.bankCreditKopecks))
                    Text("Это оборот сохранённых карточек за период: все завершённые и находящиеся в обработке движения по знаку суммы, кроме отменённых. Сводные карточки здесь учитываются по общему итогу; их внутренние списания и поступления могут отличаться от оборота банка. Этот показатель помогает при сверке и не равен финансовым доходам/расходам: сюда могут входить свои переводы, снятие наличных, Сплит и возвраты.")
                        .font(.caption).foregroundStyle(.secondary)
                    if report.invalidDateCount > 0 {
                        Text("В базе есть операции с нераспознанной датой. Их нельзя надёжно отнести к этому месяцу, поэтому сверка с банком может быть неполной.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.listRowBackground(GlassRowBackground())

                Section("Правила") {
                    Text("Возвраты уменьшают расходы и не считаются доходом. Переводы Карта ↔ Сейв и другие подтверждённые переводы между своими счетами относятся к перемещениям; проценты по Сейву считаются доходом.")
                    Text("Сплит показывается отдельно и пока не входит в итог расходов, пока исходная покупка и платежи не связаны — так мы не создаём двойной расход.")
                    Text("Старое завершённое списание без современного типа считается расходом. Непонятное положительное поступление автоматически доходом не назначается.")
                }.listRowBackground(GlassRowBackground()).font(.footnote).foregroundStyle(.secondary)
            }
            .appSurface()
            .gesture(HorizontalPanCapture(onPan: onHorizontalPan))
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
        }.listRowBackground(GlassRowBackground())
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
        }.listRowBackground(GlassRowBackground())
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
        }.listRowBackground(GlassRowBackground())
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
        }.listRowBackground(GlassRowBackground())
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
