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
    /// A line over the bank page after «copy the text of the page».
    @Published var pageTextNotice = ""
    /// The bank page is in front because the bank asked to sign in (shows the code hint).
    @Published private(set) var signInRequested = false
    private var signInWatch: Task<Void, Never>?
    /// The app's own window for the confirmation code is shown over the hidden bank page (46.28).
    @Published private(set) var codeEntryVisible = false
    /// Why the last code was not accepted, in the owner's words; nil when there is nothing to say.
    @Published private(set) var codeEntryError: String?
    /// The code is being put into the bank page and its answer awaited.
    @Published private(set) var codeSubmitting = false
    /// How many digits the bank's field takes (its group of fields or its length); 4 when the page does not say.
    @Published private(set) var codeLength = 4
    /// The owner chose the bank page itself for this sign-in: the code window does not come back over it.
    private var preferBankPage = false
    /// The balances are being read (the bank's main page may be open for it): a second reading does not start meanwhile.
    private var readingBalances = false
    /// The number of the current sign-in and of the current code sent: an answer that comes for an older one is dropped (a
    /// cancelled sign-in must not bring its window back, a new code must not get the error or the end of an older one).
    private var signInGeneration = 0
    private var submitGeneration = 0
    /// The number of the current reading of the balances; a refresh or a scan that starts makes it stop (B59-1).
    private var balanceReaderGeneration = 0
    @Published var busy = false
    @Published var message = ""
    @Published private(set) var statementPreview: StatementImportPreview?
    private var statementPreviewBase: Data?
    @Published var host = "bank.yandex.ru"
    @Published var history = SavedHistory()
    /// What the owner has saved but the screens have not been given yet (see `updateUserDataAfterClosing`). Every later change,
    /// the backup and the scans start from it, so two quick changes never overwrite one another.
    private var pendingHistory: SavedHistory?

    /// Gives the screens what is waiting.
    private func settlePending() {
        if let waiting = pendingHistory {
            pendingHistory = nil
            history = waiting
        }
    }
    @Published private(set) var storageError: String?
    @Published private(set) var storageRetryFailed = false
    private let vault = Vault()
    /// False until the encrypted history is read: nothing may be saved over it before that.
    private var readable = false
    /// True while the history is being read at launch; the screens show placeholders meanwhile.
    @Published private(set) var loadingHistory = true
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
            if autoUpdate {
                // Switched on while the app runs: the bank page was not opened at launch, so open it now.
                if webView.url == nil { openHistory() }
                scheduleAutomaticUpdate()
            } else { automaticTask?.cancel(); automaticTask = nil }
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
        // With «Обновлять при открытии» off the bank page is not opened at launch: an unsigned page makes the bank send
        // an SMS code nobody is waiting for. «Обновить новые операции» opens it (and the sign-in window) when asked.
        if autoUpdate { openHistory() }
        // Decrypting and decoding the history off the main thread lets the first frame appear at once.
        Task { await loadHistory() }
    }

    private func loadHistory() async {
        let vault = self.vault
        let result = await Task.detached(priority: .userInitiated) { Result { try vault.load() } }.value
        // A restore or reset done meanwhile wins over what was read at launch.
        guard loadingHistory else { return }
        switch result {
        case .success(var loaded):
            loaded.moveTransfersToOwnGroup()
            history = loaded
            readable = true
        case .failure(let error):
            readable = false
            storageError = error.localizedDescription
            message = "Хранилище не открыто: \(error.localizedDescription)"
        }
        loadingHistory = false
        scheduleAutomaticUpdate()
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
                // The bank's main page is open for a moment to read the balances: that is not a request to sign in.
                if self.readingBalances { continue }
                let state = await self.bankPageState()
                if state == .codeRequested {
                    self.automaticTask = nil
                    self.requestSignIn()
                    return
                }
                guard state == .history else { continue }
                guard !Task.isCancelled, self.foreground, self.autoUpdate else { return }
                self.automaticTask = nil
                self.read(mode: "history", lookbackDays: self.incrementalDays(), initialImport: false, automaticRun: true)
                return
            }
            guard let self else { return }
            self.automaticTask = nil
            guard self.foreground, self.autoUpdate, !self.busy else { return }
            // A page that loaded but shows no history means the bank wants a sign-in; without any page we are offline.
            if self.webView.url != nil && !self.webView.isLoading {
                self.requestSignIn()
            } else {
                self.message = "Не удалось открыть историю банка. Проверьте интернет и обновите операции в «Настройках»."
            }
        }
    }

    static let signInNeededMessage = "Банк просит войти. Введите код из SMS на странице банка — после входа обновление продолжится само."

    /// Brings the bank page to the front for sign-in and waits up to ten minutes for the signed-in history;
    /// then hides the page again and runs the refresh that was interrupted.
    func requestSignIn() {
        message = Self.signInNeededMessage
        signInRequested = true
        preferBankPage = false
        signInWatch?.cancel()
        signInGeneration += 1
        let generation = signInGeneration
        signInWatch = Task { @MainActor [weak self] in
            // The code window when the bank asks for a code; its own page for anything else (a phone number, a check).
            guard let first = self else { return }
            let opening = await first.bankPageState()
            guard first.signInGeneration == generation, first.signInRequested else { return }
            if opening == .codeRequested { first.showCodeEntry() } else { first.bankPageVisible = true }
            var otherSeconds = 0
            for _ in 0..<600 {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.signInGeneration == generation, self.signInRequested else { return }
                let state = await self.bankPageState()
                guard self.signInGeneration == generation, self.signInRequested else { return }
                if state == .codeRequested {
                    otherSeconds = 0
                    if !self.codeEntryVisible && !self.preferBankPage { self.showCodeEntry() }
                } else if state == .other && self.codeEntryVisible && !self.codeSubmitting {
                    // The bank moved on to something the window cannot do: its page takes over after a few seconds.
                    otherSeconds += 1
                    if otherSeconds >= 4 {
                        self.codeEntryVisible = false
                        self.bankPageVisible = true
                    }
                }
                if self.webView.url?.host == "bank.yandex.ru", self.webView.url?.path != "/my/transactions-history", !self.webView.isLoading,
                   let path = self.webView.url?.path, path == "/" || path.hasPrefix("/my") {
                    // Signed in but landed elsewhere in the bank: go to the history the scanner reads.
                    self.webView.load(URLRequest(url: URL(string: "https://bank.yandex.ru/my/transactions-history")!))
                    continue
                }
                let ready = await self.historyPageReady()
                guard self.signInGeneration == generation, self.signInRequested else { return }
                guard ready else { continue }
                self.finishSignIn()
                self.message = "Вход выполнен, обновляю операции…"
                self.read(mode: "history", lookbackDays: self.incrementalDays())
                return
            }
            // Ten minutes without a sign-in: the waiting ends, the window and the page close, the owner starts again later.
            guard let self, self.signInGeneration == generation, self.signInRequested else { return }
            self.finishSignIn()
            self.message = "Вход не завершён за 10 минут. Обновите операции, когда будете готовы войти."
        }
    }

    /// Hides the bank page and stops waiting for a sign-in (also used by «Готово»).
    func finishSignIn() {
        signInWatch?.cancel(); signInWatch = nil
        signInGeneration += 1
        signInRequested = false
        bankPageVisible = false
        codeEntryVisible = false
        codeEntryError = nil
        codeSubmitting = false
        preferBankPage = false
    }

    // MARK: - The code window

    /// The same search for the code field everywhere: one field marked for a one-time code, a group of one-digit fields, or one
    /// numeric field of 4–6 digits; fields of a phone, a search, an e-mail or a password and hidden ones are never taken.
    private static let codeFieldsJS = """
    const visible = el => !!el && el.getClientRects().length > 0 && !el.disabled && !el.readOnly;
    const meta = el => [el.name, el.id, el.placeholder, el.getAttribute('aria-label')].filter(Boolean).join(' ').toLowerCase();
    const bad = el => ['search', 'email', 'password'].includes((el.type || '').toLowerCase()) ||
        /phone|тел|поиск|search|mail|post|zip|index|индекс|почт|promo|промо|coupon|купон/.test(meta(el));
    const inputs = [...document.querySelectorAll('input')].filter(el => visible(el) && !bad(el));
    const groupOf = el => {
        const same = inputs.filter(other => other.parentElement === el.parentElement && other.maxLength === 1);
        if (same.length >= 3 && same.length <= 8) return same;
        const outer = inputs.filter(other => other.maxLength === 1 && other.parentElement && el.parentElement &&
                                             other.parentElement.parentElement === el.parentElement.parentElement);
        return outer.length >= 3 && outer.length <= 8 ? outer : null;
    };
    // Only what is clearly a code: a field marked for a one-time code, else one field named as a code, else one group of
    // one-digit fields. A numeric field of 4–6 digits alone (a postal code) is not taken; two candidates of the same kind are
    // not guessed between: the bank page itself then takes the code.
    const findCodeFields = () => {
        const marked = inputs.filter(el => (el.autocomplete || '').toLowerCase() === 'one-time-code');
        if (marked.length) {
            if (marked[0].maxLength !== 1) return marked.length === 1 ? [marked[0]] : [];
            const markedGroups = [];
            for (const el of marked) {
                const group = groupOf(el) || [el];
                if (!markedGroups.some(known => known.includes(el))) markedGroups.push(group);
            }
            return markedGroups.length === 1 ? markedGroups[0] : [];
        }
        const named = inputs.filter(el => el.maxLength !== 1 && /код|code|otp|pin|смс|sms/.test(meta(el)));
        if (named.length) return named.length === 1 ? named : [];
        const groups = [];
        for (const el of inputs) {
            if (el.maxLength !== 1) continue;
            const group = groupOf(el);
            if (group && !groups.some(known => known[0] === group[0])) groups.push(group);
        }
        return groups.length === 1 ? groups[0] : [];
    };
    // The block of the code: its form or dialog, else a few levels around the field; errors, the wait and «request again» are
    // looked for there only, not in the whole page.
    const codeArea = fields => {
        if (!fields.length) return null;
        const holder = fields[0].closest('form, [role="dialog"]');
        if (holder) return holder;
        let box = fields[0];
        for (let step = 0; step < 3 && box.parentElement && box.parentElement !== document.body &&
                           box.parentElement.tagName !== 'HTML'; step++) box = box.parentElement;
        return box;
    };
    """

    private func showCodeEntry() {
        codeEntryError = nil
        codeEntryVisible = true
        bankPageVisible = false
        let session = signInGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let script = Self.codeFieldsJS + """
            const fields = findCodeFields();
            if (fields.length > 1) return fields.length;
            if (fields.length === 1 && fields[0].maxLength >= 4 && fields[0].maxLength <= 6) return fields[0].maxLength;
            return 4;
            """
            let answer = try? await self.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
            // A late answer of an earlier sign-in must not change the length the window of this one sends at.
            if self.signInGeneration == session, let length = answer as? Int, (4...6).contains(length) {
                self.codeLength = length
            }
        }
    }

    /// The owner chose the bank page for this sign-in: the window closes and does not come back until the next sign-in.
    func showBankPageForSignIn() {
        preferBankPage = true
        codeEntryVisible = false
        codeEntryError = nil
        bankPageVisible = true
    }

    /// «Отмена» in the code window: no sign-in now.
    func cancelSignIn() {
        finishSignIn()
        message = "Вход отменён. Обновите операции, когда будет удобно."
    }

    /// Puts the code the owner typed into the bank page (the bank's own sign-in goes on there) and waits for its answer: the
    /// history (the watcher of the sign-in then finishes it), an error next to the field, or nothing for ten seconds.
    func submitCode(_ code: String) async {
        let digits = code.filter(\.isNumber)
        guard !codeSubmitting, !digits.isEmpty else { return }
        submitGeneration += 1
        let attempt = submitGeneration
        let session = signInGeneration
        // Still the same sign-in and the latest code: only then may an answer change what the window shows.
        func current() -> Bool { signInGeneration == session && submitGeneration == attempt }
        codeEntryError = nil
        codeSubmitting = true
        defer { if current() { codeSubmitting = false } }
        let fill = Self.codeFieldsJS + """
        const fields = findCodeFields();
        if (!fields.length) return { ok: false, reason: 'field_not_found' };
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        const put = (el, value) => {
            el.focus();
            setter.call(el, value);
            el.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, inputType: 'insertText', data: value }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        if (fields.length === 1) { put(fields[0], code); return { ok: fields[0].value === code, mode: 'single' }; }
        if (code.length < fields.length) return { ok: false, reason: 'code_too_short' };
        // A group of one-digit fields: the bank often spreads a pasted code itself; if not, one digit into each field.
        try {
            const data = new DataTransfer();
            data.setData('text/plain', code);
            fields[0].focus();
            fields[0].dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: data }));
        } catch (error) {}
        if (fields.every((el, index) => el.value === code[index])) return { ok: true, mode: 'paste' };
        fields.forEach((el, index) => {
            put(el, code[index]);
            el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: code[index] }));
        });
        return { ok: fields.every((el, index) => el.value === code[index]), mode: 'digits' };
        """
        let result = try? await webView.callAsyncJavaScript(fill, arguments: ["code": digits], in: nil, contentWorld: .defaultClient)
        guard current() else { return }
        guard let answer = result as? [String: Any], answer["ok"] as? Bool == true else {
            codeEntryError = "Не получилось вписать код на странице банка. Откройте страницу банка и введите код там."
            return
        }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Signed in: the watcher has already finished the sign-in and started the refresh.
            guard current(), signInRequested else { return }
            let rejected = await codeRejected()
            guard current() else { return }
            if rejected {
                codeEntryError = "Банк не принял код. Проверьте цифры или запросите новый."
                return
            }
            let state = await bankPageState()
            guard current() else { return }
            if state != .codeRequested { return }
        }
        codeEntryError = "Банк пока не ответил. Попробуйте ещё раз или откройте страницу банка."
    }

    /// The balances on the bank page: a «Карта» / «Карта Пэй» or «Сейвы» / «Счёт в Сейвах» label with one sum without a sign in
    /// its own block (the sums of operations always have «−» or «+»; a block that also names «Сплит», «Баллы» or the other account is
    /// not taken: its sum may be theirs). The history shows no balances, the bank's main page («Главный») does: it is opened for
    /// a moment and the history is loaded back. The reading never takes the page from a refresh or a sign-in: it does not start
    /// while one runs, stops when one starts, and only a reading that still owns the page brings the history back.
    private func readBankBalances() async {
        guard !readingBalances, !busy, !signInRequested else { return }
        readingBalances = true
        defer { readingBalances = false }
        balanceReaderGeneration += 1
        let generation = balanceReaderGeneration
        // Still this reading's page: no refresh, no scan and no sign-in started meanwhile.
        func owns() -> Bool { balanceReaderGeneration == generation && !busy && !signInRequested }
        if await readBalancesOnPage(owns) { return }
        guard owns() else { return }
        let tap = """
        const leaf = [...document.querySelectorAll('body *')].find(el => el.children.length === 0 && el.getClientRects().length > 0 &&
            /^главн(ый|ая)$/i.test((el.textContent || '').trim()));
        const target = leaf ? (leaf.closest('a, button, [role="button"], [role="tab"], [role="link"]') || leaf) : null;
        if (target) target.click();
        return !!target;
        """
        let tapped = (try? await webView.callAsyncJavaScript(tap, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool) == true
        guard tapped else { return }
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard owns() else { break }
            if await readBalancesOnPage(owns) { break }
        }
        // Back to the history the scanner reads. A refresh or a scan that took over loads it itself; a sign-in keeps its page.
        if owns() { webView.load(URLRequest(url: URL(string: "https://bank.yandex.ru/my/transactions-history")!)) }
    }

    /// Reads the balances on the page that is open now; true when one was found and saved. Each account keeps the time it was
    /// read itself: a reading of the card alone does not make an old balance of Save look fresh.
    private func readBalancesOnPage(_ owns: () -> Bool) async -> Bool {
        let script = """
        const labels = { card: /^карта(\\s+п[эе]й)?$/i, save: /^(сч[её]т\\s+в\\s+сейвах|сейвы?)$/i };
        // Any money label of the page: a block with two of them is shared, its sum may belong to the other one.
        const anyLabel = /^(карта(\\s+п[эе]й)?|сч[её]т\\s+в\\s+сейвах|сейвы?|сплит|баллы(\\s+плюса)?)$/i;
        const balance = /^\\d+([\\s\\u00a0\\u202f]\\d{3})*(,\\d{1,2})?\\s*₽$/;
        const leaves = [...document.querySelectorAll('body *')].filter(el => el.children.length === 0 && el.getClientRects().length > 0);
        const result = {};
        for (const [key, label] of Object.entries(labels)) {
            const sums = new Set();
            for (const el of leaves) {
                if (!label.test((el.textContent || '').trim())) continue;
                let box = el;
                for (let step = 0; step < 3 && box.parentElement; step++) {
                    box = box.parentElement;
                    const lines = (box.innerText || '').split('\\n').map(line => line.trim()).filter(Boolean);
                    if (lines.length > 4 || lines.filter(line => anyLabel.test(line)).length > 1) break;
                    // One sum without a sign in the label's own block. The sums of operations always have «−» or «+», so a row
                    // of the history never gives one; a signed line next to a balance (the interest of Save) does not matter.
                    const found = lines.filter(line => balance.test(line));
                    if (found.length === 1) { sums.add(found[0]); break; }
                }
            }
            if (sums.size === 1) result[key] = [...sums][0];
        }
        return result;
        """
        let answer = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard owns(), let found = answer as? [String: Any] else { return false }
        let card = (found["card"] as? String).flatMap(FinancialEngine.rublesKopecks)
        let save = (found["save"] as? String).flatMap(FinancialEngine.rublesKopecks)
        guard card != nil || save != nil else { return false }
        let now = Date()
        var reading = history.bankBalances ?? BankBalanceReading(readAt: now)
        if let card { reading.cardKopecks = card; reading.cardReadAt = now }
        if let save { reading.saveKopecks = save; reading.saveReadAt = now }
        reading.readAt = now
        let read = reading
        // Saved or not: a failed save is reported by `updateUserData` and is not taken for a reading.
        return updateUserData { $0.bankBalances = read }
    }

    /// An error next to the code field (not anywhere on the page: the word «ошибка» can be in any other text).
    private func codeRejected() async -> Bool {
        let script = Self.codeFieldsJS + """
        const area = codeArea(findCodeFields());
        if (!area) return false;
        return /неверн|ошибк|некоррект|истёк|истек|не подходит/i.test(area.innerText || '');
        """
        return (try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool) ?? false
    }

    /// Seconds until the bank lets ask for a new code (its «Запросить другой через N секунд»); with `request` and no wait left
    /// it taps the bank's button. The owner's tap in the window is what asks, never the app by itself.
    func resendCode(request: Bool) async -> Int {
        let script = Self.codeFieldsJS + """
        // The block of the code and a little around it (the bank's «Запросить другой» sits under the field).
        const area = codeArea(findCodeFields());
        if (!area) return 0;
        const text = area.innerText || '';
        const wait = text.match(/через\\s*(\\d+)\\s*(мин)?/i);
        const seconds = wait ? parseInt(wait[1], 10) * (wait[2] ? 60 : 1) : 0;
        if (!request || seconds > 0) return seconds;
        const button = [...area.querySelectorAll('button, a, [role="button"]')].find(node =>
            node.getClientRects().length > 0 && !node.disabled && node.getAttribute('aria-disabled') !== 'true' &&
            /запросить|отправить.*(ещё|еще|повторно|снова)|получить.*код|новый код/i.test((node.textContent || '').trim()));
        if (button) button.click();
        return 0;
        """
        let value = try? await webView.callAsyncJavaScript(script, arguments: ["request": request], in: nil, contentWorld: .defaultClient)
        return (value as? Int) ?? 0
    }

    enum BankPageState { case history, codeRequested, other }

    /// What the bank page shows: the signed-in history (its account filter is visible), a request for a
    /// confirmation code (a one-time-code field or "введите код" text, even on top of the history), or anything else.
    private func bankPageState() async -> BankPageState {
        guard webView.url != nil, !webView.isLoading else { return .other }
        let probe = """
        const visible = element => !!element && element.getClientRects().length > 0;
        const text = document.body?.innerText || '';
        const codeField = [...document.querySelectorAll('input')].some(input => visible(input) &&
            (input.autocomplete === 'one-time-code' || /код/i.test(input.placeholder || '') || /otp|sms|code/i.test(input.name || '')));
        if (codeField || /введите код|код из sms|код из смс|код подтверждения/i.test(text)) return 'code';
        if (location.hostname === 'bank.yandex.ru' && location.pathname === '/my/transactions-history' && text.includes('Все карты и счета')) return 'history';
        return 'other';
        """
        let value = try? await webView.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: .defaultClient)
        switch value as? String {
        case "history": return .history
        case "code": return .codeRequested
        default: return .other
        }
    }

    /// True when the bank's history page is loaded, signed in and not asking for a code.
    private func historyPageReady() async -> Bool { await bankPageState() == .history }

    /// Manual refresh: opens the history page when needed and, if the bank asks to sign in,
    /// says so and brings the bank page to the front instead of failing silently.
    func refreshNewOperations() {
        guard !busy, readable else { return }
        balanceReaderGeneration += 1
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
                    let state = await self.bankPageState()
                    if state == .codeRequested { break }
                    ready = state == .history
                }
            }
            self.busy = false
            if self.cancelled { self.message = "Обновление остановлено."; return }
            guard ready else {
                self.requestSignIn()
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
        picker.allowsMultipleSelection = true
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
        controller.dismiss(animated: true) { [weak self] in self?.importStatements(urls) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        message = "Импорт выписки отменён."
    }

    func importStatements(_ urls: [URL]) {
        guard !busy, readable, !urls.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let results = try StatementImporter.importPDFs(urls)
            statementPreview = try StatementImporter.preview(results, into: history)
            statementPreviewBase = try JSONEncoder().encode(history)
        } catch {
            message = "Не удалось импортировать выписки: \(error.localizedDescription)"
        }
    }

    func cancelStatementImport() {
        statementPreview = nil; statementPreviewBase = nil
        message = "Импорт выписок отменён."
    }

    func applyStatementImport() {
        guard !busy, readable, let preview = statementPreview, let base = statementPreviewBase else { return }
        settlePending()
        do {
            // A scan or another edit may finish while the confirmation is open.
            // Never overwrite changes made after the preview was prepared.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let old = try JSONDecoder().decode(SavedHistory.self, from: base)
            guard try encoder.encode(old) == encoder.encode(history) else {
                cancelStatementImport()
                message = "История изменилась после просмотра. Выберите выписки ещё раз."
                return
            }
            try vault.save(preview.history)
            history = preview.history
            message = preview.summary
            statementPreview = nil; statementPreviewBase = nil
        } catch {
            statementPreview = nil; statementPreviewBase = nil
            message = "Архив не сохранён: \(error.localizedDescription)"
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
        balanceReaderGeneration += 1
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
        settlePending()
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
        // The balances the page shows, for the reconciliation of the card and Save (46.29).
        if mode == "history" { Task { @MainActor [weak self] in await self?.readBankBalances() } }
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
            settlePending()
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
            var loaded = try vault.load()
            loaded.moveTransfersToOwnGroup()
            history = loaded
            loadingHistory = false
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

    /// Saves a change to user data (accounts, groups) into the encrypted history.
    @discardableResult
    func updateUserData(_ change: (inout SavedHistory) -> Void) -> Bool {
        guard readable else { message = "Хранилище недоступно, изменения не сохранены."; return false }
        var next = pendingHistory ?? history
        change(&next)
        do {
            try vault.save(next)
            pendingHistory = nil
            history = next
            return true
        } catch {
            message = "Не удалось сохранить: \(error.localizedDescription)"
            return false
        }
    }

    /// Like `updateUserData`, but the screens see the change a moment later. The file is written at once, so a failure is
    /// reported at once; the redraw of the whole app waits until the sheet that asked for the change has finished closing.
    @discardableResult
    func updateUserDataAfterClosing(_ change: @escaping (inout SavedHistory) -> Void) -> Bool {
        guard readable else { message = "Хранилище недоступно, изменения не сохранены."; return false }
        var next = pendingHistory ?? history
        change(&next)
        do {
            try vault.save(next)
        } catch {
            message = "Не удалось сохранить: \(error.localizedDescription)"
            return false
        }
        pendingHistory = next
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.settlePending()
        }
        return true
    }

    /// Puts the visible text of the open bank page on the clipboard (only on the user's tap, nothing is sent anywhere): it
    /// shows how the accounts and their balances are written there.
    func copyPageText() {
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''", in: nil, in: .defaultClient) { [weak self] result in
            var read: String?
            if case .success(let value) = result { read = value as? String }
            let page = read
            Task { @MainActor in
                guard let self else { return }
                if let text = page, !text.isEmpty {
                    UIPasteboard.general.string = text
                    self.pageTextNotice = "Скопировано: \(text.count) символов"
                } else {
                    self.pageTextNotice = "Не удалось прочитать страницу"
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.pageTextNotice = ""
            }
        }
    }

    func backupData() throws -> Data { try HistoryBackup.encode(pendingHistory ?? history) }

    /// Replaces the local history with a backup file chosen by the user.
    func restoreBackup(from url: URL) {
        guard !busy else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            var restored = try HistoryBackup.decode(Data(contentsOf: url))
            restored.moveTransfersToOwnGroup()
            try vault.save(restored)
            pendingHistory = nil
            history = restored
            loadingHistory = false
            readable = true
            storageError = nil
            storageRetryFailed = false
            message = "Восстановлено из копии: \(restored.operations.count) операций, счетов: \(restored.accounts?.count ?? 0)."
        } catch {
            message = "Не удалось восстановить копию: \(error.localizedDescription)"
        }
    }

    func resetLocalStorage() {
        guard !busy else { return }
        do {
            try vault.reset()
            pendingHistory = nil
            history = SavedHistory()
            loadingHistory = false
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
