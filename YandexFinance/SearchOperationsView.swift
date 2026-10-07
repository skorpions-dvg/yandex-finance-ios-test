import SwiftUI

/// "Поиск операций": every word of the query must match the title, category, purpose, MCC, type or the amount.
struct SearchOperationsView: View {
    @ObservedObject var browser: BankBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editedOperation: ManualOperation?

    /// Matching operations, newest first.
    private var results: [BankOperation] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return zip(browser.history.allOperations, browser.history.financialInputs)
            .filter { FinancialEngine.operationMatches($0.1, query: text) }
            .map { $0.0 }
            .map { ($0, BankDateParser.parse($0.occurredAt) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("Используйте любые атрибуты", systemImage: "magnifyingglass",
                                           description: Text("Название, категория, назначение или сумма: «пятёрочка», «такси», «1555»."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    let found = results
                    Section("Найдено: \(found.count)") {
                        ForEach(found.prefix(300)) { operation in
                            if operation.isManual {
                                Button {
                                    editedOperation = browser.history.manualOperations?.first { $0.id == operation.manualID }
                                } label: {
                                    OperationRow(operation: operation, input: browser.history.financialInput(for: operation), showsDate: true).foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    OperationDetailView(browser: browser, operation: operation)
                                } label: {
                                    OperationRow(operation: operation, input: browser.history.financialInput(for: operation), showsDate: true)
                                }
                            }
                        }
                    }.glassRows()
                }
            }
            .sheet(item: $editedOperation) { operation in
                ManualOperationFormView(browser: browser, operation: operation)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск")
            .appSurface()
            .navigationTitle("Поиск операций")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
    }
}
