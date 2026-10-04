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
        if busy { cancel() }
    }

    private func scheduleAutomaticUpdate() {
        guard foreground, autoUpdate, readable, !busy, automaticTask == nil else { return }
        if let lastAttempt = lastAttempt, Date().timeIntervalSince(lastAttempt) < 300 { return }
        automaticTask = Task { @MainActor [weak self] in
            // Wait for manual login and the history UI, without reading authentication pages.
            for _ in 0..<120 {
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return }
                guard let self = self, self.foreground, self.autoUpdate, !self.busy else { return }
                guard self.webView.url?.host == "bank.yandex.ru",
                      self.webView.url?.path == "/my/transactions-history", !self.webView.isLoading else { continue }
                let probe = """
                if (location.hostname !== 'bank.yandex.ru' || location.pathname !== '/my/transactions-history') return false;
                const body = document.body?.innerText || '';
                return body.includes('Все карты и счета') && /[+−–-]\\s*[\\d\\s.,]+\\s*₽/.test(body);
                """
                let ready: Bool
                do {
                    let value = try await self.webView.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: .defaultClient)
                    ready = value as? Bool ?? false
                } catch { continue }
                guard !Task.isCancelled, self.foreground, self.autoUpdate else { return }
                if ready {
                    self.automaticTask = nil
                    self.read(mode: "history")
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
        do { history = try vault.load() }
        catch { readable = false; message = "Хранилище не открыто: \(error.localizedDescription)" }
        openHistory()
    }

    func openHistory() {
        guard !busy else { return }
        webView.load(URLRequest(url: URL(string: "https://bank.yandex.ru/my/transactions-history")!))
    }

    func read(mode: String) {
        guard !busy, readable else { return }
        guard webView.url?.host == "bank.yandex.ru" else {
            message = "Сначала завершите вход на сайте банка."; return
        }
        guard let resource = Bundle.main.url(forResource: "Collector", withExtension: "js"),
              let script = try? String(contentsOf: resource, encoding: .utf8) else {
            message = "Не найден модуль чтения истории."; return
        }
        automaticTask?.cancel()
        automaticTask = nil
        lastAttempt = Date()
        busy = true
        cancelled = false
        message = mode == "card" ? "Читаю карточку…" : "Читаю последние 30 дней. Не переключайте страницу…"
        webView.isUserInteractionEnabled = false
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self = self, self.busy, !self.cancelled else { return }
                do {
                    let value = try await self.webView.callAsyncJavaScript("return window.__financeProgress || '';", arguments: [:], in: nil, contentWorld: .defaultClient)
                    guard !Task.isCancelled, self.busy, !self.cancelled else { return }
                    if let progress = value as? String, !progress.isEmpty { self.message = progress }
                } catch { }
            }
        }
        webView.callAsyncJavaScript(script, arguments: ["mode": mode], in: nil, in: .defaultClient) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                defer { self.progressTask?.cancel(); self.progressTask = nil; self.busy = false; self.webView.isUserInteractionEnabled = true }
                do {
                    guard !self.cancelled else { throw AppFailure(message: "Чтение отменено.") }
                    let raw = try result.get()
                    guard let string = raw as? String, let data = string.data(using: .utf8) else {
                        throw AppFailure(message: "Страница вернула неизвестный результат.")
                    }
                    if let failure = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let detail = failure["error"] as? String {
                        throw AppFailure(message: detail)
                    }
                    let batch = try JSONDecoder().decode(ImportBatch.self, from: data)
                    try self.merge(batch)
                } catch {
                    let nativeError = error as NSError
                    let detail = nativeError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    self.message = "Чтение остановлено, записи не сохранены: \(detail)"
                }
            }
        }
    }

    private func merge(_ batch: ImportBatch) throws {
        guard !batch.operations.isEmpty else { throw AppFailure(message: "Нет операций для сохранения.") }
        var byID = Dictionary(uniqueKeysWithValues: history.operations.map { ($0.id, $0) })
        var added = 0, changed = 0
        for operation in batch.operations {
            guard operation.currency == "RUB", !operation.identity.isEmpty,
                  !operation.description.isEmpty, !operation.status.isEmpty else {
                throw AppFailure(message: "Неполные данные операции.")
            }
            if let old = byID[operation.id] { if old != operation { changed += 1 } }
            else { added += 1 }
            byID[operation.id] = operation
        }
        let next = SavedHistory(operations: byID.values.sorted { $0.occurredAt > $1.occurredAt },
                                lastSync: Date(), lastStopReason: batch.stopReason)
        try vault.save(next)
        history = next
        let ending: String
        switch batch.stopReason {
        case "lookback_reached": ending = "Достигнута граница 30 дней."
        case "single_card": ending = "Прочитана одна карточка."
        case "limit_reached": ending = "Достигнут предел чтения; полнота истории не подтверждена."
        default: ending = "Сайт перестал догружать строки. Полнота истории не подтверждена."
        }
        message = "Прочитано \(batch.operations.count), добавлено \(added), изменено \(changed). \(ending)"
    }

    func cancel() {
        cancelled = true
        webView.evaluateJavaScript("window.__financeCancelled = true", in: nil, in: .defaultClient) { _ in }
        message = "Останавливаю чтение…"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host = webView.url?.host ?? ""
        scheduleAutomaticUpdate()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { message = "Не открылась страница: \(error.localizedDescription)" }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Manual authentication may visit Yandex identity domains. Never read their DOM.
        guard navigationAction.request.url?.scheme == "https" else {
            message = "Этот переход не поддерживается тестовой версией."
            decisionHandler(.cancel); return
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
