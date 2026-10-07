import SwiftUI

/// Main "Операции" screen
struct OperationsHomeView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    var onAccounts: () -> Void
    var onHorizontalPan: (CGFloat, CGFloat, Bool) -> Void
    
    @State private var period: HistoryPeriod = .lastDays(30)
    @State private var historyExpanded: Bool? = nil
    @State private var showForecast = false
    @AppStorage("reserveBufferRubles") private var reserveBufferRubles = 25_000
    @State private var showSearch = false
    @State private var showAdd = false
    @State private var pendingSavedOperation: ManualOperation?
    @State private var lastSavedOperationID: UUID?
    @State private var editedOperation: ManualOperation?
    @State private var showCustomDates = false
    @State private var customFrom = Date()
    @State private var customThrough = Date()
    @AppStorage("historyAlwaysExpanded") private var historyAlwaysExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    // MARK: - Computed values
    private var interval: DateInterval {
        historyInterval(period)
    }
    private var report: FinanceReport {
        presentation.report(browser.history, interval: interval)
    }
    private var isHistoryExpanded: Bool {
        historyExpanded ?? historyAlwaysExpanded
    }
    private var historyCount: Int {
        presentation.value("count:\(interval.start):\(interval.end)") {
            browser.history.allOperations.reduce(0) { sum, op in
                if let date = BankDateParser.parse(op.occurredAt), interval.contains(date) {
                    return sum + 1
                }
                return sum
            }
        }
    }
    
    // MARK: - Body
    var body: some View {
        let _ = presentation.prepare(browser.history)
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    periodRow.id("operations-top")
                    summary
                    if let operation = browser.history.manualOperations?.first(where: { $0.id == lastSavedOperationID }) {
                        Section {
                            HStack(alignment: .top) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Операция сохранена").font(.subheadline.weight(.semibold))
                                    Text("\(operation.date.formatted(date: .abbreviated, time: .shortened)) · \((Decimal(operation.amountKopecks) / 100).formatted(.currency(code: "RUB")))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Скрыть", systemImage: "xmark") { lastSavedOperationID = nil }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }.listRowBackground(GlassRowBackground())
                    }
                    if browser.busy {
                        busyRow
                    }
                    Section {
                        DisclosureGroup(isExpanded: Binding(
                            get: { isHistoryExpanded },
                            set: { expanded in
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                                    historyExpanded = expanded
                                }
                            }
                        )) {
                            if historyCount == 0 {
                                Text("За этот период операций нет")
                                    .foregroundStyle(.secondary)
                            } else {
                                daySections
                            }
                        } label: {
                            historyHeader
                        }
                        .tint(.primary)
                    }.listRowBackground(GlassRowBackground())
                }
                .appSurface()
                .listStyle(.insetGrouped)
                .gesture(HorizontalPanCapture(onPan: onHorizontalPan))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            onAccounts()
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
                .sheet(isPresented: $showForecast) {
                    let accounts = browser.history.accounts ?? []
                    ForecastDetailView(forecast: presentation.forecast(browser.history),
                                       balanceKopecks: accounts.isEmpty ? nil : currentBalance(accounts),
                                       bufferKopecks: Int64(reserveBufferRubles) * 100)
                }
                .sheet(isPresented: $showSearch) {
                    SearchOperationsView(browser: browser)
                }
                .sheet(isPresented: $showAdd, onDismiss: {
                    if pendingSavedOperation != nil {
                        revealSavedOperation()
                        withAnimation { proxy.scrollTo("operations-top", anchor: .top) }
                    }
                }) {
                    ManualOperationFormView(browser: browser) { operation in
                        pendingSavedOperation = operation
                    }
                }
                .sheet(item: $editedOperation) { operation in
                    ManualOperationFormView(browser: browser, operation: operation)
                }
                .sheet(isPresented: $showCustomDates) {
                    CustomDatesSheet(period: $period,
                                     from: $customFrom,
                                     through: $customThrough)
                }
            }
        }
    }

    private func revealSavedOperation() {
        guard let operation = pendingSavedOperation else { return }
        pendingSavedOperation = nil
        // Apply the selected day after the sheet closes so presentation updates cannot mask the saved entry.
        customFrom = operation.date
        customThrough = operation.date
        period = .custom(from: operation.date, through: operation.date)
        historyExpanded = true
        lastSavedOperationID = operation.id
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
        }.listRowBackground(GlassRowBackground())
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
            let f = presentation.forecast(browser.history)
            HStack(alignment: .top) {
                Button { onAccounts() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "wallet.pass")
                            Text("Текущий остаток")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(accounts.isEmpty ? "—" : rubles(currentBalance(accounts)))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { showForecast = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                            Text("Запас до конца месяца")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if accounts.isEmpty {
                            Text("—").font(.title3.weight(.semibold))
                            Text("добавьте счета").font(.caption).foregroundStyle(.secondary)
                        } else {
                            let reserve = FinancialEngine.monthReserve(balanceKopecks: currentBalance(accounts), forecast: f)
                            Text(signedRubles(reserve))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(reserveColor(reserve))
                            Text(reserveCaption(reserve))
                                .font(.caption).foregroundStyle(reserveColor(reserve))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }.listRowBackground(GlassRowBackground())
    }
    
    private func reserveColor(_ reserve: Int64) -> Color {
        switch FinancialEngine.reserveStatus(reserve, bufferKopecks: Int64(reserveBufferRubles) * 100) {
        case .fine: return .green
        case .tight: return .yellow
        case .short: return .red
        }
    }

    private func signedRubles(_ kopecks: Int64) -> String {
        (kopecks >= 0 ? "+" : "−") + rubles(kopecks >= 0 ? kopecks : -kopecks)
    }

    private func reserveCaption(_ reserve: Int64) -> String {
        switch FinancialEngine.reserveStatus(reserve, bufferKopecks: Int64(reserveBufferRubles) * 100) {
        case .fine: return "хватит"
        case .tight: return "впритык"
        case .short: return "не хватает"
        }
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
        HStack {
            Text("Операции")
                .font(.headline)
            Text("\(historyCount)")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
    
    // MARK: - Day Sections
    /// Operations of the period grouped by calendar day, newest day and newest operation first.
    private var dayGroups: [(day: Date, operations: [BankOperation])] {
        presentation.value("days:\(interval.start):\(interval.end)") {
            let dated = browser.history.allOperations.compactMap { op -> (BankOperation, Date)? in
                guard let date = BankDateParser.parse(op.occurredAt), interval.contains(date) else { return nil }
                return (op, date)
            }
            let byDay = Dictionary(grouping: dated) { Calendar.current.startOfDay(for: $0.1) }
            return byDay.keys.sorted(by: >).map { day in
                (day, byDay[day]!.sorted { $0.1 > $1.1 }.map(\.0))
            }
        }
    }

    private func resolvedInput(for operation: BankOperation) -> FinancialOperationInput? {
        let byID: [String: FinancialOperationInput] = presentation.value("inputsByID") {
            Dictionary(zip(browser.history.allOperations, presentation.inputs(browser.history)).map { ($0.identity, $1) },
                       uniquingKeysWith: { _, last in last })
        }
        return byID[operation.identity]
    }

    private func dayTotal(_ operations: [BankOperation]) -> Int64 {
        presentation.value("dayTotal:\(operations.first?.identity ?? ""):\(operations.count)") {
            operations.reduce(0) { sum, op in
                let assessment = op.financialAssessment
                return sum + assessment.incomeContributionKopecks + assessment.refundContributionKopecks - assessment.expenseContributionKopecks
            }
        }
    }

    private var daySections: some View {
        ForEach(dayGroups, id: \.day) { group in
            Group {
                HStack {
                    Text(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    Spacer()
                    Text(signedRubles(dayTotal(group.operations)))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)

                ForEach(group.operations) { op in
                    if op.isManual {
                        Button {
                            editedOperation = browser.history.manualOperations?.first { $0.id == op.manualID }
                        } label: {
                            OperationRow(operation: op, input: resolvedInput(for: op)).foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            OperationDetailView(browser: browser, operation: op)
                        } label: {
                            OperationRow(operation: op, input: resolvedInput(for: op))
                        }
                    }
                }
            }.listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.82))
        }
    }

    /// Accounts and groups selected for the main screen's current balance.
    private func currentBalance(_ accounts: [Account]) -> Int64 {
        presentation.value("balance") {
            let bankInputs = browser.history.operations.map(\.financialInput)
            return accounts.filter { $0.contributesToBalance(groups: browser.history.accountGroups ?? []) }.reduce(0) { total, account in
                total + account.balance(bankOperations: bankInputs, manual: browser.history.manualOperations ?? [])
            }
        }
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
            .appSurface()
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
