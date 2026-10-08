import SwiftUI

/// Report-only exclusions. The toggles never change operations or their categories.
struct ReportFilterSheet: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    let interval: DateInterval
    let mode: ReportMode
    /// «Income and expenses» has no switch between the two, so its filter offers the categories and payees of both.
    var bothModes = false
    /// The accounts the report is about: the offered payees and income categories are theirs.
    var scope: ReportAccountScope = .all
    @Binding var filter: ReportFilter
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    static func groups(browser: BankBrowser, presentation: FinancePresentationCache,
                       interval: DateInterval, mode: ReportMode, scope: ReportAccountScope = .all) -> [String] {
        if mode == .expenses {
            let names = browser.history.expenseTaxonomy.groupNames
            return names.contains("Переводы") ? names : names + ["Переводы"]
        }
        let scoped = ReportFilter(scope: scope)
        let slices: [ReportSlice] = presentation.value("filter-groups:\(interval.start):\(interval.end):\(scoped.cacheKey)") {
            ReportEngine.slices(presentation.inputs(browser.history, scope: scope), in: interval, mode: .income,
                                grouping: .categories, taxonomy: browser.history.expenseTaxonomy, filter: scoped)
        }
        return slices.map(\.title)
    }

    private func payees(_ mode: ReportMode) -> [ReportSlice] {
        let scoped = ReportFilter(scope: scope)
        return presentation.value("filter-payees:\(mode.rawValue):\(interval.start):\(interval.end):\(scoped.cacheKey)") {
            ReportEngine.slices(presentation.inputs(browser.history, scope: scope), in: interval, mode: mode,
                                grouping: .payees, taxonomy: browser.history.expenseTaxonomy, filter: scoped)
        }
    }

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let allPayees: [ReportSlice] = {
            guard bothModes else { return payees(mode) }
            var seen = Set<String>()
            return (payees(.expenses) + payees(.income)).sorted { $0.amountKopecks > $1.amountKopecks }.filter { seen.insert($0.id).inserted }
        }()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownPayees = Array(allPayees.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.prefix(50))
        NavigationStack {
            List {
                if bothModes {
                    groupsSection("Категории расходов", Self.groups(browser: browser, presentation: presentation, interval: interval, mode: .expenses, scope: scope))
                    groupsSection("Категории доходов", Self.groups(browser: browser, presentation: presentation, interval: interval, mode: .income, scope: scope))
                } else {
                    groupsSection("Категории", Self.groups(browser: browser, presentation: presentation, interval: interval, mode: mode, scope: scope))
                }
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
            .navigationTitle(bothModes ? "Фильтр" : "Фильтр · \(mode.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Сбросить") { filter.excludedGroups = []; filter.excludedPayees = [] } }
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func groupsSection(_ title: String, _ groups: [String]) -> some View {
        Section(title) {
            ForEach(groups, id: \.self) { group in
                Toggle(group, isOn: includedGroup(group))
            }
        }.glassRows()
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
