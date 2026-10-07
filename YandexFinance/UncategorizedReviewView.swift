import SwiftUI

struct UncategorizedReviewView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let groups: [ReviewGroup] = presentation.value("uncategorized") { UncategorizedReview.groups(browser.history) }
        let named = groups.filter { !$0.key.isEmpty }
        let unnamed = groups.filter { $0.key.isEmpty }
        List {
            if groups.isEmpty {
                ContentUnavailableView("Всё разобрано", systemImage: "checkmark.circle")
                    .listRowBackground(Color.clear)
            } else {
                if !named.isEmpty {
                    Section("Получатели") { rows(named) }.listRowBackground(GlassRowBackground())
                }
                if !unnamed.isEmpty {
                    Section("Без названия") { rows(unnamed) }.listRowBackground(GlassRowBackground())
                }
                Section {
                    Text("Осталось: \(groups.reduce(0) { $0 + $1.operations.count }) операций, \(money(groups.reduce(Decimal.zero) { $0 + $1.amountKopecks }))")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
            }
        }
        .appSurface()
        .navigationTitle("Разобрать операции")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rows(_ groups: [ReviewGroup]) -> some View {
        ForEach(groups) { group in
            NavigationLink {
                ReviewGroupOperationsView(browser: browser, presentation: presentation, groupID: group.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(group.title)
                        Spacer()
                        Text(money(group.amountKopecks)).monospacedDigit()
                    }
                    Text("\(group.kind == .expense ? "Расходы" : "Доходы") · \(group.operations.count) операций")
                        .font(.caption).foregroundStyle(.secondary)
                    if let date = group.latestDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func money(_ amount: Decimal) -> String { (amount / 100).formatted(.currency(code: "RUB")) }
}

private struct ReviewGroupOperationsView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    let groupID: String

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let groups: [ReviewGroup] = presentation.value("uncategorized") { UncategorizedReview.groups(browser.history) }
        List {
            if let group = groups.first(where: { $0.id == groupID }), let operation = group.operations.first {
                Section {
                    NavigationLink {
                        if group.kind == .expense {
                            OperationExpenseCategoryView(browser: browser, operation: operation, applyToAll: group.appliesToAll)
                        } else {
                            OperationIncomeCategoryView(browser: browser, operation: operation, applyToAll: group.appliesToAll)
                        }
                    } label: {
                        Text(group.appliesToAll ? "Выбрать категорию для всех" : "Выбрать категорию")
                    }
                }.listRowBackground(GlassRowBackground())
                Section(group.title) {
                    ForEach(group.operations.sorted {
                        (BankDateParser.parse($0.occurredAt) ?? .distantPast) > (BankDateParser.parse($1.occurredAt) ?? .distantPast)
                    }) { item in
                        NavigationLink {
                            OperationDetailView(browser: browser, operation: item)
                        } label: {
                            HStack {
                                if let date = BankDateParser.parse(item.occurredAt) {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                } else { Text(item.occurredAt) }
                                Spacer()
                                Text(item.formattedAmount)
                            }.font(.subheadline)
                        }
                    }
                }.listRowBackground(GlassRowBackground())
            } else {
                ContentUnavailableView("Всё разобрано", systemImage: "checkmark.circle")
                    .listRowBackground(Color.clear)
            }
        }
        .appSurface()
        .navigationTitle("Операции получателя")
        .navigationBarTitleDisplayMode(.inline)
    }
}
