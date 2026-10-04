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
    private var checkpointAdded = 0
    private var checkpointChanged = 0

    // V18 keeps the same six-month bootstrap marker. Stable already-saved operations
    // can now be verified from their direct list link without reopening the card.
    private let fullHistoryKey = "initialSixMonthsImportedV1"
    private let fullHistoryResumeKey = "fullHistoryResumeOrdinalV2"
    private let boundaryOrdinalKey = "fullHistoryBoundaryOrdinalV2"
    private let boundaryCountKey = "fullHistoryBoundaryCountV2"
    private var fullHistoryImported: Bool {
        get { UserDefaults.standard.bool(forKey: fullHistoryKey) }
        set { UserDefaults.standard.set(newValue, forKey: fullHistoryKey) }
    }

    private var fullHistoryResumeOrdinal: Int? {
        get {
            guard UserDefaults.standard.object(forKey: fullHistoryResumeKey) != nil else { return nil }
            return UserDefaults.standard.integer(forKey: fullHistoryResumeKey)
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: fullHistoryResumeKey) }
            else { UserDefaults.standard.removeObject(forKey: fullHistoryResumeKey) }
        }
    }

    private func clearBoundaryConfirmation() {
        UserDefaults.standard.removeObject(forKey: boundaryOrdinalKey)
        UserDefaults.standard.removeObject(forKey: boundaryCountKey)
    }

    /// Returns true only after the same oldest reachable month has failed to move
    /// farther back twice, and the first observation came after visiting >= 2 months.
    /// This prevents an endless full rescan without declaring the current month to be
    /// the beginning merely because the picker was temporarily unavailable.
    private func confirmStableHistoryBoundary(ordinal: Int, monthsVisited: Int) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: boundaryOrdinalKey) == nil || defaults.integer(forKey: boundaryOrdinalKey) != ordinal {
            guard monthsVisited >= 2 else {
                clearBoundaryConfirmation()
                return false
            }
            defaults.set(ordinal, forKey: boundaryOrdinalKey)
            defaults.set(1, forKey: boundaryCountKey)
            return false
        }
        let next = defaults.integer(forKey: boundaryCountKey) + 1
        defaults.set(next, forKey: boundaryCountKey)
        return next >= 2
    }

    @Published var autoUpdate = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate")
            if autoUpdate { scheduleAutomaticUpdate() }
            else { automaticTask?.cancel(); automaticTask = nil }
        }
    }

    func becameActive() {
        foreground = true
        scheduleAutomaticUpdate()
    }

    func becameInactive() {
        foreground = false
        automaticTask?.cancel()
        automaticTask = nil
        // Do not cancel an active import on .inactive/.background. iOS can enter
        // .inactive for Control Center, notifications, permission sheets, etc.
        // Flush the JavaScript queue before suspension so only the last small
        // in-flight chunk can be lost if iOS later kills the process.
        if busy {
            Task { @MainActor [weak self] in await self?.flushCheckpointFromWebView() }
        }
    }

    private func scheduleAutomaticUpdate() {
        guard foreground, autoUpdate, readable, !busy, automaticTask == nil else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 300 { return }
        automaticTask = Task { @MainActor [weak self] in
            // Wait for manual login and the history UI, without reading authentication pages.
            for _ in 0..<120 {
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return }
                guard let self, self.foreground, self.autoUpdate, !self.busy else { return }
                guard self.webView.url?.host == "bank.yandex.ru",
                      self.webView.url?.path == "/my/transactions-history", !self.webView.isLoading else { continue }
                let probe = """
                if (location.hostname !== 'bank.yandex.ru' || location.pathname !== '/my/transactions-history') return false;
                const body = document.body?.innerText || '';
                return body.includes('Все карты и счета') && /История|Январь|Февраль|Март|Апрель|Май|Июнь|Июль|Август|Сентябрь|Октябрь|Ноябрь|Декабрь/.test(body);
                """
                let ready: Bool
                do {
                    let value = try await self.webView.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: .defaultClient)
                    ready = value as? Bool ?? false
                } catch { continue }
                guard !Task.isCancelled, self.foreground, self.autoUpdate else { return }
                if ready {
                    self.automaticTask = nil
                    self.read(mode: "history", lookbackDays: self.fullHistoryImported ? 7 : 183)
                    return
                }
            }
            self?.automaticTask = nil
        }
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        do {
            history = try vault.load()
            if history.operations.isEmpty {
                fullHistoryImported = false
                fullHistoryResumeOrdinal = nil
                clearBoundaryConfirmation()
            }
        } catch {
            readable = false
            message = "Хранилище не открыто: \(error.localizedDescription)"
        }
        openHistory()
    }

    func openHistory() {
        guard !busy else { return }
        webView.load(URLRequest(url: URL(string: "https://bank.yandex.ru/my/transactions-history")!))
    }

    func syncSixMonthsHistory() {
        fullHistoryImported = false
        fullHistoryResumeOrdinal = nil
        clearBoundaryConfirmation()
        read(mode: "history", lookbackDays: 183)
    }

    func read(mode: String, lookbackDays: Int? = 30) {
        guard !busy, readable else { return }
        guard webView.url?.host == "bank.yandex.ru" else {
            message = "Сначала завершите вход на сайте банка."
            return
        }
        guard let resource = Bundle.main.url(forResource: "Collector", withExtension: "js"),
              let script = try? String(contentsOf: resource, encoding: .utf8) else {
            message = "Не найден модуль чтения истории."
            return
        }

        automaticTask?.cancel()
        automaticTask = nil
        lastAttempt = Date()
        busy = true
        cancelled = false
        checkpointAdded = 0
        checkpointChanged = 0

        if mode == "card" {
            message = "Читаю карточку…"
        } else if let lookbackDays {
            message = "Читаю последние \(lookbackDays) дней. Не переключайте страницу…"
        } else {
            message = "Синхронизация: читаю последние 6 месяцев. Не переключайте страницу…"
        }

        webView.isUserInteractionEnabled = false
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                catch { return }
                guard let self, self.busy else { return }
                await self.flushCheckpointFromWebView()
            }
        }

        let lookbackArgument: Any = lookbackDays.map { NSNumber(value: $0) } ?? NSNull()
        let shouldResumeInitialImport = mode == "history" && !fullHistoryImported && (lookbackDays == 183 || lookbackDays == nil)
        let resumeArgument: Any = (shouldResumeInitialImport ? fullHistoryResumeOrdinal : nil)
            .map { NSNumber(value: $0) } ?? NSNull()
        let knownOperationsJSON: String
        do {
            let data = try JSONEncoder().encode(history.operations)
            knownOperationsJSON = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            knownOperationsJSON = "[]"
        }
        webView.callAsyncJavaScript(
            script,
            arguments: ["mode": mode, "lookbackDays": lookbackArgument, "resumeMonthOrdinal": resumeArgument,
                        "knownOperationsJson": knownOperationsJSON],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.progressTask?.cancel()
                    self.progressTask = nil
                    self.busy = false
                    self.webView.isUserInteractionEnabled = true
                }
                do {
                    let raw = try result.get()
                    guard let string = raw as? String, let data = string.data(using: .utf8) else {
                        throw AppFailure(message: "Страница вернула неизвестный результат.")
                    }
                    if let failure = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let detail = failure["error"] as? String {
                        throw AppFailure(message: detail)
                    }
                    let batch = try JSONDecoder().decode(ImportBatch.self, from: data)
                    try self.merge(batch, requestedLookbackDays: mode == "card" ? nil : lookbackDays)
                } catch {
                    let nativeError = error as NSError
                    let detail = nativeError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    let checkpointed = self.checkpointAdded + self.checkpointChanged
                    self.message = checkpointed > 0
                        ? "Чтение остановлено: \(detail). Уже сохранено операций из этого прохода: \(checkpointed)."
                        : "Чтение остановлено: \(detail)"
                    self.checkpointAdded = 0
                    self.checkpointChanged = 0
                }
            }
        }
    }

    private func merge(_ batch: ImportBatch, requestedLookbackDays: Int?) throws {
        // An empty successful batch is meaningful: for example there may have been
        // no operations in the last seven days, or an empty account may have reached
        // the beginning of history. Do not turn those states into an error.
        var byID: [String: BankOperation] = [:]
        for operation in history.operations { byID[operation.id] = operation }

        var added = checkpointAdded
        var changed = checkpointChanged
        var rejected = 0
        for operation in batch.operations {
            guard operation.currency == "RUB", !operation.identity.isEmpty,
                  !operation.description.isEmpty, !operation.status.isEmpty else {
                rejected += 1
                continue
            }
            if let old = byID[operation.id] {
                if old != operation { changed += 1 }
            } else {
                added += 1
            }
            byID[operation.id] = operation
        }
        if !batch.operations.isEmpty && added + changed == 0 && batch.operations.count == rejected {
            throw AppFailure(message: "Все полученные операции содержат неполные данные.")
        }

        let next = SavedHistory(
            operations: byID.values.sorted { $0.occurredAt > $1.occurredAt },
            lastSync: Date(),
            lastStopReason: batch.stopReason
        )
        try vault.save(next)
        history = next

        let skipped = (batch.skippedCount ?? 0) + rejected
        let isFullHistorySync = requestedLookbackDays == 183 && batch.stopReason != "single_card"
        var acceptedStableBoundary = false

        if isFullHistorySync {
            switch batch.stopReason {
            case "lookback_reached", "history_beginning_reached", "full_history_exhausted":
                // Reaching the beginning and parsing every single card are separate
                // facts. One malformed card must not force a complete rescan forever.
                fullHistoryImported = true
                fullHistoryResumeOrdinal = nil
                clearBoundaryConfirmation()
            case "month_navigation_unavailable":
                if let oldest = batch.oldestMonthOrdinal,
                   confirmStableHistoryBoundary(ordinal: oldest, monthsVisited: batch.monthsVisited ?? 0) {
                    // The site did not expose a textual "beginning" marker, but the
                    // same oldest reachable month was observed twice. Treat traversal
                    // as complete while keeping any skipped-card warning visible.
                    acceptedStableBoundary = true
                    fullHistoryImported = true
                    fullHistoryResumeOrdinal = nil
                    clearBoundaryConfirmation()
                } else {
                    fullHistoryResumeOrdinal = batch.oldestMonthOrdinal
                }
            case "cancelled", "interrupted", "loading_timeout", "limit_reached":
                fullHistoryResumeOrdinal = batch.oldestMonthOrdinal
                clearBoundaryConfirmation()
            default:
                clearBoundaryConfirmation()
            }
        }

        let ending: String
        switch batch.stopReason {
        case "lookback_reached":
            ending = requestedLookbackDays == 183 ? "Первичная синхронизация последних 6 месяцев завершена; дальше автоматически проверяются последние 7 дней." : "Достигнута граница \(requestedLookbackDays ?? 0) дней."
        case "loading_timeout":
            ending = isFullHistorySync
                ? "Сохранено всё, что удалось прочитать. Полная синхронизация продолжится с последнего достигнутого месяца."
                : "Сохранено всё, что удалось прочитать. Период проверен не полностью."
        case "single_card":
            ending = "Прочитана одна карточка."
        case "limit_reached":
            ending = isFullHistorySync
                ? "Достигнут защитный предел. Прогресс сохранён; следующий полный проход продолжится с последнего месяца."
                : "Достигнут предел чтения; прогресс сохранён, период проверен не полностью."
        case "full_history_exhausted":
            ending = skipped == 0
                ? "Полная доступная история прочитана."
                : "Полная доступная история пройдена. Не удалось разобрать карточек: \(skipped); автоматические обновления всё равно переключены на последние 7 дней."
        case "history_beginning_reached":
            ending = isFullHistorySync ? "Доступная история короче 6 месяцев; первичная синхронизация завершена." : "Достигнуто начало доступной истории банка."
        case "month_navigation_unavailable":
            if acceptedStableBoundary {
                ending = "Одинаковая нижняя граница истории подтверждена повторно. Полный проход завершён; дальше будут проверяться последние 7 дней."
            } else {
                ending = isFullHistorySync
                    ? "Переход к более старому периоду не подтверждён. Прогресс сохранён; следующая попытка продолжится с этого месяца, а не с начала."
                    : "Не удалось перейти к предыдущему периоду; прогресс сохранён, период проверен не полностью."
            }
        case "cancelled":
            ending = "Остановлено пользователем. Уже прочитанные операции сохранены."
        case "interrupted":
            ending = "Сайт прервал чтение. Уже прочитанные операции сохранены."
        default:
            ending = "Прогресс сохранён, но полнота периода не подтверждена."
        }

        let fast = batch.fastSkippedCount ?? 0
        let openedCards = batch.openedCardCount ?? 0
        var parts = ["Прочитано новых/изменённых \(batch.operations.count), добавлено \(added), изменено \(changed).", ending]
        if fast > 0 || openedCards > 0 { parts.append("Быстро проверено: \(fast), открыто карточек: \(openedCards).") }
        if skipped > 0 { parts.append("Пропущено: \(skipped).") }
        if let warning = batch.warning, !warning.isEmpty { parts.append("Причина: \(warning)") }
        message = parts.joined(separator: " ")
        checkpointAdded = 0
        checkpointChanged = 0
    }

    private func persistCheckpoint(_ operations: [BankOperation]) throws {
        guard !operations.isEmpty else { return }
        var byID: [String: BankOperation] = [:]
        for operation in history.operations { byID[operation.id] = operation }

        var added = 0
        var changed = 0
        for operation in operations {
            guard operation.currency == "RUB", !operation.identity.isEmpty,
                  !operation.description.isEmpty, !operation.status.isEmpty else { continue }
            if let old = byID[operation.id] {
                if old != operation { changed += 1 }
            } else {
                added += 1
            }
            byID[operation.id] = operation
        }
        guard added > 0 || changed > 0 else { return }
        let next = SavedHistory(
            operations: byID.values.sorted { $0.occurredAt > $1.occurredAt },
            lastSync: Date(),
            lastStopReason: history.lastStopReason
        )
        try vault.save(next)
        history = next
        checkpointAdded += added
        checkpointChanged += changed
    }

    private func flushCheckpointFromWebView() async {
        guard busy else { return }
        let script = """
        const q = Array.isArray(window.__financeCheckpointQueue) ? window.__financeCheckpointQueue : [];
        return JSON.stringify({progress: window.__financeProgress || '', operations: q.slice(), count: q.length});
        """
        do {
            let raw = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
            guard let string = raw as? String, let data = string.data(using: .utf8) else { return }
            let snapshot = try JSONDecoder().decode(ProgressCheckpoint.self, from: data)
            if !cancelled && !snapshot.progress.isEmpty { message = snapshot.progress }
            if snapshot.count > 0 {
                try persistCheckpoint(snapshot.operations)
                // Remove only the prefix we successfully persisted. Operations
                // appended after the snapshot remain queued for the next flush.
                _ = try? await webView.callAsyncJavaScript(
                    "if (Array.isArray(window.__financeCheckpointQueue)) window.__financeCheckpointQueue.splice(0, Math.max(0, Number(count) || 0)); return true;",
                    arguments: ["count": snapshot.count], in: nil, contentWorld: .defaultClient
                )
            }
        } catch {
            // Keep the JS queue intact; a later poll or the final batch can retry.
        }
    }

    func cancel() {
        guard busy else { return }
        cancelled = true
        webView.evaluateJavaScript("window.__financeCancelled = true", in: nil, in: .defaultClient) { _ in }
        Task { @MainActor [weak self] in await self?.flushCheckpointFromWebView() }
        message = "Останавливаю чтение и сохраняю уже прочитанные операции…"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host = webView.url?.host ?? ""
        scheduleAutomaticUpdate()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            message = "Не открылась страница: \(error.localizedDescription)"
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Manual authentication may visit Yandex identity domains. Never read their DOM.
        guard navigationAction.request.url?.scheme == "https" else {
            message = "Этот переход не поддерживается тестовой версией."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.request.url?.scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

@MainActor
struct BankWebView: UIViewRepresentable {
    let browser: BankBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
