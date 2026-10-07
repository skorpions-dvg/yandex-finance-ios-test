import SwiftUI

/// Report-only exclusions. The toggles never change operations or their categories.
struct ReportFilterSheet: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    let interval: DateInterval
    let mode: ReportMode
    @Binding var filter: ReportFilter
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    static func groups(browser: BankBrowser, presentation: FinancePresentationCache,
                       interval: DateInterval, mode: ReportMode) -> [String] {
        if mode == .expenses {
            let names = browser.history.expenseTaxonomy.groupNames
            return names.contains("Переводы") ? names : names + ["Переводы"]
        }
        let slices: [ReportSlice] = presentation.value("filter-groups:\(interval.start):\(interval.end):\(ReportFilter.none.cacheKey)") {
            ReportEngine.slices(presentation.inputs(browser.history), in: interval, mode: .income,
                                grouping: .categories, taxonomy: browser.history.expenseTaxonomy, filter: .none)
        }
        return slices.map(\.title)
    }

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let groups = Self.groups(browser: browser, presentation: presentation, interval: interval, mode: mode)
        let payees: [ReportSlice] = presentation.value("filter-payees:\(mode.rawValue):\(interval.start):\(interval.end):\(ReportFilter.none.cacheKey)") {
            ReportEngine.slices(presentation.inputs(browser.history), in: interval, mode: mode,
                                grouping: .payees, taxonomy: browser.history.expenseTaxonomy, filter: .none)
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownPayees = Array(payees.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.prefix(50))
        NavigationStack {
            List {
                Section("Категории") {
                    ForEach(groups, id: \.self) { group in
                        Toggle(group, isOn: includedGroup(group))
                    }
                }.glassRows()
                Section("Получатели") {
                    TextField("Поиск получателя", text: $search)
                        .autocorrectionDisabled()
                    ForEach(shownPayees) { slice in
                        Toggle(isOn: includedPayee(slice.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slice.title).lineLimit(2)
                                Text((Decimal(slice.amountKopecks) / 100).formatted(.currency(code: "RUB")))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    if shownPayees.isEmpty {
                        Text(query.isEmpty ? "За выбранный период получателей нет" : "Получатель не найден")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }.glassRows()
            }
            .appSurface()
            .navigationTitle("Фильтр · \(mode.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Сбросить") { filter = .none } }
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func includedGroup(_ group: String) -> Binding<Bool> {
        Binding(get: { !filter.excludedGroups.contains(group) }, set: { included in
            if included { filter.excludedGroups.remove(group) }
            else { filter.excludedGroups.insert(group) }
        })
    }

    private func includedPayee(_ key: String) -> Binding<Bool> {
        Binding(get: { !filter.excludedPayees.contains(key) }, set: { included in
            if included { filter.excludedPayees.remove(key) }
            else { filter.excludedPayees.insert(key) }
        })
    }
}
