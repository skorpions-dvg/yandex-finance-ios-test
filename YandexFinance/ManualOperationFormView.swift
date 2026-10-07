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
        kind == .transfer ? accounts : accounts.filter { !$0.tracksBankCard }
    }

    private var parsedAmount: Int64? {
        let text = amountText.filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        guard text.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let kopecks = amount * 100
        guard kopecks > 0, kopecks <= Decimal(Int64.max) else { return nil }
        return NSDecimalNumber(decimal: kopecks).int64Value
    }

    private var canSave: Bool {
        guard parsedAmount != nil, date <= Date(),
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
                    fields
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
            .navigationTitle(operation == nil ? "Добавить" : "Операция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена", systemImage: "xmark") { dismiss() }
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
                            Label(name, systemImage: style.icon).foregroundStyle(style.color)
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
                    Text("Дата и время")
                    Spacer()
                    Button(date.formatted(date: .abbreviated, time: .omitted)) { openDateTime(time: false) }
                        .buttonStyle(.borderless)
                    Button(date.formatted(date: .omitted, time: .shortened)) { openDateTime(time: true) }
                        .buttonStyle(.borderless)
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
        default: return ("square.grid.2x2.fill", .gray)
        }
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
        let success = browser.updateUserData { history in
            var operations = history.manualOperations ?? []
            if let index = operations.firstIndex(where: { $0.id == operationToSave.id }) { operations[index] = operationToSave }
            else { operations.append(operationToSave) }
            history.manualOperations = operations
        }
        if success {
            saved = true
            onSave?(operationToSave)
            dismiss()
        } else {
            saveErrorMessage = browser.message
            saveError = true
        }
    }

    private func delete() {
        guard let operation else { return }
        if browser.updateUserData({ history in history.manualOperations?.removeAll { $0.id == operation.id } }) {
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
