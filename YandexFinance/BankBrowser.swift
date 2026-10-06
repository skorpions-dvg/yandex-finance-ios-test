import SwiftUI
import WebKit
import UIKit
import UniformTypeIdentifiers

@MainActor
final class BankBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, UIDocumentPickerDelegate {
    let webView: WKWebView
    @Published var selectedTab = 1
    /// The bank page always stays in the window (scanning needs it); this only brings it to the front.
    @Published var bankPageVisible = false
    @Published var busy = false
    @Published var message = ""
    @Published var host = "bank.yandex.ru"
    @Published var history = SavedHistory()
    @Published private(set) var storageError: String?
    @Published private(set) var storageRetryFailed = false
    private let vault = Vault()
    private var readable = true
    private var cancelled = false
    private var foreground = false
    private var automaticTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private var pendingRetry: ImportIssue?
    private var retryNavigationTask: Task<Void, Never>?
    private var activeRunID: String?
    private var checkpointInFlight = false
    private var bootstrapRun = false
    private var checkpointAdded = 0
    private var checkpointChanged = 0

    @Published var autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate")
            if autoUpdate { scheduleAutomaticUpdate() }
            else { automaticTask?.cancel(); automaticTask = nil }
        }
    }
    var bootstrapComplete: Bool { history.statementArchiveThrough != nil || history.bootstrapCompleted == true }
    var canResume: Bool { false }
    var storageAvailable: Bool { readable }
    var stalePendingCount: Int { incrementalPolicy().stalePendingCount }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        do { history = try vault.load() }
        catch {
            readable = false
            storageError = error.localizedDescription
            message = "Хранилище не открыто: \(error.localizedDescription)"
        }
        openHistory()
    }
    func becameActive() { foreground = true; scheduleAutomaticUpdate() }
    func becameInactive() {
        foreground = false
        automaticTask?.cancel(); automaticTask = nil
        if busy { Task { @MainActor [weak self] in await self?.flushCheckpointFromWebView() } }
    }
    private func scheduleAutomaticUpdate() {
        guard foreground, autoUpdate, readable, !busy, pendingRetry == nil, automaticTask == nil else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 300 { return }
        automaticTask = Task { @MainActor [weak self] in
            for _ in 0..<120 {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, self.foreground, self.autoUpdate, !self.busy else { return }
                guard await self.historyPageReady() else { continue }
                guard !Task.isCancelled, self.foreground, self.autoUpdate else { return }
                self.automaticTask = nil
                self.read(mode: "history", lookbackDays: self.incrementalDays(), initialImport: false, automaticRun: true)
                return
            }
            guard let self else { return }
            self.automaticTask = nil
            if self.foreground, self.autoUpdate, !self.busy {
                self.message = Self.signInNeededMessage
            }
        }
    }

    static let signInNeededMessage = "Банк не показал историю операций — похоже, нужен вход. Откройте «Настройки» → «Страница банка», войдите и нажмите «Готово», затем обновите операции."

    /// True when the bank's history page is loaded and signed in (its account filter is visible).
    private func historyPageReady() async -> Bool {
        guard webView.url?.host == "bank.yandex.ru", webView.url?.path == "/my/transactions-history", !webView.isLoading else { return false }
        let probe = """
        if (location.hostname !== 'bank.yandex.ru' || location.pathname !== '/my/transactions-history') return false;
        return (document.body?.innerText || '').includes('Все карты и счета');
        """
        let value = try? await webView.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: .defaultClient)
        return value as? Bool == true
    }

    /// Manual refresh: opens the history page when needed and, if the bank asks to sign in,
    /// says so and brings the bank page to the front instead of failing silently.
    func refreshNewOperations() {
        guard !busy, readable else { return }
        automaticTask?.cancel(); automaticTask = nil
        busy = true; cancelled = false
        message = "Открываю историю банка…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            var ready = await self.historyPageReady()
            if !ready {
                self.webView.load(URLRequest(url: URL(string: "https://bank.yandex.ru/my/transactions-history")!))
                for _ in 0..<30 where !ready && !self.cancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    ready = await self.historyPageReady()
                }
            }
            self.busy = false
            if self.cancelled { self.message = "Обновление остановлено."; return }
            guard ready else {
                self.message = Self.signInNeededMessage
                self.bankPageVisible = true
                return
            }
            self.read(mode: "history", lookbackDays: 30)
        }
    }
    private func incrementalPolicy(now: Date = Date()) -> SyncLookbackResult {
        IncrementalSyncPolicy.calculate(
            history.operations.map { SyncStatusInput(occurredAt: $0.occurredAt, status: $0.status) },
            lastCompletedSync: history.lastCompletedSync,
            now: now
        )
    }
    private func liveScanMaximumDays(now: Date = Date()) -> Int {
        let seconds = max(0, now.timeIntervalSince(StatementImporter.archiveCutoff))
        return max(1, Int(ceil(seconds / 86400)))
    }
    private func effectiveHistoryLookback(_ requested: Int?, now: Date = Date()) -> Int? {
        let maximum = liveScanMaximumDays(now: now)
        guard let requested else { return maximum }
        return min(maximum, max(1, requested))
    }
    private func incrementalDays(now: Date = Date()) -> Int {
        min(incrementalPolicy(now: now).days, liveScanMaximumDays(now: now))
    }
    private static func operationDate(_ value: String) -> Date? { IncrementalSyncPolicy.operationDate(value) }
    private func webViewOperations(_ operations: [BankOperation]) -> [BankOperation] {
        operations.filter { operation in
            guard let date = Self.operationDate(operation.occurredAt) else { return true }
            return date >= StatementImporter.archiveCutoff
        }
    }
    private func webViewIssues(_ issues: [ImportIssue]) -> [ImportIssue] {
        let floorMonthOrdinal = 2026 * 12 + 9
        return issues.filter { issue in
            if let raw = issue.bankDate, let date = Self.operationDate(raw) { return date >= StatementImporter.archiveCutoff }
            if let month = issue.monthOrdinal { return month >= floorMonthOrdinal }
            return true
        }
    }
    func openHistory() {
        guard !busy else { return }
        webView.load(URLRequest(url: URL(string: "https://bank.yandex.ru/my/transactions-history")!))
    }
    func continueInitialHistory() { read(mode: "history", lookbackDays: incrementalDays(), initialImport: false) }

    // Kept under the old method name so existing SwiftUI stays source-compatible.
    // This opens a PDF statement instead of scrolling old months in WebView.
    func syncSixMonthsHistory() {
        guard !busy, readable else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        guard let presenter = topViewController() else {
            message = "Не удалось открыть выбор выписки."
            return
        }
        presenter.present(picker, animated: true)
    }

    private func topViewController() -> UIViewController? {
        let roots = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter(\.isKeyWindow)
            .compactMap(\.rootViewController)
        guard var top = roots.first else { return nil }
        while true {
            if let presented = top.presentedViewController { top = presented; continue }
            if let navigation = top as? UINavigationController, let visible = navigation.visibleViewController { top = visible; continue }
            if let tab = top as? UITabBarController, let selected = tab.selectedViewController { top = selected; continue }
            return top
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        importStatement(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        message = "Импорт выписки отменён."
    }

    private func importStatement(_ url: URL) {
        guard !busy, readable else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try StatementImporter.importPDF(at: url)
            var next = history
            let cutoff = StatementImporter.archiveCutoff

            // Statement is authoritative below 01.10.2026. Replace any partial
            // WebView bootstrap there to avoid the same movement under two IDs.
            next.operations.removeAll { operation in
                guard let date = Self.operationDate(operation.occurredAt) else { return false }
                return date < cutoff
            }
            let floorMonthOrdinal = 2026 * 12 + 9
            next.unresolvedIssues = (next.unresolvedIssues ?? []).filter { issue in
                if let raw = issue.bankDate, let date = Self.operationDate(raw) { return date >= cutoff }
                if let month = issue.monthOrdinal { return month >= floorMonthOrdinal }
                return true
            }

            let counts = apply(result.operations, to: &next)
            guard counts.rejected == 0 else {
                throw AppFailure(message: "Часть операций выписки не прошла проверку: \(counts.rejected). Архив не сохранён.")
            }
            next.statementArchiveThrough = cutoff.addingTimeInterval(-1)
            next.statementImportedAt = Date()
            next.statementOperationCount = result.operations.count
            next.bootstrapCompleted = true
            next.bootstrapResumeMonth = nil
            next.lastStopReason = "statement_archive_imported"
            next.lastSync = Date()
            try vault.save(next)
            history = next
            message = "Выписка импортирована: \(result.operations.count) архивных операций до 01.10.2026. Операций с 01.10.2026 и новее оставлено сканеру: \(result.ignoredAtOrAfterCutoff). Старую историю через WebView больше листать не нужно."
        } catch {
            message = "Не удалось импортировать выписку: \(error.localizedDescription)"
        }
    }

    func retry(_ issue: ImportIssue) {
        guard !busy, readable else { return }
        bankPageVisible = true
        automaticTask?.cancel(); automaticTask = nil
        lastAttempt = Date()
        if let raw = issue.operationURL, let url = URL(string: raw),
           url.scheme == "https", url.host == "bank.yandex.ru", url.path == "/my/transactions-history/operation" {
            if webView.url == url, !webView.isLoading {
                read(mode: "retry_card", lookbackDays: nil, retryIssue: issue)
                return
            }
            pendingRetry = issue
            busy = true
            message = "Открываю пропущенную операцию…"
            webView.load(URLRequest(url: url))
            retryNavigationTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                guard let self, self.pendingRetry != nil else { return }
                self.pendingRetry = nil; self.busy = false
                self.webView.stopLoading()
                self.message = "Карточка не открылась вовремя. Ошибка остаётся в списке; можно повторить."
            }
        } else if issue.monthOrdinal != nil && issue.identity != nil {
            if webView.url?.path != "/my/transactions-history" { message = "Откройте «Настройки» → «Страница банка» → «История», затем повторите поиск пропущенной операции."; return }
            read(mode: "retry", lookbackDays: nil, retryIssue: issue)
        } else {
            message = "У старой ошибки нет ссылки или идентификатора. Откройте нужную карточку вручную; автоматически сопоставить её пока нельзя."
        }
    }
    func read(mode: String, lookbackDays: Int? = 30, initialImport: Bool = false, retryIssue: ImportIssue? = nil, automaticRun: Bool = false) {
        guard !busy, readable else { return }
        guard webView.url?.host == "bank.yandex.ru" else { message = "Сначала завершите вход на сайте банка."; return }
        guard let resource = Bundle.main.url(forResource: "Collector", withExtension: "js"),
              let script = try? String(contentsOf: resource, encoding: .utf8) else { message = "Не найден модуль чтения."; return }
        automaticTask?.cancel(); automaticTask = nil
        lastAttempt = Date(); busy = true; cancelled = false
        checkpointAdded = 0; checkpointChanged = 0
        bootstrapRun = initialImport
        let runID = UUID().uuidString
        activeRunID = runID
        let startedAt = Date()
        let effectiveLookback = mode == "history" ? effectiveHistoryLookback(lookbackDays, now: startedAt) : lookbackDays
        let resume = retryIssue?.monthOrdinal ?? (initialImport ? history.bootstrapResumeMonth : nil)
        message = (mode == "card" || mode == "retry_card") ? "Читаю карточку…" : "Проверяю историю с 01.10.2026. Архив до этой даты берётся из выписки."
        webView.isUserInteractionEnabled = false
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self, self.busy, self.activeRunID == runID else { return }
                await self.flushCheckpointFromWebView()
            }
        }
        let retryData = retryIssue.flatMap { try? JSONEncoder().encode($0) }
        let arguments: [String: Any] = ["mode": mode, "lookbackDays": effectiveLookback.map { NSNumber(value: $0) } ?? NSNull(),
            "resumeMonthOrdinal": resume.map { NSNumber(value: $0) } ?? NSNull(), "runID": runID,
            "archiveFloorISO": StatementImporter.archiveCutoffISO,
            "retryIssueJson": retryData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"]
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.activeRunID == runID else { return }
                self.activeRunID = nil
                self.progressTask?.cancel(); self.progressTask = nil
                defer { self.busy = false; self.webView.isUserInteractionEnabled = true }
                do {
                    guard let string = try result.get() as? String, let data = string.data(using: .utf8) else { throw AppFailure(message: "Неизвестный результат чтения.") }
                    if let failure = try JSONSerialization.jsonObject(with: data) as? [String: Any], let detail = failure["error"] as? String { throw AppFailure(message: detail) }
                    let batch = try JSONDecoder().decode(ImportBatch.self, from: data)
                    try self.merge(batch, initialImport: initialImport, startedAt: startedAt, resumed: resume != nil, mode: mode, requestedDays: effectiveLookback, automaticRun: automaticRun)
                } catch { self.message = "Чтение остановлено: \(error.localizedDescription). Ранее сохранённые записи доступны." }
            }
        }
    }
    private func apply(_ operations: [BankOperation], to next: inout SavedHistory) -> (added: Int, changed: Int, rejected: Int) {
        var byID: [String: BankOperation] = [:]
        for operation in next.operations { byID[operation.identity] = operation }
        var added = 0, changed = 0, rejected = 0
        var resolved = Set<String>()
        for operation in operations {
            guard operation.currency == "RUB", !operation.identity.isEmpty, !operation.description.isEmpty,
                  !operation.status.isEmpty, Self.operationDate(operation.occurredAt) != nil else {
                rejected += 1
                continue
            }
            if let old = byID[operation.identity] {
                if !old.sameFinancialContent(as: operation) { changed += 1 }
            } else { added += 1 }
            byID[operation.identity] = operation
            resolved.insert(operation.identity)
        }
        next.operations = byID.values.sorted { lhs, rhs in
            let lhsDate = Self.operationDate(lhs.occurredAt)
            let rhsDate = Self.operationDate(rhs.occurredAt)
            if let lhsDate, let rhsDate, lhsDate != rhsDate { return lhsDate > rhsDate }
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            return lhs.identity < rhs.identity
        }
        next.unresolvedIssues = (next.unresolvedIssues ?? []).filter { issue in
            guard let identity = issue.identity else { return true }
            return !resolved.contains(identity)
        }
        return (added: added, changed: changed, rejected: rejected)
    }
    private func addIssues(_ issues: [ImportIssue], to next: inout SavedHistory) {
        var items = next.unresolvedIssues ?? []
        for issue in issues {
            if let identity = issue.identity, let index = items.firstIndex(where: { $0.identity == identity }) {
                items[index] = issue
            } else if issue.identity == nil, let operationURL = issue.operationURL,
                      let index = items.firstIndex(where: { $0.identity == nil && $0.operationURL == operationURL }) {
                items[index] = issue
            } else if issue.identity == nil,
                      let index = items.firstIndex(where: { $0.identity == nil && $0.monthOrdinal == issue.monthOrdinal && $0.rowSummary == issue.rowSummary && $0.reason == issue.reason }) {
                items[index] = issue
            } else if !items.contains(issue) {
                items.append(issue)
            }
        }
        next.unresolvedIssues = items
    }
    private func merge(_ batch: ImportBatch, initialImport: Bool, startedAt: Date, resumed: Bool, mode: String, requestedDays: Int?, automaticRun: Bool) throws {
        var next = history
        let acceptedOperations = webViewOperations(batch.operations)
        let acceptedIssues = webViewIssues(batch.issues ?? [])
        let counts = apply(acceptedOperations, to: &next)
        addIssues(acceptedIssues, to: &next)
        let runClean = counts.rejected == 0 && (batch.skippedCount ?? 0) == 0 && acceptedIssues.isEmpty
        let bootstrapClean = runClean && (next.unresolvedIssues ?? []).isEmpty
        let boundaryReached = ["lookback_reached", "history_beginning_reached", "full_history_exhausted"].contains(batch.stopReason)
        if initialImport {
            next.bootstrapResumeMonth = batch.oldestMonthOrdinal ?? next.bootstrapResumeMonth
            next.bootstrapCompleted = boundaryReached && bootstrapClean
            if next.bootstrapCompleted == true { next.bootstrapResumeMonth = nil }
        }
        if mode == "history", boundaryReached, runClean, !resumed, (requestedDays == nil || requestedDays! >= incrementalDays(now: startedAt)) { next.lastCompletedSync = startedAt }
        next.lastSync = Date(); next.lastStopReason = batch.stopReason
        try vault.save(next); history = next
        let ending: String
        if batch.stopReason == "issue_retry_completed" { ending = "Пропущенная операция прочитана." }
        else if batch.stopReason == "issue_not_found" { ending = "Операция не найдена в сохранённом месяце. Ошибка остаётся в списке." }
        else if batch.stopReason == "single_card" { ending = "Карточка прочитана." }
        else if boundaryReached && runClean { ending = "Граница выбранного периода достигнута." }
        else if batch.stopReason == "cancelled" { ending = "Остановлено. Прогресс сохранён." }
        else { ending = "Прогресс сохранён. Полнота периода не подтверждена." }
        message = "Разобрано карточек: \(acceptedOperations.count), добавлено \(checkpointAdded + counts.added), изменено \(checkpointChanged + counts.changed). \(ending)"
        if counts.rejected > 0 { message += " Не сохранено после проверки: \(counts.rejected) (не RUB или неполные обязательные поля)." }
        if let skipped = batch.skippedCount, skipped > 0 { message += " Пропущено: \(skipped)." }
        if let warning = batch.warning, !warning.isEmpty { message += " \(warning)" }
        if mode == "history" && !automaticRun {
            let stalePending = incrementalPolicy(now: startedAt).stalePendingCount
            if stalePending > 0 {
                message += " Старых незавершённых операций старше \(IncrementalSyncPolicy.pendingWatchDays) дней: \(stalePending). Они не расширяют обычное автообновление; при необходимости проверьте их вручную."
            }
        }
    }
    private func flushCheckpointFromWebView() async {
        guard busy, !checkpointInFlight, let runID = activeRunID else { return }
        checkpointInFlight = true
        defer { checkpointInFlight = false }
        let script = """
        if (window.__financeRunID !== expectedRunID) return null;
        const q = window.__financeCheckpointQueue || [];
        return JSON.stringify({runID: window.__financeRunID, progress: window.__financeProgress || '',
          operations: q.map(x => x.operation), throughSequence: q.length ? q[q.length-1].sequence : 0,
          monthOrdinal: window.__financeCheckpointMonth ?? null, issues: window.__financeIssues || []});
        """
        do {
            let raw = try await webView.callAsyncJavaScript(script, arguments: ["expectedRunID": runID], in: nil, contentWorld: .defaultClient)
            guard busy, activeRunID == runID, let string = raw as? String, let data = string.data(using: .utf8) else { return }
            let snapshot = try JSONDecoder().decode(ProgressCheckpoint.self, from: data)
            guard snapshot.runID == runID else { return }
            var next = history
            let counts = apply(webViewOperations(snapshot.operations), to: &next)
            addIssues(webViewIssues(snapshot.issues), to: &next)
            if bootstrapRun { next.bootstrapResumeMonth = snapshot.monthOrdinal ?? next.bootstrapResumeMonth }
            if !snapshot.operations.isEmpty { next.lastSync = Date() }
            try vault.save(next); history = next
            checkpointAdded += counts.added; checkpointChanged += counts.changed
            if !cancelled, !snapshot.progress.isEmpty { message = snapshot.progress }
            _ = try? await webView.callAsyncJavaScript("""
            if (window.__financeRunID !== expectedRunID) return false;
            window.__financeCheckpointQueue = (window.__financeCheckpointQueue || []).filter(x => x.sequence > throughSequence);
            return true;
            """, arguments: ["expectedRunID": runID, "throughSequence": snapshot.throughSequence], in: nil, contentWorld: .defaultClient)
        } catch { }
    }
    func retryOpenStorage() {
        guard !busy else { return }
        do {
            history = try vault.load()
            readable = true
            storageError = nil
            storageRetryFailed = false
            message = "Локальное хранилище снова доступно."
            scheduleAutomaticUpdate()
        } catch {
            readable = false
            storageError = error.localizedDescription
            storageRetryFailed = true
            message = "Хранилище по-прежнему недоступно: \(error.localizedDescription)"
        }
    }

    func resetLocalStorage() {
        guard !busy else { return }
        do {
            try vault.reset()
            history = SavedHistory()
            readable = true
            storageError = nil
            storageRetryFailed = false
            autoUpdate = false
            message = "Локальное хранилище сброшено. Сначала импортируйте PDF-выписку для архива до 01.10.2026, затем обновите текущую историю и включите автообновление."
        } catch {
            message = "Не удалось сбросить локальное хранилище: \(error.localizedDescription)"
        }
    }

    func cancel() {
        guard busy else { return }
        if pendingRetry != nil {
            pendingRetry = nil; retryNavigationTask?.cancel(); webView.stopLoading(); busy = false
            message = "Повторное чтение остановлено. Ошибка остаётся в списке."
            return
        }
        cancelled = true
        webView.evaluateJavaScript("window.__financeCancelled = true", in: nil, in: .defaultClient) { _ in }
        Task { @MainActor [weak self] in await self?.flushCheckpointFromWebView() }
        message = "Останавливаю чтение и сохраняю прогресс…"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host = webView.url?.host ?? ""
        if let issue = pendingRetry {
            pendingRetry = nil; retryNavigationTask?.cancel(); busy = false
            guard webView.url?.host == "bank.yandex.ru", webView.url?.path == "/my/transactions-history/operation" else {
                message = "Войдите в банк и повторите чтение пропущенной операции."; return
            }
            read(mode: "retry_card", lookbackDays: nil, retryIssue: issue)
        } else {
            if webView.url?.host == "bank.yandex.ru", webView.url?.path == "/my/transactions-history", !busy {
                message = ""
            }
            scheduleAutomaticUpdate()
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }
    private func handleNavigationError(_ error: Error) {
        let detail = error as NSError
        if detail.code == NSURLErrorCancelled { return }
        if pendingRetry != nil {
            pendingRetry = nil; retryNavigationTask?.cancel(); busy = false
            webView.isUserInteractionEnabled = true
        }
        message = "Не открылась страница: \(error.localizedDescription). Код: \(detail.code). Ошибка операции остаётся в списке."
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.request.url?.scheme == "https" else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.request.url?.scheme == "https" { webView.load(navigationAction.request) }
        return nil
    }
}
@MainActor
struct BankWebView: UIViewRepresentable {
    let browser: BankBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
