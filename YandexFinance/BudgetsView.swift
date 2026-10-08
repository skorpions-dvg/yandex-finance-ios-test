import SwiftUI

func budgetWholeRubles(_ kopecks: Int64) -> String {
    (Decimal(kopecks) / 100).formatted(.currency(code: "RUB").precision(.fractionLength(0)))
}

extension BudgetLevel {
    var color: Color {
        switch self {
        case .calm: return .accentColor
        case .warning: return .orange
        case .exceeded: return .red
        }
    }
}

extension BudgetStatus {
    var title: String { group ?? "Весь месяц" }

    /// The line under the bar: what is left, or by how much the limit is exceeded.
    var caption: String {
        switch level {
        case .calm: return "Осталось \(budgetWholeRubles(remainingKopecks))"
        case .warning: return remainingKopecks > 0 ? "Почти исчерпан · осталось \(budgetWholeRubles(remainingKopecks))" : "Лимит исчерпан"
        case .exceeded: return "Превышен на \(budgetWholeRubles(-remainingKopecks))"
        }
    }
}

/// A thin bar of how much of a limit is spent; the colour follows the level of the budget.
struct BudgetBar: View {
    let fraction: Double
    let level: BudgetLevel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(level.color).frame(width: max(4, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}

/// What the form edits: a group (nil: the whole month) and whether a limit already exists for it.
struct BudgetFormTarget: Identifiable {
    let group: String?
    let isNew: Bool
    /// The month the form edits («yyyy-MM»), fixed when the form opens: a form left open over midnight keeps its month.
    let month: String
    var id: String { (group ?? "—month") + (isNew ? "+new" : "") + month }
}

/// «Бюджеты»: the limits of the current month with what is spent against each, and the form to change them.
@MainActor
struct BudgetsView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    @State private var editing: BudgetFormTarget?

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let month = Date()
        let statuses = presentation.budgetStatuses(browser.history, month: month)
        let monthKey = BudgetEngine.monthKey(month)
        List {
            Section {
                Text(month.formatted(.dateTime.month(.wide).year()).capitalized).font(.headline)
                Text("Лимит считается на каждый месяц. Для одного месяца можно задать свою сумму: она заменит обычную. Расходы считаются как в отчётах: возвраты вычитаются, переводы между своими счетами не учитываются.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.glassRows()
            if statuses.isEmpty {
                Section {
                    ContentUnavailableView("Бюджетов пока нет", systemImage: "target",
                                           description: Text("Задайте лимит на весь месяц или на группу расходов, например «Еда»."))
                    Button { editing = BudgetFormTarget(group: nil, isNew: true, month: monthKey) } label: {
                        Label { Text("Добавить бюджет").foregroundStyle(.primary) } icon: { Image(systemName: "plus.circle").foregroundStyle(.primary) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }.glassRows()
            } else {
                if let total = statuses.first(where: { $0.group == nil }) {
                    Section("Весь месяц") { row(total, monthKey) }.glassRows()
                } else {
                    Section {
                        Button { editing = BudgetFormTarget(group: nil, isNew: true, month: monthKey) } label: {
                            Label { Text("Задать лимит на весь месяц").foregroundStyle(.primary) } icon: { Image(systemName: "plus.circle").foregroundStyle(.primary) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }.glassRows()
                }
                let groups = statuses.filter { $0.group != nil }
                if !groups.isEmpty {
                    Section("Группы расходов") { ForEach(groups) { row($0, monthKey) } }.glassRows()
                }
            }
        }
        .appSurface()
        .navigationTitle("Бюджеты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = BudgetFormTarget(group: nil, isNew: true, month: BudgetEngine.monthKey(Date())) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить бюджет")
            }
        }
        .sheet(item: $editing) { target in
            BudgetFormView(browser: browser, presentation: presentation, target: target)
        }
    }

    private func row(_ status: BudgetStatus, _ monthKey: String) -> some View {
        Button { editing = BudgetFormTarget(group: status.group, isNew: false, month: monthKey) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: status.group == nil ? "calendar" : "tag").foregroundStyle(.secondary).frame(width: 24)
                    Text(status.title).font(.headline)
                    if status.isMonthOnly { Text("только этот месяц").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text("\(status.percent) %").font(.headline).monospacedDigit().foregroundStyle(status.level.color)
                }
                BudgetBar(fraction: status.fraction, level: status.level)
                HStack {
                    Text("\(budgetWholeRubles(status.spentKopecks)) из \(budgetWholeRubles(status.limitKopecks))")
                    Spacer()
                    Text(status.caption).foregroundStyle(status.level == .calm ? Color.secondary : status.level.color)
                }
                .font(.caption).monospacedDigit()
            }
        }
        .buttonStyle(.plain)
    }
}

/// The form of one limit: what to limit, the amount, and whether it is for this month only.
@MainActor
struct BudgetFormView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    let target: BudgetFormTarget
    @Environment(\.dismiss) private var dismiss
    @State private var group: String?
    @State private var amountText = ""
    @State private var monthOnly = false
    @State private var error: String?
    @State private var loaded = false

    private var monthKey: String { target.month }

    /// «Октябрь 2026» for the month the form edits.
    private var monthTitle: String {
        let parts = target.month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return target.month }
        return date.formatted(.dateTime.month(.wide).year()).capitalized
    }
    private var budgets: [Budget] { browser.history.budgets ?? [] }

    /// The groups of the user's tree, and the group of a limit whose group has been deleted since.
    private var groupNames: [String] {
        var names = browser.history.categoryTree.map(\.name)
        if let group, !names.contains(group) { names.append(group) }
        return names
    }

    private var parsedAmount: Int64? {
        guard let kopecks = ReceiptParser.kopecks(fromDecimal: amountText.filter { !$0.isWhitespace }), kopecks > 0 else { return nil }
        return kopecks
    }

    private var existing: (limitKopecks: Int64, isMonthOnly: Bool)? { BudgetEngine.limit(budgets, group: group, monthKey: monthKey) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if target.isNew {
                        Picker("Что ограничить", selection: $group) {
                            Text("Весь месяц").tag(String?.none)
                            ForEach(groupNames, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    } else {
                        LabeledContent("Что ограничить", value: group ?? "Весь месяц")
                    }
                    LabeledContent("Месяц", value: monthTitle)
                    TextField("Лимит, ₽", text: $amountText).keyboardType(.decimalPad)
                    Toggle("Только на этот месяц", isOn: $monthOnly)
                } footer: {
                    if target.isNew, existing != nil {
                        Text("Для этого лимит уже задан: он будет заменён.")
                    } else {
                        Text(monthOnly ? "Сумма действует только в этом месяце, в остальных месяцах остаётся обычный лимит."
                                       : "Сумма действует в каждом месяце.")
                    }
                }.glassRows()
                if !target.isNew {
                    Section {
                        Button("Удалить бюджет", role: .destructive) { remove() }
                    }.glassRows()
                }
            }
            .appSurface()
            .navigationTitle(target.isNew ? "Новый бюджет" : "Бюджет")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Сохранить") { save() }.disabled(parsedAmount == nil) }
            }
            .alert("Не удалось сохранить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                group = target.group
                if let held = BudgetEngine.limit(budgets, group: target.group, monthKey: monthKey), !target.isNew {
                    amountText = (Decimal(held.limitKopecks) / 100).description.replacingOccurrences(of: ".", with: ",")
                    monthOnly = held.isMonthOnly
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let kopecks = parsedAmount else { return }
        let key = monthKey
        let chosen = group
        let thisMonthOnly = monthOnly
        let ok = browser.updateUserDataAfterClosing { history in
            if thisMonthOnly {
                history.setBudget(group: chosen, limitKopecks: kopecks, month: key)
            } else {
                // A limit «for every month» also replaces this month's own one, so this month follows it.
                history.removeBudget(group: chosen, month: key)
                history.setBudget(group: chosen, limitKopecks: kopecks, month: nil)
            }
        }
        if ok { dismiss() } else { error = browser.message }
    }

    private func remove() {
        let chosen = group
        let key = monthKey
        let monthly = existing?.isMonthOnly ?? false
        let ok = browser.updateUserDataAfterClosing { $0.removeBudget(group: chosen, month: monthly ? key : nil) }
        if ok { dismiss() } else { error = browser.message }
    }
}
