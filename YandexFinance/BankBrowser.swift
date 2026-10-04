import SwiftUI
import WebKit

@MainActor
final class BankBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var busy = false
    @Published var message = "Войдите в банк, затем откройте историю."
    @Published var host = "bank.yandex.ru"
    @Published var history = SavedHistory()
    private let vault = Vault()
    private var readable = true
    private var cancelled = false
    private var foreground = false
    private var automaticTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var lastAttempt: Date?
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
    var bootstrapComplete: Bool { history.bootstrapCompleted == true }
    var canResume: Bool { !bootstrapComplete && history.bootstrapResumeMonth != nil }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        do { history = try vault.load() }
        catch { readable = false; message = "Хранилище не открыто: \(error.localizedDescription)" }
        // Old UserDefaults completion flags do not prove coverage; legacy records remain intact.
        openHistory()
    }
    func becameActive() { foreground = true; scheduleAutomaticUpdate() }
    func becameInactive() {
        foreground = false
        automaticTask?.cancel(); automaticTask = nil
        if busy { Task { @MainActor [weak self] in await self?.flushCheckpointFromWebView() } }
    }
    private func scheduleAutomaticUpdate() {
        guard foreground, autoUpdate, readable, !busy, automaticTask == nil else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 300 { return }
        automaticTask = Task { @MainActor [weak self] in
            for _ in 0..<120 {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, self.foreground, self.autoUpdate, !self.busy else { return }
                guard self.webView.url?.host == "bank.yandex.ru", self.webView.url?.path == "/my/transactions-history", !self.webView.isLoading else { continue }
                let probe = """
                if (location.hostname !== 'bank.yandex.ru' || location.pathname !== '/my/transactions-history') return false;
                return (document.body?.innerText || '').includes('Все карты и счета');
                """
                do {
                    let value = try await self.webView.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: .defaultClient)
                    guard !Task.isCancelled, self.foreground, self.autoUpdate else { return }
                    if value as? Bool == true {
                        self.automaticTask = nil
                        // Fresh data first; older bootstrap work has an explicit continuation action.
                        if self.history.operations.isEmpty { self.continueInitialHistory() }
                        else { self.read(mode: "history", lookbackDays: self.incrementalDays(), initialImport: self.history.lastCompletedSync == nil && self.history.bootstrapResumeMonth == nil) }
                        return
                    }
                } catch { continue }
            }
            self?.automaticTask = nil
        }
    }
    private func incrementalDays(now: Date = Date()) -> Int {
        var start = history.lastCompletedSync?.addingTimeInterval(-7 * 86400)
            ?? now.addingTimeInterval(-183 * 86400)
        for operation in history.operations {
            if operation.status.range(of: "ожида|обработ|в процессе|pending|не указан", options: [.regularExpression, .caseInsensitive]) != nil,
               let date = Self.operationDate(operation.occurredAt) { start = min(start, date.addingTimeInterval(-86400)) }
        }
        for issue in history.unresolvedIssues ?? [] {
            if let ordinal = issue.monthOrdinal,
               let date = Calendar.current.date(from: DateComponents(year: ordinal / 12, month: ordinal % 12 + 1, day: 1)) { start = min(start, date) }
        }
        return max(7, Int(ceil(now.timeIntervalSince(start) / 86400)))
    }
    private static func operationDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    func openHistory() {
        guard !busy else { return }
        webView.load(URLRequest(url: URL(string: "https://bank.yandex.ru/my/transactions-history")!))
    }
    func continueInitialHistory() { read(mode: "history", lookbackDays: 183, initialImport: true) }
    func syncSixMonthsHistory() {
        guard !busy, readable else { return }
        var next = history
        next.bootstrapResumeMonth = nil
        next.bootstrapCompleted = false
        do { try vault.save(next); history = next }
        catch { message = "Не удалось сохранить состояние: \(error.localizedDescription)"; return }
        continueInitialHistory()
    }
    func read(mode: String, lookbackDays: Int? = 30, initialImport: Bool = false) {
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
        let resume = initialImport ? history.bootstrapResumeMonth : nil
        message = mode == "card" ? "Читаю карточку…" : "Проверяю историю. Уже сохранённые записи остаются на телефоне."
        webView.isUserInteractionEnabled = false
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self, self.busy, self.activeRunID == runID else { return }
                await self.flushCheckpointFromWebView()
            }
        }
        let knownData = (try? JSONEncoder().encode(history.operations)) ?? Data("[]".utf8)
        let arguments: [String: Any] = ["mode": mode, "lookbackDays": lookbackDays.map { NSNumber(value: $0) } ?? NSNull(),
            "resumeMonthOrdinal": resume.map { NSNumber(value: $0) } ?? NSNull(), "runID": runID,
            "forceVerification": !initialImport,
            "knownOperationsJson": String(data: knownData, encoding: .utf8) ?? "[]"]
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.activeRunID == runID else { return }
                // Invalidate late snapshots before merging the authoritative final batch.
                self.activeRunID = nil
                self.progressTask?.cancel(); self.progressTask = nil
                defer { self.busy = false; self.webView.isUserInteractionEnabled = true }
                do {
                    guard let string = try result.get() as? String, let data = string.data(using: .utf8) else { throw AppFailure(message: "Неизвестный результат чтения.") }
                    if let failure = try JSONSerialization.jsonObject(with: data) as? [String: Any], let detail = failure["error"] as? String { throw AppFailure(message: detail) }
                    let batch = try JSONDecoder().decode(ImportBatch.self, from: data)
                    try self.merge(batch, initialImport: initialImport, startedAt: startedAt, resumed: resume != nil, mode: mode, requestedDays: lookbackDays)
                } catch { self.message = "Чтение остановлено: \(error.localizedDescription). Ранее сохранённые записи доступны." }
            }
        }
    }
    private func apply(_ operations: [BankOperation], to next: inout SavedHistory) -> (Int, Int) {
        var byID: [String: BankOperation] = [:]
        for operation in next.operations { byID[operation.id] = operation }
        var added = 0, changed = 0
        var resolved = Set<String>()
        for operation in operations {
            guard operation.currency == "RUB", !operation.identity.isEmpty, !operation.description.isEmpty,
                  !operation.status.isEmpty, Self.operationDate(operation.occurredAt) != nil else { continue }
            if let old = byID[operation.id] {
                if !old.sameFinancialContent(as: operation) { changed += 1 }
            } else { added += 1 }
            byID[operation.id] = operation
            resolved.insert(operation.identity)
        }
        next.operations = byID.values.sorted { $0.occurredAt > $1.occurredAt }
        next.unresolvedIssues = (next.unresolvedIssues ?? []).filter { issue in
            guard let identity = issue.identity else { return true }
            return !resolved.contains(identity)
        }
        return (added, changed)
    }
    private func addIssues(_ issues: [ImportIssue], to next: inout SavedHistory) {
        var items = next.unresolvedIssues ?? []
        for issue in issues where !items.contains(issue) { items.append(issue) }
        next.unresolvedIssues = items
    }
    private func merge(_ batch: ImportBatch, initialImport: Bool, startedAt: Date, resumed: Bool, mode: String, requestedDays: Int?) throws {
        var next = history
        let counts = apply(batch.operations, to: &next)
        addIssues(batch.issues ?? [], to: &next)
        let clean = (batch.skippedCount ?? 0) == 0 && (next.unresolvedIssues ?? []).isEmpty
        let boundaryReached = ["lookback_reached", "history_beginning_reached", "full_history_exhausted"].contains(batch.stopReason)
        if initialImport {
            next.bootstrapResumeMonth = batch.oldestMonthOrdinal ?? next.bootstrapResumeMonth
            next.bootstrapCompleted = boundaryReached && clean
            if next.bootstrapCompleted == true { next.bootstrapResumeMonth = nil }
        }
        // A resumed pass covers old months only; it must not advance the fresh-data watermark.
        if mode == "history", boundaryReached, clean, !resumed, (requestedDays == nil || requestedDays! >= incrementalDays(now: startedAt)) { next.lastCompletedSync = startedAt }
        next.lastSync = Date(); next.lastStopReason = batch.stopReason
        try vault.save(next); history = next
        let ending: String
        if batch.stopReason == "single_card" { ending = "Карточка прочитана." }
        else if boundaryReached && clean { ending = "Граница выбранного периода достигнута." }
        else if batch.stopReason == "cancelled" { ending = "Остановлено. Прогресс сохранён." }
        else { ending = "Прогресс сохранён. Полнота периода не подтверждена." }
        message = "Разобрано карточек: \(batch.operations.count), добавлено \(checkpointAdded + counts.0), изменено \(checkpointChanged + counts.1). \(ending)"
        if let skipped = batch.skippedCount, skipped > 0 { message += " Пропущено: \(skipped)." }
        if let warning = batch.warning, !warning.isEmpty { message += " \(warning)" }
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
            let counts = apply(snapshot.operations, to: &next)
            addIssues(snapshot.issues, to: &next)
            if bootstrapRun { next.bootstrapResumeMonth = snapshot.monthOrdinal ?? next.bootstrapResumeMonth }
            if !snapshot.operations.isEmpty { next.lastSync = Date() }
            try vault.save(next); history = next
            checkpointAdded += counts.0; checkpointChanged += counts.1
            if !cancelled, !snapshot.progress.isEmpty { message = snapshot.progress }
            _ = try? await webView.callAsyncJavaScript("""
            if (window.__financeRunID !== expectedRunID) return false;
            window.__financeCheckpointQueue = (window.__financeCheckpointQueue || []).filter(x => x.sequence > throughSequence);
            return true;
            """, arguments: ["expectedRunID": runID, "throughSequence": snapshot.throughSequence], in: nil, contentWorld: .defaultClient)
        } catch { /* Queue remains available to retry; final batch contains all parsed operations. */ }
    }
    func cancel() {
        guard busy else { return }
        cancelled = true
        webView.evaluateJavaScript("window.__financeCancelled = true", in: nil, in: .defaultClient) { _ in }
        Task { @MainActor [weak self] in await self?.flushCheckpointFromWebView() }
        message = "Останавливаю чтение и сохраняю прогресс…"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { host = webView.url?.host ?? ""; scheduleAutomaticUpdate() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { message = "Не открылась страница: \(error.localizedDescription)" }
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
