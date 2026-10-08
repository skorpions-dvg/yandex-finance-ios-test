import SwiftUI
import Charts

enum ReportTab: String, CaseIterable, Identifiable {
    case structure, dynamics, balances, flow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .structure: return "Структура"
        case .dynamics: return "Динамика"
        case .balances: return "Остатки"
        case .flow: return "Доходы и расходы"
        }
    }
    var symbol: String {
        switch self {
        case .structure: return "chart.pie"
        case .dynamics: return "chart.bar"
        case .balances: return "chart.line.uptrend.xyaxis"
        case .flow: return "arrow.up.arrow.down"
        }
    }
}

enum ReportPalette {
    private static let known: [String: Color] = [
        "Еда": .orange, "Транспорт": .blue, "Покупки": .purple, "Обязательные": .teal, "Другое": .gray, "Переводы": .indigo,
    ]
    private static let spare: [Color] = [.pink, .mint, .cyan, .brown, .yellow, .red, .green]

    /// The same colour for the same name everywhere: the chart, the list and the details.
    static func color(_ name: String) -> Color {
        if let color = known[name] { return color }
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }
        return spare[sum % spare.count]
    }
}

private func reportRubles(_ kopecks: Int64) -> String {
    (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
}

private func reportWholeRubles(_ kopecks: Int64) -> String {
    (Decimal(kopecks) / 100).formatted(.currency(code: "RUB").precision(.fractionLength(0)))
}

private func shortAmount(_ rubles: Double) -> String {
    let value = abs(rubles)
    if value >= 1_000_000 { return (rubles / 1_000_000).formatted(.number.precision(.fractionLength(0...1))) + " млн" }
    if value >= 1_000 { return (rubles / 1_000).formatted(.number.precision(.fractionLength(0...1))) + " тыс." }
    return rubles.formatted(.number.precision(.fractionLength(0)))
}

/// «Отчёты»: four views of the same period. The tabs, the ribbon of months and the filters stay put above the list, so
/// nothing in the chart moves when a period is chosen.
@MainActor
struct ReportsView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    @State private var tab: ReportTab = .structure
    @State private var period: ReportPeriod = .month(Date())
    @State private var mode: ReportMode = .expenses
    @State private var grouping: ReportGrouping = .categories
    @State private var stepChoice: ReportStep = .automatic
    @State private var perAccount = false
    @State private var showPeriodSheet = false
    @State private var filter: ReportFilter = .none
    @State private var showFilterSheet = false
    @State private var accountChoice: ReportAccountChoice = .all
    @Environment(\.colorScheme) private var scheme

    /// The ink of the pills over the wallpaper: white on the dark theme, the usual text colour on the light one.
    private var ink: Color { scheme == .dark ? Color.white : Color.primary }

    private var calendar: Calendar { .current }

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let resolved = accountChoice.resolve(accounts: browser.history.accounts ?? [], groups: browser.history.accountGroups ?? [])
        // The exclusions of the filter sheet plus the chosen accounts: what the four reports are computed for.
        let scopedFilter: ReportFilter = {
            var scoped = filter
            scoped.scope = resolved.scope
            return scoped
        }()
        // Not cached: the ribbon of months must follow the history the moment it is loaded.
        let first: Date? = browser.history.allOperations.compactMap { BankDateParser.parse($0.occurredAt) }.min()
        let interval = period.interval(firstDate: first)
        let step = ReportEngine.step(stepChoice, for: interval)
        let buckets = ReportEngine.buckets(interval, step: step)
        // Balances and income/expenses do not show months before the first operation.
        // Income and expenses stop at today; the balances go on to the end of the month as a forecast.
        let trimmedBuckets = ReportEngine.trimmed(buckets, from: first)
        let shownBuckets = tab == .balances ? trimmedBuckets : (tab == .flow ? ReportEngine.untilToday(trimmedBuckets) : buckets)
        let shownInterval = (shownBuckets.first != nil && shownBuckets.last != nil)
            ? DateInterval(start: shownBuckets[0].start, end: shownBuckets[shownBuckets.count - 1].end) : interval
        NavigationStack {
            VStack(spacing: 0) {
                header(resolved)
                List {
                    switch tab {
                    case .structure:
                        StructureContent(browser: browser, presentation: presentation, interval: interval, mode: mode,
                                         grouping: grouping, showsChart: true, buckets: buckets, filter: scopedFilter)
                    case .dynamics:
                        DynamicsContent(browser: browser, presentation: presentation, interval: interval, mode: mode,
                                        grouping: grouping, buckets: buckets, step: step, filter: scopedFilter)
                    case .balances:
                        BalancesContent(browser: browser, presentation: presentation, interval: shownInterval, buckets: shownBuckets, step: step,
                                        perAccount: perAccount, accounts: resolved.scope.isAll ? browser.history.reserveAccounts : resolved.accounts,
                                        isScoped: !resolved.scope.isAll)
                    case .flow:
                        FlowContent(presentation: presentation, browser: browser, interval: shownInterval, buckets: shownBuckets, step: step, filter: scopedFilter)
                    }
                }
                .appSurface()
            }
            .navigationTitle("Отчёты")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPeriodSheet) {
                ReportPeriodSheet(period: $period, first: first)
            }
            .sheet(isPresented: $showFilterSheet) {
                ReportFilterSheet(browser: browser, presentation: presentation, interval: interval, mode: mode,
                                  bothModes: tab == .flow, scope: resolved.scope, filter: $filter)
            }
            .onChange(of: mode) { _, newMode in
                let groups = ReportFilterSheet.groups(browser: browser, presentation: presentation, interval: interval, mode: newMode, scope: resolved.scope)
                filter.excludedGroups.formIntersection(Set(groups))
            }
        }
    }

    // MARK: Header

    private func header(_ resolved: ReportAccountChoice.Resolved) -> some View {
        VStack(spacing: 10) {
            tabBar
            periodAndAccount(resolved)
            filters
        }
        .padding(.vertical, 8)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ReportTab.allCases) { item in
                    Button { tab = item } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .foregroundStyle(tab == item ? Color.white : Color.primary)
                            .background(tab == item ? Color.accentColor : Color.primary.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// The chosen period (the sheet behind it lists every month of the history) and, next to it, the accounts.
    private func periodAndAccount(_ resolved: ReportAccountChoice.Resolved) -> some View {
        HStack(spacing: 8) {
            Button { showPeriodSheet = true } label: {
                HStack(spacing: 4) {
                    Text(periodTitle).lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ink)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.primary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            if !(browser.history.accounts ?? []).isEmpty { accountMenu(resolved) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    /// «All accounts», one account or a group of accounts; the reports and the balances follow the choice.
    private func accountMenu(_ resolved: ReportAccountChoice.Resolved) -> some View {
        let groups = browser.history.accountGroups ?? []
        let accounts = browser.history.accounts ?? []
        let active = !resolved.scope.isAll
        return Menu {
            Button { accountChoice = .all } label: {
                Label("Все счета", systemImage: active ? "wallet.pass" : "checkmark")
            }
            if !groups.isEmpty {
                Section("Группы") {
                    ForEach(groups) { group in
                        Button { accountChoice = .group(group.id) } label: {
                            Label(group.name, systemImage: accountChoice == .group(group.id) && resolved.isValid ? "checkmark" : "folder")
                        }
                    }
                }
            }
            Section("Счета") {
                ForEach(accounts) { account in
                    Button { accountChoice = .account(account.id) } label: {
                        Label(account.name, systemImage: accountChoice == .account(account.id) && resolved.isValid ? "checkmark" : account.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "wallet.pass")
                Text(resolved.title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(active ? Color.white : ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(active ? Color.accentColor : Color.primary.opacity(0.1), in: Capsule())
        }
        .tint(active ? .white : ink)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if tab == .structure || tab == .dynamics {
                    Menu {
                        Picker("Тип", selection: $mode) { ForEach(ReportMode.allCases) { Text($0.title).tag($0) } }
                    } label: { pill(mode.title) }
                    .tint(ink)
                    Menu {
                        Picker("Группировка", selection: $grouping) { ForEach(ReportGrouping.allCases) { Text($0.title).tag($0) } }
                    } label: { pill(grouping.title) }
                    .tint(ink)
                }
                if tab == .balances {
                    Menu {
                        Picker("Линии", selection: $perAccount) {
                            Text("Одна линия").tag(false)
                            Text("По счетам").tag(true)
                        }
                    } label: { pill(perAccount ? "По счетам" : "Одна линия") }
                    .tint(ink)
                }
                if tab != .structure {
                    Menu {
                        Picker("Шаг", selection: $stepChoice) { ForEach(ReportStep.allCases) { Text($0.title).tag($0) } }
                    } label: { pill(stepChoice == .automatic ? "Шаг" : stepChoice.title) }
                    .tint(ink)
                }
                if tab != .balances {
                    Button { showFilterSheet = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(filter.isActive ? "Фильтр · \(filter.excludedGroups.count + filter.excludedPayees.count)" : "Фильтр")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(filter.isActive ? Color.white : ink)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(filter.isActive ? Color.accentColor : Color.primary.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func pill(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(ink)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.1), in: Capsule())
    }

    // MARK: Text

    private var periodTitle: String {
        switch period {
        case .month(let date): return date.formatted(.dateTime.month(.wide).year()).capitalized
        case .year(let date): return date.formatted(.dateTime.year())
        case .lastDays(let days): return "Последние \(days) дн."
        case .custom(let from, let through):
            return from.formatted(.dateTime.day().month(.abbreviated)) + " – " + through.formatted(.dateTime.day().month(.abbreviated))
        case .allHistory: return "Вся история"
        }
    }
}

// MARK: - Structure

/// The ring and the list of groups of the shown total.
private struct StructureContent: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    let interval: DateInterval
    let mode: ReportMode
    let grouping: ReportGrouping
    let showsChart: Bool
    let buckets: [DateInterval]
    let filter: ReportFilter

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let slices = ReportSliceList.compute(browser: browser, presentation: presentation, interval: interval, mode: mode, grouping: grouping, filter: filter)
        let report = presentation.report(browser.history, interval: interval, scope: filter.scope)
        let total = slices.reduce(Int64(0)) { $0 + $1.amountKopecks }
        let headline = mode == .expenses && !filter.isActive ? report.netExpenseKopecks : total
        if showsChart {
            Section {
                if slices.isEmpty {
                    ContentUnavailableView("Нет операций", systemImage: "chart.pie",
                                           description: Text("За выбранный период нет \(mode == .expenses ? "расходов" : "доходов")."))
                } else {
                    Chart(slices) { slice in
                        SectorMark(angle: .value("Сумма", Double(slice.amountKopecks) / 100), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(ReportPalette.color(slice.title))
                    }
                    .chartLegend(.hidden)
                    .frame(height: 240)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            if let frame = proxy.plotFrame, total > 0 {
                                let rect = geometry[frame]
                                // The middle of the ring's band: halfway between the inner (0.62) and the outer radius.
                                let radius = min(rect.width, rect.height) / 2 * 0.81
                                ForEach(Self.percentLabels(slices, total: total)) { label in
                                    Text(label.text)
                                        .font(.caption.weight(.semibold)).foregroundStyle(Color.white)
                                        .position(x: rect.midX + radius * sin(label.angle), y: rect.midY - radius * cos(label.angle))
                                }
                            }
                        }
                    }
                    .overlay {
                        VStack(spacing: 2) {
                            Text("Всего").font(.caption).foregroundStyle(.secondary)
                            Text(reportWholeRubles(headline))
                                .font(.title3.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
            }.glassRows()
        }
        ReportSliceList(browser: browser, presentation: presentation, interval: interval, mode: mode, grouping: grouping, slices: slices, total: total, headline: headline,
                        refundsKopecks: mode == .expenses && !filter.isActive ? report.refundsKopecks : 0, filter: filter)
        if mode == .expenses && !filter.isActive && filter.scope.isAll && needsCategoryReview(report) {
            let groups = QuickReviewCache.groups(browser.history, presentation: presentation)
            if !groups.isEmpty {
                Section {
                    NavigationLink {
                        UncategorizedReviewView(browser: browser, presentation: presentation)
                    } label: {
                        Text("Разобрать «Прочее»: \(groups.count) получателей").foregroundStyle(.primary)
                    }
                }.glassRows()
            }
        }
        if !filter.isActive { separateSection(report) }
    }

    private func needsCategoryReview(_ report: FinanceReport) -> Bool {
        guard report.grossExpenseKopecks > 0,
              let category = browser.history.expenseCategory(id: UncategorizedReview.otherExpenseID),
              let group = report.expenseLines.first(where: { $0.title == category.group.name }),
              let other = group.children.first(where: { $0.title == category.category.name }) else { return false }
        return Double(other.amountKopecks) / Double(report.grossExpenseKopecks) > 0.1
    }

    /// A percentage on a sector: the angle of its middle, clockwise from the top. Small sectors have no label.
    private struct PercentLabel: Identifiable {
        let id: String
        let text: String
        let angle: Double
    }

    private static func percentLabels(_ slices: [ReportSlice], total: Int64) -> [PercentLabel] {
        var labels: [PercentLabel] = []
        var passed: Int64 = 0
        for slice in slices {
            let share = Double(slice.amountKopecks) / Double(total)
            if share >= 0.05 {
                let middle = (Double(passed) + Double(slice.amountKopecks) / 2) / Double(total)
                labels.append(PercentLabel(id: slice.id, text: share.formatted(.percent.precision(.fractionLength(0))), angle: middle * 2 * Double.pi))
            }
            passed += slice.amountKopecks
        }
        return labels
    }

    /// What the report keeps out of the total: transfers between own accounts, Split and operations not finished yet.
    private struct SeparateLine: Identifiable {
        let title: String
        let amount: Int64
        let selection: FinanceOperationSelection?
        var id: String { title }
    }

    private func separateLines(_ report: FinanceReport) -> [SeparateLine] {
        var lines: [SeparateLine] = []
        for line in report.movementLines {
            lines.append(SeparateLine(title: line.title, amount: line.amountKopecks, selection: .movement(subcategory: line.title)))
        }
        for line in report.expenseLines where line.title == "Сплит" {
            lines.append(SeparateLine(title: "Сплит", amount: line.amountKopecks, selection: .split))
        }
        for line in report.incompleteLines {
            // «Не определено» opens the operations behind it: there each one can be named.
            lines.append(SeparateLine(title: line.title, amount: line.amountKopecks,
                                      selection: line.title == FinancialType.unknown.title ? .unknownIncoming : nil))
        }
        return lines
    }

    @ViewBuilder private func separateSection(_ report: FinanceReport) -> some View {
        let lines = separateLines(report)
        if !lines.isEmpty {
            Section("Не входит в итог") {
                ForEach(lines) { line in
                    if let selection = line.selection {
                        NavigationLink {
                            FinanceCategoryOperationsView(browser: browser, interval: interval, selection: selection)
                        } label: { separateRow(line.title, line.amount) }
                    } else {
                        separateRow(line.title, line.amount)
                    }
                }
                Text("Переводы между своими счетами, Сплит и операции в обработке не считаются ни доходом, ни расходом.")
                    .font(.caption).foregroundStyle(.secondary)
            }.glassRows()
        }
    }

    private func separateRow(_ title: String, _ amount: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(reportRubles(amount)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// The list under the ring and under the dynamics chart: the total and a row with a bar for every group.
private struct ReportSliceList: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    let interval: DateInterval
    let mode: ReportMode
    let grouping: ReportGrouping
    let slices: [ReportSlice]
    /// The sum of the groups: the base of the percentages and of the bars.
    let total: Int64
    /// The figure of the «all» row: the same as the centre of the ring (expenses are net of refunds).
    let headline: Int64
    let refundsKopecks: Int64
    let filter: ReportFilter

    static func compute(browser: BankBrowser, presentation: FinancePresentationCache, interval: DateInterval,
                        mode: ReportMode, grouping: ReportGrouping, filter: ReportFilter) -> [ReportSlice] {
        // The history may have been loaded after this view was first built: never read a cache of the old one.
        presentation.prepare(browser.history)
        return presentation.value("slices:\(mode.rawValue):\(grouping.rawValue):\(interval.start):\(interval.end):\(filter.cacheKey)") {
            ReportEngine.slices(presentation.inputs(browser.history, scope: filter.scope), in: interval, mode: mode, grouping: grouping,
                                taxonomy: browser.history.expenseTaxonomy, filter: filter)
        }
    }

    var body: some View {
        if !slices.isEmpty {
            Section {
                NavigationLink {
                    FinanceCategoryOperationsView(browser: browser, interval: interval,
                                                  selection: mode == .expenses ? .allExpenses : .allIncome, filter: filter)
                } label: {
                    VStack(spacing: 6) {
                        HStack {
                            Image(systemName: "sum").foregroundStyle(.secondary).frame(width: 28)
                            Text(mode == .expenses ? "Все расходы" : "Все доходы").font(.headline)
                            Spacer()
                            Text(reportRubles(headline)).font(.headline).monospacedDigit()
                        }
                        ShareBar(fraction: 1, color: .accentColor)
                    }
                }
                ForEach(slices) { slice in
                    NavigationLink {
                        ReportDetailView(browser: browser, presentation: presentation, interval: interval, mode: mode, grouping: grouping, slice: slice, filter: filter)
                    } label: {
                        VStack(spacing: 6) {
                            HStack {
                                Circle().fill(ReportPalette.color(slice.title)).frame(width: 12, height: 12).frame(width: 28)
                                Text(slice.title).lineLimit(1)
                                Spacer()
                                Text(percent(slice.amountKopecks)).font(.caption).foregroundStyle(.secondary)
                                Text(reportRubles(slice.amountKopecks)).monospacedDigit()
                            }
                            ShareBar(fraction: total > 0 ? Double(slice.amountKopecks) / Double(total) : 0, color: ReportPalette.color(slice.title))
                        }
                    }
                }
                if refundsKopecks > 0 {
                    HStack {
                        Image(systemName: "arrow.uturn.backward").foregroundStyle(.green).frame(width: 28)
                        Text("Возвраты")
                        Spacer()
                        Text("−" + reportRubles(refundsKopecks)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text("Возвраты уменьшают итог расходов.").font(.caption).foregroundStyle(.secondary)
                }
            }.glassRows()
        }
    }

    private func percent(_ amount: Int64) -> String {
        guard total > 0 else { return "" }
        return (Double(amount) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct ShareBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(4, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Details of a group

/// One group: its dynamics, its subcategories and its operations.
private struct ReportDetailView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    let interval: DateInterval
    let mode: ReportMode
    let grouping: ReportGrouping
    let slice: ReportSlice
    let filter: ReportFilter
    @State private var stepChoice: ReportStep = .automatic

    private var selection: FinanceOperationSelection {
        switch grouping {
        case .categories: return mode == .expenses ? .expenseGroup(slice.title) : .income(subcategory: slice.title)
        case .payees: return .payee(key: slice.id, income: mode == .income, title: slice.title)
        }
    }

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let step = ReportEngine.step(stepChoice, for: interval)
        let buckets = ReportEngine.buckets(interval, step: step)
        let bars = presentation.value("detail-bars:\(mode.rawValue):\(grouping.rawValue):\(slice.id):\(interval.start):\(interval.end):\(step.rawValue):\(filter.cacheKey)") {
            ReportEngine.bars(presentation.inputs(browser.history, scope: filter.scope), buckets: buckets, mode: mode, grouping: grouping, focus: slice.id, filter: filter)
        }
        List {
            Section {
                HStack {
                    Text("Динамика").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Шаг", selection: $stepChoice) {
                        Text("Авто").tag(ReportStep.automatic)
                        Text("Дни").tag(ReportStep.day)
                        Text("Недели").tag(ReportStep.week)
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 220)
                }
                StackedBarsChart(bars: bars, buckets: buckets, step: step, singleColor: ReportPalette.color(slice.title))
            }.glassRows()
            Section {
                NavigationLink {
                    FinanceCategoryOperationsView(browser: browser, interval: interval, selection: selection, filter: filter)
                } label: {
                    HStack {
                        Image(systemName: "sum").foregroundStyle(.secondary).frame(width: 28)
                        Text(mode == .expenses ? "Все расходы" : "Все доходы").font(.headline)
                        Spacer()
                        Text(reportRubles(slice.amountKopecks)).font(.headline).monospacedDigit()
                    }
                }
                ForEach(slice.children) { child in
                    NavigationLink {
                        FinanceCategoryOperationsView(browser: browser, interval: interval,
                                                      selection: .expense(group: slice.title, subcategory: child.title), filter: filter)
                    } label: {
                        HStack {
                            Circle().fill(ReportPalette.color(slice.title).opacity(0.7)).frame(width: 12, height: 12).frame(width: 28)
                            Text(child.title).lineLimit(1)
                            Spacer()
                            Text(reportRubles(child.amountKopecks)).monospacedDigit()
                        }
                    }
                }
            }.glassRows()
        }
        .appSurface()
        .navigationTitle(slice.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Dynamics

private struct StackedBarsChart: View {
    let bars: [ReportBar]
    let buckets: [DateInterval]
    let step: ReportStep
    /// A single series (the details of one group): drawn in this colour.
    var singleColor: Color?

    private var keys: [String] { buckets.map { Self.key($0.start) } }

    static func key(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }

    private func label(_ bucket: DateInterval) -> String {
        step == .month ? bucket.start.formatted(.dateTime.month(.abbreviated)) : bucket.start.formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        let labels = Dictionary(uniqueKeysWithValues: buckets.map { (Self.key($0.start), label($0)) })
        let every = max(1, Int((Double(buckets.count) / 6).rounded(.up)))
        let shownKeys = keys.enumerated().filter { $0.offset % every == 0 }.map(\.element)
        Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Период", Self.key(bar.bucket.start)), y: .value("Сумма", Double(bar.amountKopecks) / 100))
                    .foregroundStyle(singleColor ?? ReportPalette.color(bar.label))
                    .cornerRadius(2)
            }
            // An invisible mark per bucket keeps every bucket on the axis, with or without operations.
            ForEach(keys, id: \.self) { key in
                BarMark(x: .value("Период", key), y: .value("Сумма", 0)).opacity(0)
            }
        }
        .chartXScale(domain: keys)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: shownKeys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let text = labels[key] { Text(text).font(.caption2).lineLimit(1).fixedSize() }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                AxisValueLabel {
                    if let rubles = value.as(Double.self) { Text(shortAmount(rubles)).font(.caption2) }
                }
            }
        }
        .frame(height: 220)
        .overlay {
            if bars.isEmpty { Text("Нет операций").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

private struct DynamicsContent: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    let interval: DateInterval
    let mode: ReportMode
    let grouping: ReportGrouping
    let buckets: [DateInterval]
    let step: ReportStep
    let filter: ReportFilter

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let bars = presentation.value("bars:\(mode.rawValue):\(grouping.rawValue):\(interval.start):\(interval.end):\(step.rawValue):\(filter.cacheKey)") {
            ReportEngine.bars(presentation.inputs(browser.history, scope: filter.scope), buckets: buckets, mode: mode, grouping: grouping, filter: filter)
        }
        Section {
            StackedBarsChart(bars: bars, buckets: buckets, step: step)
        }.glassRows()
        let slices = ReportSliceList.compute(browser: browser, presentation: presentation, interval: interval, mode: mode, grouping: grouping, filter: filter)
        let report = presentation.report(browser.history, interval: interval, scope: filter.scope)
        let total = slices.reduce(Int64(0)) { $0 + $1.amountKopecks }
        ReportSliceList(browser: browser, presentation: presentation, interval: interval, mode: mode, grouping: grouping, slices: slices,
                        total: total, headline: mode == .expenses && !filter.isActive ? report.netExpenseKopecks : total,
                        refundsKopecks: mode == .expenses && !filter.isActive ? report.refundsKopecks : 0, filter: filter)
    }
}

// MARK: - Balances

private struct BalancesContent: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    let interval: DateInterval
    let buckets: [DateInterval]
    let step: ReportStep
    let perAccount: Bool
    /// Under «All accounts» the accounts of the reserve: the last figure of the forecast is then the reserve at the end
    /// of the month, the same number as on the main screen (money put aside is not counted). Otherwise the chosen ones.
    let accounts: [Account]
    /// A chosen account or group: the forecast is made for the reserve as a whole, so these balances end today.
    let isScoped: Bool

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let accounts = self.accounts
        // The days to come: today's balance moves to the balance expected at the end of the month.
        let change: Int64? = isScoped ? nil : FinancialEngine.monthReserve(balanceKopecks: 0, forecast: presentation.forecast(browser.history))
        let points = ReportEngine.balances(browser.history, accounts: accounts, buckets: buckets, forecastChangeKopecks: change)
        let facts = points.filter { $0.hasData && !$0.isForecast }
        let forecast = points.filter { $0.hasData && $0.isForecast }
        if accounts.isEmpty {
            Section {
                ContentUnavailableView(isScoped ? "В группе нет счетов" : "Нет счетов в запасе", systemImage: "wallet.pass",
                                       description: Text(isScoped ? "Выберите другой счёт или группу в меню рядом с периодом."
                                                                  : "Добавьте счета в панели «Счета» или включите их в настройке запаса."))
            }.glassRows()
        } else {
            Section {
                Chart {
                    if perAccount {
                        ForEach(accounts) { account in
                            ForEach(points.filter { $0.byAccount[account.id] != nil }) { point in
                                LineMark(x: .value("Дата", point.bucket.end.addingTimeInterval(-1)),
                                         y: .value("Остаток", Double(point.byAccount[account.id] ?? 0) / 100),
                                         series: .value("Счёт", account.name))
                                    .foregroundStyle(accountColor(account.color))
                                    .interpolationMethod(.monotone)
                            }
                        }
                    } else {
                        ForEach(facts) { point in
                            AreaMark(x: .value("Дата", point.bucket.end.addingTimeInterval(-1)), y: .value("Остаток", Double(point.totalKopecks) / 100),
                                     series: .value("Вид", "Факт"))
                                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Дата", point.bucket.end.addingTimeInterval(-1)), y: .value("Остаток", Double(point.totalKopecks) / 100),
                                     series: .value("Вид", "Факт"))
                                .foregroundStyle(Color.accentColor)
                                .interpolationMethod(.monotone)
                        }
                        // The forecast starts from the last fact so that the line does not break.
                        ForEach(Array(facts.suffix(1)) + forecast) { point in
                            LineMark(x: .value("Дата", point.bucket.end.addingTimeInterval(-1)), y: .value("Остаток", Double(point.totalKopecks) / 100),
                                     series: .value("Вид", "Прогноз"))
                                .foregroundStyle(Color.accentColor)
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartXScale(domain: interval.start...interval.end)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        AxisValueLabel { if let rubles = value.as(Double.self) { Text(shortAmount(rubles)).font(.caption2) } }
                    }
                }
                .frame(height: 240)
                .overlay {
                    if !points.contains(where: { $0.hasData || !$0.byAccount.isEmpty }) {
                        Text("Нет данных об остатке").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if perAccount {
                    HStack(spacing: 12) {
                        ForEach(accounts) { account in
                            HStack(spacing: 4) {
                                Circle().fill(accountColor(account.color)).frame(width: 8, height: 8)
                                Text(account.name).font(.caption2).lineLimit(1)
                            }
                        }
                    }
                }
            }.glassRows()
            Section("Остаток на конец периода") {
                ForEach(points.filter(\.hasData)) { point in
                    HStack {
                        Text(rowTitle(point.bucket) + (point.isForecast ? " · прогноз" : ""))
                        Spacer()
                        Text(reportRubles(point.totalKopecks)).monospacedDigit()
                            .foregroundStyle(point.isForecast ? Color.secondary : Color.primary)
                    }
                }
                if points.contains(where: { !$0.hasData && !$0.isForecast }) {
                    Text("Общий остаток показан там, где известны все счета. По счетам, которые заведены позже, прошлых остатков нет: режим «По счетам» показывает каждый счёт с даты, с которой он известен.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Остаток по счетам запаса, без отложенных денег. Дни после сегодняшнего — прогноз: ожидаемые расходы и доходы месяца; на конец месяца он равен запасу на экране «Операции».")
                    .font(.caption).foregroundStyle(.secondary)
            }.glassRows()
        }
    }

    private func rowTitle(_ bucket: DateInterval) -> String {
        bucket.end.addingTimeInterval(-1).formatted(date: .long, time: .omitted)
    }
}

// MARK: - Income and expenses

private struct FlowContent: View {
    let presentation: FinancePresentationCache
    @ObservedObject var browser: BankBrowser
    let interval: DateInterval
    let buckets: [DateInterval]
    let step: ReportStep
    let filter: ReportFilter

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let points = presentation.value("flow:\(interval.start):\(interval.end):\(step.rawValue):\(filter.cacheKey)") {
            ReportEngine.flow(presentation.inputs(browser.history, scope: filter.scope), buckets: buckets, filter: filter)
        }
        let income = points.reduce(Int64(0)) { $0 + $1.incomeKopecks }
        let expense = points.reduce(Int64(0)) { $0 + $1.expenseKopecks }
        Section {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Дата", point.bucket.start), y: .value("Сумма", Double(point.incomeKopecks) / 100), series: .value("Вид", "Доходы"))
                        .foregroundStyle(.green).interpolationMethod(.monotone)
                    LineMark(x: .value("Дата", point.bucket.start), y: .value("Сумма", Double(max(0, point.expenseKopecks)) / 100), series: .value("Вид", "Расходы"))
                        .foregroundStyle(Color.primary.opacity(0.7)).interpolationMethod(.monotone)
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: interval.start...interval.end)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    AxisValueLabel { if let rubles = value.as(Double.self) { Text(shortAmount(rubles)).font(.caption2) } }
                }
            }
            .frame(height: 220)
            HStack(spacing: 16) {
                Label("Доходы", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
                Label("Расходы", systemImage: "circle.fill").foregroundStyle(Color.primary.opacity(0.7)).font(.caption)
            }
        }.glassRows()
        Section {
            flowRow("Всего", income: income, expense: expense, bold: true)
            ForEach(points) { point in
                flowRow(title(point.bucket), income: point.incomeKopecks, expense: point.expenseKopecks, bold: false)
            }
            Text(income >= expense ? "За период получается откладывать: доходы больше расходов." : "За период расходы обгоняют доходы.")
                .font(.caption).foregroundStyle(.secondary)
        }.glassRows()
    }

    private func title(_ bucket: DateInterval) -> String {
        let last = bucket.end.addingTimeInterval(-1)
        if Calendar.current.isDate(bucket.start, inSameDayAs: last) { return bucket.start.formatted(.dateTime.day().month(.wide)) }
        return bucket.start.formatted(.dateTime.day().month(.abbreviated)) + " – " + last.formatted(.dateTime.day().month(.abbreviated))
    }

    private func flowRow(_ title: String, income: Int64, expense: Int64, bold: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(bold ? .headline : .body)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("+ " + reportRubles(income)).foregroundStyle(income == 0 ? Color.secondary : Color.green)
                Text("− " + reportRubles(expense)).foregroundStyle(expense == 0 ? Color.secondary : Color.primary)
            }
            .font(bold ? .headline : .subheadline).monospacedDigit()
        }
    }
}

// MARK: - Period sheet

private struct ReportPeriodSheet: View {
    @Binding var period: ReportPeriod
    let first: Date?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var ink: Color { scheme == .dark ? Color.white : Color.primary }
    @State private var from = Date()
    @State private var through = Date()
    @State private var choosingDates = false

    private var years: [Int] {
        let months = ReportPeriod.months(from: first)
        let all = Set(months.map { Calendar.current.component(.year, from: $0) })
        return all.sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach([7, 14, 30, 90, 365], id: \.self) { days in
                        Button { choose(.lastDays(days)) } label: {
                            Label("Последние \(days) дн.", systemImage: "calendar").foregroundStyle(ink)
                        }
                    }
                    Button { choosingDates = true } label: { Label("Выбрать даты", systemImage: "calendar.badge.clock").foregroundStyle(ink) }
                    Button { choose(.allHistory) } label: { Label("Вся история", systemImage: "infinity").foregroundStyle(ink) }
                    if let first {
                        Text("История с " + first.formatted(.dateTime.month(.wide).year())).font(.caption).foregroundStyle(.secondary)
                    }
                }.glassRows()
                ForEach(years, id: \.self) { year in
                    Section {
                        ForEach(months(of: year), id: \.self) { month in
                            Button { choose(.month(month)) } label: {
                                HStack {
                                    Text(month.formatted(.dateTime.month(.wide)).capitalized).foregroundStyle(ink)
                                    Spacer()
                                    if period == .month(month) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(String(year))
                            Spacer()
                            Button("Весь год") { choose(.year(Calendar.current.date(from: DateComponents(year: year))!)) }
                                .font(.caption).textCase(nil).foregroundStyle(ink)
                        }
                    }.glassRows()
                }
            }
            .appSurface()
            .navigationTitle("Период")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть", systemImage: "xmark") { dismiss() } } }
            .sheet(isPresented: $choosingDates) {
                NavigationStack {
                    Form {
                        DatePicker("С", selection: $from, in: ...Date(), displayedComponents: .date)
                        DatePicker("По", selection: $through, in: ...Date(), displayedComponents: .date)
                    }
                    .appSurface()
                    .navigationTitle("Выбрать даты")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Отмена", systemImage: "xmark") { choosingDates = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Готово", systemImage: "checkmark") {
                                choosingDates = false
                                choose(.custom(from: from, through: through))
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func months(of year: Int) -> [Date] {
        ReportPeriod.months(from: first).filter { Calendar.current.component(.year, from: $0) == year }
    }

    private func choose(_ new: ReportPeriod) {
        period = new
        dismiss()
    }
}
