import SwiftUI

/// Edits an operation of the bank (read from the bank page or from a statement): its title, amount, income or expense, day and
/// time. What the bank gave stays behind it: «Вернуть как в банке» takes the edit back, and every new read keeps it.
struct BankOperationEditView: View {
    @ObservedObject var browser: BankBrowser
    let operation: BankOperation
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amountText = ""
    @State private var isIncome = false
    @State private var date = Date()
    @State private var confirmDeletion = false
    @State private var error: String?
    @State private var loaded = false

    private var isEdited: Bool { browser.history.operationEdits?[operation.identity] != nil }
    private var parsedAmount: Int64? {
        guard let kopecks = ReceiptParser.kopecks(fromDecimal: amountText.filter { !$0.isWhitespace }), kopecks > 0 else { return nil }
        return kopecks
    }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedAmount != nil }

    var body: some View {
        Form {
            Section {
                TextField("Название", text: $title)
                Picker("Вид", selection: $isIncome) {
                    Text("Расход").tag(false)
                    Text("Доход").tag(true)
                }
                .pickerStyle(.segmented)
                TextField("Сумма, ₽", text: $amountText).keyboardType(.decimalPad)
                DatePicker("Дата и время", selection: $date)
            } footer: {
                Text("Правки видны только в Horizon: банк не меняется, а при каждом чтении банка и выписки они сохраняются.")
            }.glassRows()
            if isEdited {
                Section {
                    Button("Вернуть как в банке") { revert() }
                } footer: {
                    if let original = browser.history.operationEdits?[operation.identity]?.original {
                        Text("В банке: \(original.description), \(original.formattedAmount)")
                    }
                }.glassRows()
            }
            Section {
                Button("Удалить операцию", role: .destructive) { confirmDeletion = true }
            } footer: {
                Text("Операция пропадёт из истории и итогов; повторное чтение банка и выписки её не вернёт.")
            }.glassRows()
        }
        .appSurface()
        .navigationTitle("Изменить операцию")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Сохранить") { save() }.disabled(!canSave) }
        }
        .confirmationDialog("Удалить операцию из истории?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { remove() }
            Button("Отмена", role: .cancel) { }
        }
        .alert("Не удалось сохранить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            title = operation.description
            isIncome = operation.amountKopecks > 0
            amountText = (Decimal(abs(operation.amountKopecks)) / 100).description.replacingOccurrences(of: ".", with: ",")
            date = BankDateParser.parse(operation.occurredAt) ?? Date()
        }
    }

    private func save() {
        guard let amount = parsedAmount else { return }
        // A day and time left as they were keep the exact moment of the bank (the picker shows minutes only).
        let original = BankDateParser.parse(operation.occurredAt)
        let occurredAt = original.map { Calendar.current.isDate(date, equalTo: $0, toGranularity: .minute) } == true
            ? operation.occurredAt : ISO8601DateFormatter().string(from: date)
        let signed = isIncome ? amount : -amount
        let name = title
        let identity = operation.identity
        if browser.updateUserData({ $0.editBankOperation(identity: identity, amountKopecks: signed, occurredAt: occurredAt, description: name) }) {
            dismiss()
        } else {
            error = browser.message
        }
    }

    private func revert() {
        let identity = operation.identity
        if browser.updateUserData({ $0.revertBankOperationEdit(identity: identity) }) { dismiss() } else { error = browser.message }
    }

    private func remove() {
        let identity = operation.identity
        if browser.updateUserData({ $0.deleteBankOperation(identity: identity) }) { dismiss() } else { error = browser.message }
    }
}
