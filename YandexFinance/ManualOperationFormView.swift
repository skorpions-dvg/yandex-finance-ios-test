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
            return subcategories(for: group).contains(subcategory)
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
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .tint(.orange)
            .navigationTitle(operation == nil ? "Добавить" : "Операция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить", systemImage: "checkmark", action: save)
                        .tint(.orange).disabled(!canSave || saved)
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
            }
            if kind == .expense {
                Section("Категория") {
                    if let group, let subcategory {
                        Text("\(group) → \(subcategory)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(FinancialEngine.expenseGroupOrder, id: \.self) { name in
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
                                            Image(systemName: "checkmark").foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                        } label: {
                            let style = groupStyle(name)
                            Label(name, systemImage: style.icon).foregroundStyle(style.color)
                        }
                    }
                }
            } else if kind == .income {
                Section {
                    Picker("Категория", selection: $subcategory) {
                        Text("Выберите категорию").tag(nil as String?)
                        ForEach(FinancialEngine.incomeSubcategoryOrder, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                }
            }
            Section {
                if eligibleAccounts.isEmpty {
                    Text("Нет счетов для ручных операций").foregroundStyle(.secondary)
                    Text("В разделе «Все счета» добавьте отдельный счёт, например «Наличные», без отметки «Карта Яндекс Банка».")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    accountPicker(kind == .transfer ? "Откуда" : "Счёт", selection: $accountID, choices: eligibleAccounts)
                    if kind == .transfer {
                        accountPicker("Куда", selection: $toAccountID, choices: accounts.filter { $0.id != accountID })
                    }
                }
            } footer: {
                if kind != .transfer {
                    Text("Операции по карте Яндекс Банка загружаются из банка автоматически")
                }
            }
            Section {
                DatePicker("Дата и время", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                TextField("Комментарий", text: $note).focused($fieldFocused)
            }
        }
    }

    private func accountPicker(_ title: String, selection: Binding<UUID?>, choices: [Account]) -> some View {
        Picker(title, selection: selection) {
            Text("Выберите счёт").tag(nil as UUID?)
            ForEach(choices) { account in
                Label(account.name, systemImage: account.icon)
                    .foregroundStyle(accountColor(account.color)).tag(Optional(account.id))
            }
        }
    }

    private func subcategories(for group: String) -> [String] {
        let categories: [String]
        switch group {
        case "Еда": categories = ["Супермаркеты", "Кафе и рестораны", "Доставка еды"]
        case "Транспорт": categories = ["Такси", "Общественный транспорт", "Топливо", "Авто"]
        case "Покупки": categories = ["Маркетплейсы", "Одежда", "Электроника", "Дом и быт"]
        case "Обязательные": categories = ["ЖКХ", "Связь и интернет", "Подписки", "Здоровье"]
        default: categories = ["Развлечения", "Путешествия", "Подарки", "Доставка и курьеры", "Переводы другим", "Комиссии", "Прочее"]
        }
        return FinancialEngine.expenseSubcategoryOrder.filter { categories.contains($0) }
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
