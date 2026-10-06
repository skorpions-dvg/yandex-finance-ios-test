import SwiftUI

/// Main "Операции" screen
struct OperationsHomeView: View {
    @ObservedObject var browser: BankBrowser
    
    @State private var period: HistoryPeriod = .lastDays(30)
    @State private var historyExpanded: Bool? = nil
    @State private var showAccounts = false
    @State private var showSearch = false
    @State private var showAdd = false
    @State private var showCustomDates = false
    @State private var customFrom = Date()
    @State private var customThrough = Date()
    @AppStorage("historyAlwaysExpanded") private var historyAlwaysExpanded = false
    
    // MARK: - Computed values
    private var inputs: [FinancialOperationInput] {
        browser.history.operations.map(\.financialInput)
    }
    private var interval: DateInterval {
        historyInterval(period)
    }
    private var report: FinanceReport {
        FinancialEngine.report(inputs, in: interval)
    }
    private var isHistoryExpanded: Bool {
        historyExpanded ?? historyAlwaysExpanded
    }
    private var historyCount: Int {
        browser.history.operations.reduce(0) { sum, op in
            if let date = BankDateParser.parse(op.occurredAt), interval.contains(date) {
                return sum + 1
            }
            return sum
        }
    }
    
    // MARK: - Body
    var body: some View {
        NavigationStack {
            List {
                periodRow
                summary
                forecast
                if browser.busy {
                    busyRow
                }
                Section {
                    historyHeader
                }
                if historyCount == 0 {
                    Text("За этот период операций нет")
                        .foregroundStyle(.secondary)
                } else if isHistoryExpanded {
                    daySections
                }
            }
            .listStyle(.insetGrouped)
            // Swipe right on the main screen opens the accounts, like in Money Flow.
            .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { drag in
                if drag.translation.width > 100 && abs(drag.translation.height) < 60 { showAccounts = true }
            })
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showAccounts = true
                    } label: {
                        Label("Все счета", systemImage: "wallet.pass")
                            .labelStyle(.titleAndIcon)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .sheet(isPresented: $showAccounts) {
                AccountsView(browser: browser)
            }
            .sheet(isPresented: $showSearch) {
                SearchOperationsView(browser: browser)
            }
            .sheet(isPresented: $showAdd) {
                ComingSoonSheet(title: "Добавить",
                                text: "Добавление доходов и расходов вручную появится в следующей версии.")
            }
            .sheet(isPresented: $showCustomDates) {
                CustomDatesSheet(period: $period,
                                 from: $customFrom,
                                 through: $customThrough)
            }
        }
    }
    
    // MARK: - Period Row
    private var periodRow: some View {
        Section {
            VStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        capsuleButton(title: "Период",
                                      icon: "calendar",
                                      selected: periodIsCustom,
                                      action: { showCustomDates = true })
                        capsuleButton(title: "Сегодня",
                                      selected: period == .lastDays(1),
                                      action: { period = .lastDays(1) })
                        capsuleButton(title: "7 дней",
                                      selected: period == .lastDays(7),
                                      action: { period = .lastDays(7) })
                        capsuleButton(title: "30 дней",
                                      selected: period == .lastDays(30),
                                      action: { period = .lastDays(30) })
                        capsuleButton(title: "365 дней",
                                      selected: period == .lastDays(365),
                                      action: { period = .lastDays(365) })
                        capsuleButton(title: "Вся история",
                                      selected: period == .allTime,
                                      action: { period = .allTime })
                    }
                }
                if periodIsCustom {
                    Text("\(customFrom.formatted(.dateTime.day().month().year())) — \(customThrough.formatted(.dateTime.day().month().year()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var periodIsCustom: Bool {
        if case .custom = period { return true }
        return false
    }
    
    private func capsuleButton(title: String,
                               icon: String? = nil,
                               selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if let icon = icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? .orange : .primary)
            .background(selected ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.15),
                        in: Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Summary
    private var summary: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text("Доходы")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(rubles(report.incomeKopecks))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "arrow.up.circle")
                        Text("Расходы")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(rubles(report.netExpenseKopecks))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            let accounts = browser.history.accounts ?? []
            if !accounts.isEmpty {
                Button { showAccounts = true } label: {
                    HStack {
                        Label("Текущий остаток", systemImage: "wallet.pass")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(rubles(currentBalance(accounts)))
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Forecast
    private var forecast: some View {
        Section(header: Text("Прогноз на месяц")) {
            let f = FinancialEngine.monthForecast(inputs)
            LabeledContent("Потрачено за \(f.elapsedDays) из \(f.daysInMonth) дн.", value: rubles(f.spentKopecks))
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Расходы к концу месяца", value: "≈ " + rubles(f.projectedExpenseKopecks))
                Text("обычно от \(rubles(f.projectedExpenseLowKopecks)) до \(rubles(f.projectedExpenseHighKopecks))")
                    .font(.caption).foregroundStyle(.secondary)
                if f.oneOffKopecks > 0 {
                    Text("Разовые покупки \(rubles(f.oneOffKopecks)) учтены как потраченные, но не в темпе")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Доход за месяц", value: "≈ " + rubles(f.projectedIncomeKopecks))
                Text("пришло пока \(rubles(f.incomeKopecks)) + ожидаемая зарплата · в прошлом месяце \(rubles(f.previousMonthIncomeKopecks))")
                    .font(.caption).foregroundStyle(.secondary)
                if f.typicalIrregularIncomeKopecks > 0 {
                    Text("Нерегулярные поступления обычно ≈ \(rubles(f.typicalIrregularIncomeKopecks)) в месяц")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            balanceLine(f.projectedBalanceKopecks, scenario: "Без новых поступлений")
            if f.balanceWithTypicalIncomeKopecks != f.projectedBalanceKopecks {
                balanceLine(f.balanceWithTypicalIncomeKopecks, scenario: "С обычными поступлениями")
            }
            if !f.upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ещё ожидается").font(.caption).foregroundStyle(.secondary)
                    ForEach(f.upcoming) { payment in
                        HStack {
                            Image(systemName: payment.isIncome ? "arrow.down.circle" : "arrow.up.circle")
                                .foregroundStyle(payment.isIncome ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(payment.title).lineLimit(1)
                                Text(payment.overdue
                                     ? "ожидался \(payment.date.formatted(.dateTime.day().month())), не пришёл"
                                     : payment.date.formatted(.dateTime.day().month()))
                                    .font(.caption)
                                    .foregroundStyle(payment.overdue ? .orange : .secondary)
                            }
                            Spacer()
                            Text((payment.isIncome ? "+" : "−") + rubles(payment.amountKopecks))
                                .foregroundStyle(payment.isIncome ? .green : .primary)
                        }
                        .font(.subheadline)
                    }
                }
            }
            if !f.baselineMonths.isEmpty {
                DisclosureGroup("Как посчитано") {
                    ForEach(f.baselineMonths) { month in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(month.month.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(rubles(month.netExpenseKopecks)).font(.subheadline)
                            }
                            Text("переменные \(rubles(month.variableKopecks)) · регулярные \(rubles(month.recurringKopecks)) · разовые \(rubles(month.oneOffKopecks))")
                                .font(.caption).foregroundStyle(.secondary)
                            if !month.largestOneOffs.isEmpty {
                                Text("разовые: " + month.largestOneOffs.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Расходы к концу месяца = потрачено + ещё ожидаемые регулярные + переменные траты до конца месяца по медиане этих месяцев с поправкой на темп. Вилка — по нижней и верхней четверти этих месяцев.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if f.historyMonths < 3 {
                Text("Истории пока мало (\(f.historyMonths) мес.), прогноз приблизительный.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    
    private func balanceLine(_ balance: Int64, scenario: String) -> some View {
        Label(balance >= 0
              ? "\(scenario): останется ≈ \(rubles(balance))"
              : "\(scenario): не хватит ≈ \(rubles(-balance))",
              systemImage: balance >= 0 ? "checkmark.circle" : "exclamationmark.triangle")
            .foregroundStyle(balance >= 0 ? .green : .orange)
            .font(.subheadline)
    }

    // MARK: - Busy Row
    private var busyRow: some View {
        HStack {
            ProgressView()
            Text("Обновление операций…")
                .font(.footnote)
        }
    }
    
    // MARK: - History Header
    private var historyHeader: some View {
        Button(action: {
            historyExpanded = !isHistoryExpanded
        }) {
            HStack {
                Text("Операции")
                    .font(.headline)
                Text("\(historyCount)")
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isHistoryExpanded ? 90 : 0))
            }
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Day Sections
    /// Operations of the period grouped by calendar day, newest day and newest operation first.
    private var dayGroups: [(day: Date, operations: [BankOperation])] {
        let dated = browser.history.operations.compactMap { op -> (BankOperation, Date)? in
            guard let date = BankDateParser.parse(op.occurredAt), interval.contains(date) else { return nil }
            return (op, date)
        }
        let byDay = Dictionary(grouping: dated) { Calendar.current.startOfDay(for: $0.1) }
        return byDay.keys.sorted(by: >).map { day in
            (day, byDay[day]!.sorted { $0.1 > $1.1 }.map(\.0))
        }
    }

    private func dayTotal(_ operations: [BankOperation]) -> Int64 {
        operations.reduce(0) { sum, op in
            let assessment = op.financialAssessment
            return sum + assessment.incomeContributionKopecks + assessment.refundContributionKopecks - assessment.expenseContributionKopecks
        }
    }

    private var daySections: some View {
        ForEach(dayGroups, id: \.day) { group in
            Section {
                ForEach(group.operations) { op in
                    NavigationLink {
                        OperationDetailView(operation: op)
                    } label: {
                        OperationRow(operation: op)
                    }
                }
            } header: {
                HStack {
                    Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    Spacer()
                    Text(signedRubles(dayTotal(group.operations)))
                }
            }
        }
    }

    /// Sum of the accounts that show their balance, the same way the accounts screen counts them.
    private func currentBalance(_ accounts: [Account]) -> Int64 {
        accounts.filter(\.showsBalance).reduce(0) { total, account in
            total + FinancialEngine.accountBalance(startKopecks: account.startBalanceKopecks, since: account.startDate,
                                                   tracksBankCard: account.tracksBankCard, operations: inputs)
        }
    }

    private func signedRubles(_ kopecks: Int64) -> String {
        let formatted = rubles(kopecks)
        return kopecks >= 0 ? "+" + formatted : formatted
    }
    
    // MARK: - Money Helper
    private func rubles(_ kopecks: Int64) -> String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }
}

// MARK: - Custom Dates Sheet
private struct CustomDatesSheet: View {
    @Binding var period: HistoryPeriod
    @Binding var from: Date
    @Binding var through: Date
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("С", selection: $from, displayedComponents: .date)
                DatePicker("По", selection: $through, displayedComponents: .date)
            }
            .navigationTitle("Выбрать даты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        period = .custom(from: from, through: through)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Coming Soon Sheet
private struct ComingSoonSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ContentUnavailableView(title,
                                   systemImage: "hammer",
                                   description: Text(text))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Закрыть") {
                            dismiss()
                        }
                    }
                }
        }
    }
}
