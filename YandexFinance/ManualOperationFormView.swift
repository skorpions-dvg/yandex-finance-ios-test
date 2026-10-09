import SwiftUI

struct ManualOperationFormView: View {
    @ObservedObject var browser: BankBrowser
    @Environment(\.dismiss) private var dismiss
    private let operation: ManualOperation?
    private let onSave: ((ManualOperation) -> Void)?
    @State private var operationID: UUID
    @FocusState private var fieldFocused: Bool
    @State private var kind: ManualOperation.Kind
    @State private var amountText: String
    @State private var accountID: UUID?
    @State private var toAccountID: UUID?
    @State private var group: String?
    @State private var subcategory: String?
    @State private var date: Date
    @State private var note: String
    @State private var confirmDeletion = false
    @State private var saveError = false
    @State private var saveErrorMessage = ""
    @State private var saved = false
    /// Photos of a receipt added to an operation that is not saved yet; they are attached when it is saved.
    @State private var pendingReceipts: [String] = []
    /// What the reading of a receipt did, shown above the fields; `recognizing` while it is being read.
    @State private var recognition: String?
    /// The goods read from the receipt, one per line; the owner corrects them, they are saved in the comment.
    @State private var itemsText = ""
    /// The reading found neither a sum nor a date: the owner is told so in red.
    @State private var recognitionFailed = false
    @State private var itemsExpanded = false
    /// What the phone read from the receipt of this form: kept with the operation when it is saved.
    @State private var lastScan: ReceiptScan?
    /// The date the form had when a receipt was read without a date on it: while it stays, the owner has not given the date
    /// of the receipt and the operation cannot be saved.
    @State private var dateConfirmBase: Date?
    @State private var recognizing = false
    /// Each reading has a number: a result that comes after the form was closed, or after a newer reading, is dropped.
    @State private var recognitionGeneration = 0
    /// The goods as the last accepted reading set them: a list that differs from it was edited by the owner and is not replaced.
    @State private var itemsSetByScan = ""
    /// How much the best reading of this form gave; a later photo replaces the goods and the scan only if it gives more.
    @State private var scanScore = -1
    /// The time was read from printed text, not from the QR code: it may be misread, the owner is asked to check it.
    @State private var timeCheckBase: Date?
    @State private var showDateTime = false
    @State private var selectsTime = false

    init(browser: BankBrowser, operation: ManualOperation? = nil,
         onSave: ((ManualOperation) -> Void)? = nil) {
        self.browser = browser
        self.operation = operation
        self.onSave = onSave
        _operationID = State(initialValue: operation?.id ?? UUID())
        _kind = State(initialValue: operation?.kind ?? .expense)
        _amountText = State(initialValue: operation.map {
            (Decimal($0.amountKopecks) / 100).description.replacingOccurrences(of: ".", with: ",")
        } ?? "")
        _accountID = State(initialValue: operation?.accountID)
        _toAccountID = State(initialValue: operation?.toAccountID)
        _group = State(initialValue: operation?.group)
        _subcategory = State(initialValue: operation?.subcategory)
        _date = State(initialValue: operation?.date ?? Date())
        _note = State(initialValue: operation?.note ?? "")
    }

    private var accounts: [Account] { browser.history.accounts ?? [] }
    private var eligibleAccounts: [Account] {
        kind == .transfer ? accounts : accounts.filter { !$0.followsBank }
    }

    private var parsedAmount: Int64? {
        let text = amountText.filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        guard text.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let kopecks = amount * 100
        guard kopecks > 0, kopecks <= Decimal(Int64.max) else { return nil }
        return NSDecimalNumber(decimal: kopecks).int64Value
    }

    /// The bank purchases this receipt may already be (46.40, `ReceiptBankMatch`): a receipt saved as its own operation would
    /// count the purchase twice (8 Oct: the same shop, 1 656,87 ₽, in the bank and by hand). Only for a new expense with a photo.
    private var bankTwins: [BankOperation] {
        guard operation == nil, kind == .expense, !pendingReceipts.isEmpty, !recognizing, !dateIsPending,
              let amount = parsedAmount else { return [] }
        let bank = browser.history.operations
        let candidates = bank.map { ReceiptMatchCandidate(identity: $0.identity, input: $0.financialInput) }
        let identities: [String]
        switch ReceiptBankMatch.match(totalKopecks: amount, date: date, hasTime: lastScan?.dateHasTime == true, candidates: candidates) {
        case .confirmed(let identity, _): identities = [identity]
        case .ambiguous(let list): identities = list
        case .none: return []
        }
        return identities.compactMap { identity in bank.first { $0.identity == identity } }
    }

    /// A receipt was read but its date was not: the date must be set by hand (or confirmed as it is).
    private var dateIsPending: Bool { dateConfirmBase.map { $0 == date } ?? false }
    private var timeNeedsCheck: Bool { timeCheckBase.map { $0 == date } ?? false }

    private var canSave: Bool {
        guard parsedAmount != nil, date <= Date(), !dateIsPending, !recognizing,
              eligibleAccounts.contains(where: { $0.id == accountID }) else { return false }
        switch kind {
        case .expense:
            guard let group, let subcategory else { return false }
            return browser.history.categoryTree.contains { $0.name == group && $0.categories.contains { $0.name == subcategory } }
        case .income:
            return subcategory.map { FinancialEngine.incomeSubcategoryOrder.contains($0) } ?? false
        case .transfer:
            return toAccountID != accountID && accounts.contains { $0.id == toAccountID }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if accounts.isEmpty {
                    ContentUnavailableView("Счетов пока нет", systemImage: "wallet.pass",
                                           description: Text("Добавьте счёт на главном экране в разделе «Все счета»."))
                } else {
                    if operation == nil {
                        // A new operation starts with the receipt: scan it and the fields below are filled in.
                        ReceiptSection(browser: browser, identity: ManualOperation.identityPrefix + operationID.uuidString,
                                       pending: $pendingReceipts, onAdded: recognize)
                        if recognizing || recognition != nil {
                            Section {
                                HStack(spacing: 10) {
                                    if recognizing { ProgressView() }
                                    else if recognitionFailed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                                    Text(recognizing ? "Читаю чек…" : (recognition ?? "")).font(.footnote)
                                        .foregroundStyle(recognitionFailed ? Color.red : Color.primary)
                                }
                                if !recognizing && !recognitionFailed {
                                    let goods = itemsText.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                                    DisclosureGroup(isExpanded: $itemsExpanded) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            TextEditor(text: $itemsText)
                                                .font(.caption)
                                                .frame(height: min(380, max(140, CGFloat(goods) * 28 + 16)))
                                                .scrollContentBackground(.hidden)
                                                .padding(6)
                                                .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 10))
                                                                                        if let check = ReceiptParser.goodsSumNote(itemsText.split(separator: "\n").map { ReceiptGood(line: String($0)) },
                                                                                      expectedKopecks: parsedAmount) {
                                                Text(check.text).font(.caption).foregroundStyle(check.adds ? Color.green : Color.orange)
                                            }
                                            Text("Одно название на строку, цена после « — »; исправьте или удалите лишнее. Товары сохраняются в операции, в блоке «Товары» под чеком.")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    } label: {
                                        Text(goods == 0 ? "Товары не найдены" : "Товары: \(goods) (проверьте)").font(.footnote)
                                    }
                                }
                            }.glassRows()
                        }
                    }
                    let twins = bankTwins
                    if !twins.isEmpty {
                        Section {
                            ForEach(twins, id: \.identity) { twin in
                                Button { attach(to: twin) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(twin.description).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text(balanceText(-twin.amountKopecks) + " · "
                                             + (BankDateParser.parse(twin.occurredAt)?.formatted(date: .abbreviated, time: .shortened) ?? twin.occurredAt))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text("Прикрепить чек к этой покупке").font(.caption.weight(.semibold))
                                    }
                                }
                                .disabled(saved)
                            }
                        } header: {
                            Label(twins.count == 1 ? "Эта покупка уже есть в банке" : "Похожие покупки в банке", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } footer: {
                            Text("Если сохранить чек отдельной операцией, покупка посчитается дважды. Прикрепите чек к покупке банка: фото и товары перейдут к ней.")
                        }.glassRows()
                    }
                    fields
                    if operation != nil {
                        ReceiptSection(browser: browser, identity: ManualOperation.identityPrefix + operationID.uuidString)
                        ReceiptGoodsSection(browser: browser, identity: ManualOperation.identityPrefix + operationID.uuidString)
                    }
                }
                if operation != nil {
                    Section {
                        Button("Удалить операцию", role: .destructive) { confirmDeletion = true }
                    }.glassRows()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .tint(.accentColor)
            .appSurface()
            .interactiveDismissDisabled(!pendingReceipts.isEmpty && !saved)
            .navigationTitle(operation == nil ? "Добавить" : "Операция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена", systemImage: "xmark") {
                        recognitionGeneration += 1
                        ReceiptStore.delete(pendingReceipts)
                        pendingReceipts = []
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить", systemImage: "checkmark", action: save)
                        .tint(.accentColor).disabled(!canSave || saved)
                }
            }
        }
        .onChange(of: kind) { _, _ in
            group = nil
            subcategory = nil
            if !eligibleAccounts.contains(where: { $0.id == accountID }) { accountID = nil }
            toAccountID = nil
        }
        .onChange(of: accountID) { _, value in
            if toAccountID == value { toAccountID = nil }
        }
        .sheet(isPresented: $showDateTime) {
            ManualOperationDateTimeView(date: $date, startsWithTime: selectsTime)
        }
        .confirmationDialog("Удалить операцию?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Удалить операцию", role: .destructive, action: delete)
            Button("Отмена", role: .cancel) { }
        }
        .alert("Не удалось сохранить", isPresented: $saveError) {
            Button("OK", role: .cancel) { }
        } message: { Text(saveErrorMessage) }
    }

    private var fields: some View {
        Group {
            Section {
                Picker("Тип операции", selection: $kind) {
                    Text("Расход").tag(ManualOperation.Kind.expense)
                    Text("Доход").tag(ManualOperation.Kind.income)
                    Text("Перевод").tag(ManualOperation.Kind.transfer)
                }
                .pickerStyle(.segmented)
                TextField("Сумма, ₽", text: $amountText)
                    .focused($fieldFocused)
                    .font(.title.weight(.semibold))
                    .keyboardType(.decimalPad)
                    .foregroundStyle(kind == .income ? Color.green : Color.primary)
            }.glassRows()
            if kind == .expense {
                Section("Категория") {
                    if let group, let subcategory {
                        Text("\(group) → \(subcategory)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(browser.history.categoryTree) { categoryGroup in
                        let name = categoryGroup.name
                        DisclosureGroup {
                            ForEach(subcategories(for: name), id: \.self) { category in
                                Button {
                                    group = name
                                    subcategory = category
                                } label: {
                                    HStack {
                                        Text(category).foregroundStyle(.primary)
                                        Spacer()
                                        if group == name && subcategory == category {
                                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                            }
                        } label: {
                            let style = groupStyle(name)
                            HStack {
                                Label(name, systemImage: style.icon).foregroundStyle(style.color)
                                Spacer()
                                if group == name, let subcategory {
                                    Text(subcategory).font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }.glassRows()
            } else if kind == .income {
                Section {
                    Picker("Категория", selection: $subcategory) {
                        Text("Выберите категорию").tag(nil as String?)
                        ForEach(FinancialEngine.incomeSubcategoryOrder, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                }.glassRows()
            }
            Section {
                if eligibleAccounts.isEmpty {
                    Text("Нет счетов для ручных операций").foregroundStyle(.secondary)
                    Text("В разделе «Все счета» добавьте отдельный счёт, например «Наличные», без отметки «Карта Яндекс Банка».")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    let balances = accountBalances
                    accountPicker(kind == .transfer ? "Откуда" : "Счёт", selection: $accountID, choices: eligibleAccounts, balances: balances)
                    if kind == .transfer {
                        accountPicker("Куда", selection: $toAccountID, choices: accounts.filter { $0.id != accountID }, balances: balances)
                    }
                }
            } footer: {
                if kind != .transfer {
                    Text("Операции по карте Яндекс Банка загружаются из банка автоматически")
                }
            }.glassRows()
            Section {
                HStack {
                    Text("Дата и время").foregroundStyle(dateIsPending ? Color.red : Color.primary)
                    Spacer()
                    Button(date.formatted(date: .abbreviated, time: .omitted)) { openDateTime(time: false) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(dateIsPending ? Color.red : Color.accentColor)
                    Button(date.formatted(date: .omitted, time: .shortened)) { openDateTime(time: true) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(dateIsPending ? Color.red : Color.accentColor)
                }
                if dateIsPending {
                    Text("Дату или время чека не удалось прочитать: укажите их. Пока они не указаны, сохранить нельзя.")
                        .font(.footnote).foregroundStyle(.red)
                    Button("Дата и время верны") { dateConfirmBase = nil }
                        .font(.footnote)
                } else if timeNeedsCheck {
                    Text("Время взято из печатного текста чека, где цифра могла прочитаться неверно: сверьте с чеком.")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("Время верно") { timeCheckBase = nil }
                        .font(.footnote)
                }
                TextField("Комментарий", text: $note).focused($fieldFocused)
            } footer: {
                if let account = accounts.first(where: { $0.id == accountID }), date < account.startDate {
                    Text("Операция до начального остатка сохранится в истории и отчётах, но не изменит остаток счёта.")
                }
            }.glassRows()
        }
    }

    private func openDateTime(time: Bool) {
        fieldFocused = false
        selectsTime = time
        showDateTime = true
    }

    /// Current balance of every account, the same way the accounts screen counts it.
    private var accountBalances: [UUID: Int64] {
        let bank = browser.history.operations.map(\.financialInput)
        let manual = browser.history.manualOperations ?? []
        return Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.balance(bankOperations: bank, manual: manual)) })
    }

    private func balanceText(_ kopecks: Int64?) -> String {
        guard let kopecks else { return "" }
        return (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }

    private func accountPicker(_ title: String, selection: Binding<UUID?>, choices: [Account], balances: [UUID: Int64]) -> some View {
        // The balance is part of each choice, so it shows both in the list and next to «Откуда»/«Куда».
        Picker(title, selection: selection) {
            Text("Выберите счёт").tag(nil as UUID?)
            ForEach(choices) { account in
                Label("\(account.name) — \(balanceText(balances[account.id]))", systemImage: account.icon)
                    .foregroundStyle(accountColor(account.color)).tag(Optional(account.id))
            }
        }
    }

    private func subcategories(for group: String) -> [String] {
        browser.history.categoryTree.first { $0.name == group }?.categories.map(\.name) ?? []
    }

    private func groupStyle(_ group: String) -> (icon: String, color: Color) {
        switch group {
        case "Еда": return ("fork.knife", .orange)
        case "Транспорт": return ("car.fill", .blue)
        case "Покупки": return ("bag.fill", .purple)
        case "Обязательные": return ("house.fill", .teal)
        case "Переводы": return ("person.2.fill", .indigo)
        default: return ("square.grid.2x2.fill", .gray)
        }
    }

    /// Reads the pictures of a receipt and fills the empty fields of the form; the user checks them and saves.
    private func recognize(_ images: [UIImage]) {
        recognizing = true
        recognition = nil
        recognitionGeneration += 1
        let generation = recognitionGeneration
        let dateAtStart = date
        Task {
            let parsed = await ReceiptRecognizer.recognize(images)
            // The form was closed or a newer reading began: an old result must not win over it or over the owner's corrections.
            guard generation == recognitionGeneration else { return }
            apply(parsed, dateAtStart: dateAtStart)
            recognizing = false
        }
    }

    /// `dateAtStart`: the date of the form when the reading began; a date the user changed meanwhile is not overwritten.
    private func apply(_ parsed: ParsedReceipt, dateAtStart: Date) {
        // How much this reading gave. A later photo of the same receipt replaces the scan, the goods and the date only if it gives more.
        let adds = ReceiptParser.goodsSumNote(parsed.goods, expectedKopecks: parsed.totalKopecks)?.adds == true
        let score = (parsed.totalKopecks != nil ? 3 : 0) + (parsed.date != nil ? (parsed.dateHasTime ? 3 : 1) : 0)
            + min(parsed.goods.filter { $0.kopecks != nil }.count, 6) + (adds ? 10 : 0)
        let isBetter = score > scanScore
        if isBetter {
            scanScore = score
            lastScan = ReceiptScan(scannedAt: Date(), readLines: parsed.readLines, totalKopecks: parsed.totalKopecks, date: parsed.date,
                                   merchant: parsed.merchant, goods: parsed.goods, dateHasTime: parsed.dateHasTime)
        }
        // Neither a sum nor a date: nothing useful was read, and the owner is told so instead of getting a guessed form.
        if parsed.totalKopecks == nil && parsed.date == nil {
            if scanScore > 0 {
                recognition = "Эта фото не прочиталась, остаётся прежнее чтение."
            } else {
                recognitionFailed = true
                dateConfirmBase = nil
                recognition = "Не удалось прочитать чек. Сфотографируйте ровнее и при хорошем свете или введите данные вручную. Фото останется приложенным."
            }
            return
        }
        recognitionFailed = false
        if isBetter, !parsed.goods.isEmpty, itemsText.isEmpty || itemsText == itemsSetByScan {
            itemsSetByScan = parsed.goods.map(\.line).joined(separator: "\n")
            itemsText = itemsSetByScan
        }
        var filled: [String] = []
        if kind == .expense {
            if let total = parsed.totalKopecks, amountText.filter({ !$0.isWhitespace }).isEmpty {
                amountText = (Decimal(total) / 100).description.replacingOccurrences(of: ".", with: ",")
                filled.append("сумма")
            }
            if let merchant = parsed.merchant {
                if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    note = merchant
                    filled.append("магазин")
                }
            }
            // The category: by the shop (the rule of the owner, the latest purchase there, the words of its name) and, if
            // that tells nothing, by the words of the goods.
            if group == nil, let guess = browser.history.suggestedExpenseCategory(forMerchant: parsed.merchant ?? "",
                                                                                  text: parsed.goods.map(\.name).joined(separator: " ")) {
                group = guess.group
                subcategory = guess.subcategory
                filled.append("категория")
            }
            if accountID == nil, let id = browser.history.lastManualAccountID, eligibleAccounts.contains(where: { $0.id == id }) {
                accountID = id
                filled.append("счёт")
            }
        }
        if isBetter {
            dateConfirmBase = nil
            timeCheckBase = nil
            if let when = parsed.date, when <= Date(), date == dateAtStart {
                date = when
                filled.append("дата")
                if !parsed.dateHasTime { dateConfirmBase = date }
                else if !parsed.dateFromQR { timeCheckBase = date }
            } else if date == dateAtStart, parsed.date.map({ $0 > Date() }) ?? true {
                // The date of the receipt was not read, or it was read as a day to come (a misread year): the form keeps today's date,
                // but it is not accepted until it is set.
                dateConfirmBase = date
            }
        }
        var message = filled.isEmpty ? "Ничего нового не нашлось." : "Заполнено: " + filled.joined(separator: ", ") + ". Проверьте и сохраните."
        if parsed.totalKopecks == nil { message += " Сумму не удалось прочитать: введите её вручную." }
        if parsed.date == nil { message += " Дату чека не удалось прочитать: укажите её." }
        else if parsed.date.map({ $0 > Date() }) == true { message += " Дата чека прочиталась как будущая: укажите её." }
        else if !parsed.dateHasTime { message += " Время чека не прочиталось: укажите его." }
        recognition = message
    }

    private func save() {
        guard !saved else { return }
        fieldFocused = false
        guard canSave, let amount = parsedAmount else {
            saveErrorMessage = "Проверьте сумму, категорию, счёт и дату операции."
            saveError = true
            return
        }
        let operationToSave = ManualOperation(id: operationID, kind: kind, amountKopecks: amount,
                                    date: date, accountID: accountID,
                                    toAccountID: kind == .transfer ? toAccountID : nil,
                                    group: kind == .expense ? group : nil,
                                    subcategory: kind == .transfer ? nil : subcategory, note: note)
        let photos = pendingReceipts
        let goods = itemsText.split(separator: "\n").map { ReceiptGood(line: String($0)) }.filter { !$0.name.isEmpty }
        let scan = lastScan
        let isNew = operation == nil
        let identity = ManualOperation.identityPrefix + operationToSave.id.uuidString
        let success = browser.updateUserData { history in
            var operations = history.manualOperations ?? []
            if let index = operations.firstIndex(where: { $0.id == operationToSave.id }) { operations[index] = operationToSave }
            else { operations.append(operationToSave) }
            history.manualOperations = operations
            for name in photos { history.addReceipt(name, toIdentity: identity) }
            // Only a new operation takes its goods from this form; for an existing one they are edited under the receipt.
            if isNew {
                history.setReceiptGoods(goods, forIdentity: identity)
                if let scan, !photos.isEmpty { history.setReceiptScan(scan, forIdentity: identity) }
            }
        }
        if success {
            pendingReceipts = []
            saved = true
            onSave?(operationToSave)
            dismiss()
        } else {
            saveErrorMessage = browser.message
            saveError = true
        }
    }

    /// The receipt goes to the bank purchase instead of a new operation: its photos, and the goods and the reading when that
    /// purchase has none yet. Nothing is added by hand, so the purchase counts once.
    private func attach(to twin: BankOperation) {
        guard !saved else { return }
        fieldFocused = false
        let photos = pendingReceipts
        let goods = itemsText.split(separator: "\n").map { ReceiptGood(line: String($0)) }.filter { !$0.name.isEmpty }
        let scan = lastScan
        let identity = twin.identity
        let success = browser.updateUserData { history in
            for name in photos { history.addReceipt(name, toIdentity: identity) }
            if history.receiptGoods(forIdentity: identity).isEmpty, !goods.isEmpty { history.setReceiptGoods(goods, forIdentity: identity) }
            if let scan, history.receiptScans?[identity] == nil { history.setReceiptScan(scan, forIdentity: identity) }
        }
        if success {
            pendingReceipts = []
            saved = true
            dismiss()
        } else {
            saveErrorMessage = browser.message
            saveError = true
        }
    }

    private func delete() {
        guard let operation else { return }
        var photos: [String] = []
        let identity = ManualOperation.identityPrefix + operation.id.uuidString
        // Saved at once (a failure is told at once), shown to the screens after the sheet has closed: counting the forecast and the
        // reports again takes about a second, and the sheet used to wait for it.
        if browser.updateUserDataAfterClosing({ history in
            history.manualOperations?.removeAll { $0.id == operation.id }
            photos = history.removeReceipts(forIdentity: identity)
        }) {
            ReceiptStore.delete(photos)
            dismiss()
        } else {
            saveErrorMessage = browser.message
            saveError = true
        }
    }
}

/// A separate sheet keeps the calendar from intercepting the operation's Save button.
private struct ManualOperationDateTimeView: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Date
    @State private var selectsTime: Bool

    init(date: Binding<Date>, startsWithTime: Bool) {
        _date = date
        _draft = State(initialValue: date.wrappedValue)
        _selectsTime = State(initialValue: startsWithTime)
    }

    var body: some View {
        NavigationStack {
            VStack {
                if selectsTime {
                    Text(draft.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    DatePicker("Время", selection: $draft, in: ...Date(), displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden()
                } else {
                    DatePicker("Дата", selection: $draft, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .onChange(of: draft) { _, _ in selectsTime = true }
                }
            }
            .padding()
            .tint(.accentColor)
            .appSurface()
            .navigationTitle(selectsTime ? "Время" : "Дата")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectsTime {
                        Button("Дата", systemImage: "chevron.left") { selectsTime = false }
                    } else {
                        Button("Отмена", systemImage: "xmark") { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectsTime ? "Готово" : "Время", systemImage: "checkmark") {
                        if selectsTime {
                            date = min(draft, Date())
                            dismiss()
                        } else { selectsTime = true }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
