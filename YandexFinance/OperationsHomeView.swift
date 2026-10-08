import SwiftUI

/// Main "Операции" screen
struct OperationsHomeView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    var onAccounts: () -> Void
    var onHorizontalPan: (CGFloat, CGFloat, Bool) -> Void
    
    /// The chosen period is remembered between launches (and when the app is locked and rebuilt).
    @AppStorage("homePeriod") private var storedPeriod = ""
    private var period: HistoryPeriod {
        get { HistoryPeriod(storageText: storedPeriod) ?? .lastDays(30) }
        nonmutating set { storedPeriod = newValue.storageText }
    }
    @State private var historyExpanded: Bool? = nil
    @State private var showForecast = false
    @State private var showBudgets = false
    /// «Доходы» / «Расходы» tapped: the report of the chosen period.
    @State private var periodReport: ReportMode?
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
                if let date = BankDateParser.parse(op.occurredAt), date >= interval.start, date < interval.end {
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
                    // Placeholders for the fraction of a second the history is still being read at launch.
                    summary.redacted(reason: browser.loadingHistory ? .placeholder : [])
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
                        }.glassRows()
                    }
                    if browser.busy {
                        busyRow
                    }
                    Section {
                        historyHeader
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    // Ordinary list sections: the list inserts and removes them itself, rolling the days out below the
                    // header and back up, and only the rows on screen are built.
                    if isHistoryExpanded {
                        if historyCount == 0 {
                            Section {
                                Text("За этот период операций нет").foregroundStyle(.secondary)
                            }
                            .listRowBackground(historyRowBackground)
                        } else {
                            daySections
                        }
                    }
                }
                .appSurface()
                .listStyle(.insetGrouped)
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
                        // The same check as «Обновить новые операции» in Settings, including the sign-in page.
                        Button {
                            browser.refreshNewOperations()
                        } label: {
                            if browser.busy {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(browser.busy)
                        .accessibilityLabel("Обновить новые операции")
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
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .sheet(isPresented: $showForecast) {
                    let reserveAccounts = browser.history.reserveAccounts
                    ForecastDetailView(forecast: presentation.forecast(browser.history),
                                       balanceKopecks: reserveAccounts.isEmpty ? nil : reserveBalance(),
                                       accountNames: reserveAccounts.map(\.name),
                                       browser: browser, presentation: presentation)
                }
                .sheet(isPresented: $showSearch) {
                    SearchOperationsView(browser: browser)
                }
                .sheet(item: $periodReport) { mode in
                    PeriodReportView(browser: browser, presentation: presentation, interval: interval, mode: mode)
                }
                .sheet(isPresented: $showBudgets) {
                    NavigationStack {
                        BudgetsView(browser: browser, presentation: presentation)
                            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { showBudgets = false } } }
                    }
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
                    CustomDatesSheet(period: Binding(get: { period }, set: { period = $0 }),
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
                                      action: { openCustomDates() })
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
                if case .custom(let from, let through) = period {
                    Text("\(from.formatted(.dateTime.day().month().year())) — \(through.formatted(.dateTime.day().month().year()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }.glassRows()
    }
    
    /// The sheet starts from the dates in use, or from today.
    private func openCustomDates() {
        if case .custom(let from, let through) = period {
            customFrom = from
            customThrough = through
        } else {
            customFrom = Date()
            customThrough = Date()
        }
        showCustomDates = true
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
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15),
                        in: Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Summary
    private var summary: some View {
        Section {
            HStack {
                Button { periodReport = .income } label: {
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
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Button { periodReport = .expenses } label: {
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
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                        if accounts.isEmpty || browser.history.reserveAccounts.isEmpty {
                            Text("—").font(.title3.weight(.semibold))
                            Text(accounts.isEmpty ? "добавьте счета" : "выберите счета в настройках").font(.caption).foregroundStyle(.secondary)
                        } else {
                            let reserve = FinancialEngine.monthReserve(balanceKopecks: reserveBalance(), forecast: f)
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
            let budgets = presentation.budgetStatuses(browser.history, month: Date())
            if !budgets.isEmpty { budgetLine(budgets) }
        }.glassRows()
    }
    
    /// «Budget of the month»: the bar of the whole month's limit and the groups that have used up theirs.
    private func budgetLine(_ statuses: [BudgetStatus]) -> some View {
        let total = statuses.first { $0.group == nil }
        let notices = BudgetEngine.notices(statuses)
        return Button { showBudgets = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let total {
                    HStack {
                        Image(systemName: "target")
                        Text("Бюджет месяца: потрачено \(total.percent) %")
                        Spacer()
                        Text(total.caption).foregroundStyle(total.level == .calm ? Color.secondary : total.level.color)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    BudgetBar(fraction: total.fraction, level: total.level)
                }
                ForEach(notices) { notice in
                    HStack {
                        if total == nil { Image(systemName: "target") }
                        Text(notice.text).foregroundStyle(notice.level.color)
                    }
                    .font(.caption)
                }
                if total == nil && notices.isEmpty {
                    HStack {
                        Image(systemName: "target")
                        Text("Бюджеты: всё в пределах лимитов")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        case .fine: return "с запасом"
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
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
                historyExpanded = !isHistoryExpanded
            }
        } label: {
            HStack {
                Text("Операции").font(.headline)
                Text("\(historyCount)").foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isHistoryExpanded ? 0 : -90))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.thinMaterial, in: .rect(cornerRadius: 24))
        .accessibilityValue(isHistoryExpanded ? "Развёрнуто" : "Свёрнуто")
    }
    
    // MARK: - Day Sections
    /// Operations of the period grouped by calendar day, newest day and newest operation first.
    private var dayGroups: [(day: Date, operations: [BankOperation])] {
        presentation.value("days:\(interval.start):\(interval.end)") {
            let dated = browser.history.allOperations.compactMap { op -> (BankOperation, Date)? in
                guard let date = BankDateParser.parse(op.occurredAt), date >= interval.start, date < interval.end else { return nil }
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
            let resolver = ExpenseCategoryResolver(browser.history)
            return operations.reduce(0) { sum, op in
                let assessment = FinancialEngine.classify(resolver.financialInput(for: op))
                return sum + assessment.incomeContributionKopecks + assessment.refundContributionKopecks - assessment.expenseContributionKopecks
            }
        }
    }

    /// One calm surface for every history row, so rows do not differ in colour over the wallpaper.
    private var historyRowBackground: Color {
        Color(uiColor: .secondarySystemGroupedBackground).opacity(0.82)
    }

    private var daySections: some View {
        ForEach(dayGroups, id: \.day) { group in
            Section {
                ForEach(group.operations) { op in
                    Group {
                        if op.isManual {
                            Button {
                                editedOperation = browser.history.manualOperations?.first { $0.id == op.manualID }
                            } label: {
                                historyOperationRow(op)
                            }
                            .buttonStyle(.plain)
                        } else {
                            // The hidden link makes the whole row open the card without a second list chevron.
                            historyOperationRow(op)
                                .background {
                                    NavigationLink {
                                        OperationDetailView(browser: browser, operation: op)
                                    } label: { EmptyView() }
                                    .opacity(0)
                                }
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(historyRowBackground)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 62 }
                    .listRowSeparatorTint(Color.primary.opacity(0.22))
                }
            } header: {
                let total = dayTotal(group.operations)
                HStack {
                    Text(dayTitle(group.day))
                    Spacer()
                    Text(signedRubles(total)).foregroundStyle(total > 0 ? Color.green : Color.primary).monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            }
        }
    }

    /// «Среда, 7 октября»; the year only for a day of another year.
    private func dayTitle(_ day: Date) -> String {
        let sameYear = Calendar.current.component(.year, from: day) == Calendar.current.component(.year, from: Date())
        let text = sameYear ? day.formatted(.dateTime.weekday(.wide).day().month(.wide))
                            : day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func historyOperationRow(_ operation: BankOperation) -> some View {
        HStack(spacing: 8) {
            OperationRow(operation: operation, input: resolvedInput(for: operation), look: browser.history.look(for: operation),
                         hasReceipt: browser.history.hasReceipt(operation))
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// The balance of the accounts the reserve counts (money put aside is not in it).
    private func reserveBalance() -> Int64 {
        presentation.value("reserveBalance") { browser.history.reserveBalanceKopecks }
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
                Button {
                    if case .custom(let first, let last) = HistoryPeriod.currentMonth() {
                        from = first
                        through = last
                    }
                } label: {
                    // Plain blue text sinks into the glass of the sheet: the words keep the main colour, the icon the accent.
                    Label {
                        Text("Текущий месяц (с 1 числа)").foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "calendar").foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                // A plain button keeps the colours of its label: the standard style paints the whole row blue.
                .buttonStyle(.plain)
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
                        // The sheet closes first; the screen behind it recounts the operations right after.
                        let chosen = HistoryPeriod.custom(from: from, through: through)
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            period = chosen
                        }
                    } label: {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
