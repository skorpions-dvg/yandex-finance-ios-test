import Foundation

// Data for the reports (Структура, Динамика, Остатки, Доходы и расходы). No UI here: everything is checked by tests on
// the PC. Amounts come from the same classification as the rest of the app; nothing is classified again.

enum ReportMode: String, CaseIterable, Identifiable {
    case expenses, income
    var id: String { rawValue }
    var title: String { self == .expenses ? "Расходы" : "Доходы" }
}

enum ReportGrouping: String, CaseIterable, Identifiable {
    case categories, payees
    var id: String { rawValue }
    var title: String { self == .categories ? "Категории" : "Получатели" }
}

enum ReportStep: String, CaseIterable, Identifiable {
    case automatic, day, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Автоматически"
        case .day: return "Дни"
        case .week: return "Недели"
        case .month: return "Месяцы"
        }
    }
}

/// What the reports show: a month, a year, the last days, own dates or everything.
enum ReportPeriod: Equatable {
    case month(Date)
    case year(Date)
    case lastDays(Int)
    case custom(from: Date, through: Date)
    case allHistory

    /// The days covered, today included for «last days» and «all history».
    func interval(now: Date = Date(), firstDate: Date? = nil, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        switch self {
        case .month(let date):
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
            return DateInterval(start: start, end: calendar.date(byAdding: .month, value: 1, to: start)!)
        case .year(let date):
            let start = calendar.date(from: calendar.dateComponents([.year], from: date))!
            // The current year ends with the current month: months that have not come yet are not shown.
            let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            let untilNow = calendar.date(byAdding: .month, value: 1, to: thisMonth)!
            let yearEnd = calendar.date(byAdding: .year, value: 1, to: start)!
            return DateInterval(start: start, end: max(start, min(yearEnd, untilNow)))
        case .lastDays(let days):
            return DateInterval(start: calendar.date(byAdding: .day, value: -max(1, days), to: tomorrow)!, end: tomorrow)
        case .custom(let from, let through):
            let first = calendar.startOfDay(for: min(from, through))
            let last = calendar.startOfDay(for: max(from, through))
            return DateInterval(start: first, end: calendar.date(byAdding: .day, value: 1, to: last)!)
        case .allHistory:
            let start = calendar.startOfDay(for: firstDate ?? today)
            return DateInterval(start: min(start, today), end: tomorrow)
        }
    }

    /// Months from the one of the first operation to the current one, oldest first.
    static func months(from first: Date?, now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let current = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        guard let first else { return [current] }
        var month = calendar.date(from: calendar.dateComponents([.year, .month], from: min(first, now)))!
        var result: [Date] = []
        while month <= current {
            result.append(month)
            month = calendar.date(byAdding: .month, value: 1, to: month)!
        }
        return result
    }
}

/// The share of one group of operations (a category, a payee) in the shown total.
struct ReportSlice: Identifiable, Equatable {
    let id: String
    let title: String
    let amountKopecks: Int64
    let count: Int
    /// Subcategories (empty for payees and income).
    let children: [ReportSlice]
}

struct ReportBar: Identifiable, Equatable {
    let bucket: DateInterval
    let label: String
    let amountKopecks: Int64
    var id: String { "\(bucket.start.timeIntervalSince1970)|\(label)" }
}

struct ReportFlowPoint: Identifiable, Equatable {
    let bucket: DateInterval
    let incomeKopecks: Int64
    let expenseKopecks: Int64
    var id: Date { bucket.start }
    var netKopecks: Int64 { incomeKopecks - expenseKopecks }
}

struct ReportBalancePoint: Identifiable, Equatable {
    /// The last day of the bucket: the balance is shown at its end.
    let bucket: DateInterval
    let totalKopecks: Int64
    let byAccount: [UUID: Int64]
    var id: Date { bucket.start }
}

enum ReportEngine {
    // MARK: Steps

    /// «Автоматически»: days for up to six weeks, weeks for up to five months, months beyond that.
    static func step(_ choice: ReportStep, for interval: DateInterval, calendar: Calendar = .current) -> ReportStep {
        let days = max(1, calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1)
        var step = choice
        if step == .automatic { step = days <= 45 ? .day : (days <= 150 ? .week : .month) }
        // A step that would give too many bars falls back to a coarser one.
        if step == .day && days > 120 { step = days > 700 ? .month : .week }
        if step == .week && days > 800 { step = .month }
        return step
    }

    /// Consecutive buckets that exactly cover `interval`: days, 7-day blocks from its start, or calendar months.
    static func buckets(_ interval: DateInterval, step: ReportStep, calendar: Calendar = .current) -> [DateInterval] {
        let unit = step == .automatic ? self.step(.automatic, for: interval, calendar: calendar) : step
        var result: [DateInterval] = []
        var start = interval.start
        while start < interval.end {
            let next: Date
            switch unit {
            case .day, .automatic:
                next = calendar.date(byAdding: .day, value: 1, to: start)!
            case .week:
                next = calendar.date(byAdding: .day, value: 7, to: start)!
            case .month:
                let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: start))!
                next = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            }
            let end = min(next, interval.end)
            result.append(DateInterval(start: start, end: end))
            start = end
        }
        return result
    }

    /// Drops the buckets that end before the first operation, so balances and income/expenses start where the history does.
    /// Nothing is dropped without a known first date or when it would drop everything.
    static func trimmed(_ buckets: [DateInterval], from first: Date?) -> [DateInterval] {
        guard let first else { return buckets }
        let kept = Array(buckets.drop(while: { $0.end <= first }))
        return kept.isEmpty ? buckets : kept
    }

    // MARK: Structure

    private static func date(_ input: FinancialOperationInput) -> Date? { BankDateParser.parse(input.occurredAt) }

    /// One classified operation of the mode, or nil when it does not belong to it.
    private static func entry(_ input: FinancialOperationInput, mode: ReportMode)
        -> (group: String, sub: String, payee: String, title: String, amount: Int64)? {
        let assessment = FinancialEngine.classify(input)
        switch mode {
        case .expenses:
            guard assessment.type == .expense || assessment.type == .commission, assessment.expenseContributionKopecks > 0 else { return nil }
            let path = FinancialEngine.expenseCategory(for: input, assessment: assessment)
            return (path.group, path.subcategory, FinancialEngine.payeeRuleKey(input.description), input.description,
                    assessment.expenseContributionKopecks)
        case .income:
            guard assessment.type == .income || assessment.type == .interestIncome, assessment.incomeContributionKopecks > 0 else { return nil }
            let category = FinancialEngine.incomeCategory(for: input, assessment: assessment)
            return (category, category, FinancialEngine.payeeRuleKey(input.description), input.description,
                    assessment.incomeContributionKopecks)
        }
    }

    /// The groups of the shown total, the largest first. Expenses by category have subcategories inside; the order of
    /// equal amounts follows the user's tree so that the list does not shuffle.
    static func slices(_ inputs: [FinancialOperationInput], in interval: DateInterval, mode: ReportMode,
                       grouping: ReportGrouping, taxonomy: ExpenseTaxonomy) -> [ReportSlice] {
        var groups: [String: (title: String, amount: Int64, count: Int, subs: [String: (Int64, Int)])] = [:]
        for input in inputs {
            guard let when = date(input), when >= interval.start, when < interval.end,
                  let item = entry(input, mode: mode) else { continue }
            let key: String
            let title: String
            switch grouping {
            case .categories: key = item.group; title = item.group
            case .payees: key = item.payee.isEmpty ? "—" : item.payee; title = item.payee.isEmpty ? "Без названия" : item.title
            }
            var entry = groups[key] ?? (title, 0, 0, [:])
            entry.amount += item.amount
            entry.count += 1
            if grouping == .categories && mode == .expenses {
                var sub = entry.subs[item.sub] ?? (0, 0)
                sub.0 += item.amount; sub.1 += 1
                entry.subs[item.sub] = sub
            }
            groups[key] = entry
        }
        let order = taxonomy.groupNames
        let subOrder = taxonomy.subcategoryOrder
        return groups.map { key, value in
            let children = value.subs.map { ReportSlice(id: key + "/" + $0.key, title: $0.key, amountKopecks: $0.value.0, count: $0.value.1, children: []) }
                .sorted { lhs, rhs in
                    if lhs.amountKopecks != rhs.amountKopecks { return lhs.amountKopecks > rhs.amountKopecks }
                    return (subOrder.firstIndex(of: lhs.title) ?? Int.max) < (subOrder.firstIndex(of: rhs.title) ?? Int.max)
                }
            return ReportSlice(id: key, title: value.title, amountKopecks: value.amount, count: value.count, children: children)
        }.sorted { lhs, rhs in
            if lhs.amountKopecks != rhs.amountKopecks { return lhs.amountKopecks > rhs.amountKopecks }
            let left = order.firstIndex(of: lhs.title) ?? Int.max, right = order.firstIndex(of: rhs.title) ?? Int.max
            return left == right ? lhs.title < rhs.title : left < right
        }
    }

    // MARK: Dynamics

    /// Stacked bars: each bucket split by group (or, with `focus`, one group split by its subcategories; for payees
    /// the focused payee as one series). Buckets without operations are present with no bars, so the axis never shifts.
    static func bars(_ inputs: [FinancialOperationInput], buckets: [DateInterval], mode: ReportMode,
                     grouping: ReportGrouping, focus: String? = nil) -> [ReportBar] {
        guard let first = buckets.first?.start, let last = buckets.last?.end else { return [] }
        var sums: [Int: [String: Int64]] = [:]
        for input in inputs {
            guard let when = date(input), when >= first, when < last, let item = entry(input, mode: mode) else { continue }
            let owner = grouping == .categories ? item.group : (item.payee.isEmpty ? "—" : item.payee)
            if let focus, owner != focus { continue }
            let label = focus == nil ? (grouping == .categories ? item.group : (item.payee.isEmpty ? "Без названия" : item.title))
                                     : (grouping == .categories ? item.sub : item.title)
            guard let index = bucketIndex(of: when, in: buckets) else { continue }
            sums[index, default: [:]][label, default: 0] += item.amount
        }
        var result: [ReportBar] = []
        for (index, bucket) in buckets.enumerated() {
            for (name, amount) in (sums[index] ?? [:]).sorted(by: { $0.key < $1.key }) {
                result.append(ReportBar(bucket: bucket, label: name, amountKopecks: amount))
            }
        }
        return result
    }

    /// Total of each bucket, for the axis scale and the empty buckets.
    static func totals(_ bars: [ReportBar], buckets: [DateInterval]) -> [Int64] {
        var sums = [Int64](repeating: 0, count: buckets.count)
        let indexByStart = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { ($1.start, $0) })
        for bar in bars { if let index = indexByStart[bar.bucket.start] { sums[index] += bar.amountKopecks } }
        return sums
    }

    private static func bucketIndex(of date: Date, in buckets: [DateInterval]) -> Int? {
        var low = 0, high = buckets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if date < buckets[mid].start { high = mid - 1 }
            else if date >= buckets[mid].end { low = mid + 1 }
            else { return mid }
        }
        return nil
    }

    // MARK: Income and expenses

    /// Income and net expense (refunds taken off) of every bucket.
    static func flow(_ inputs: [FinancialOperationInput], buckets: [DateInterval]) -> [ReportFlowPoint] {
        guard let first = buckets.first?.start, let last = buckets.last?.end else { return [] }
        var income = [Int64](repeating: 0, count: buckets.count)
        var expense = [Int64](repeating: 0, count: buckets.count)
        for input in inputs {
            guard let when = date(input), when >= first, when < last, let index = bucketIndex(of: when, in: buckets) else { continue }
            let assessment = FinancialEngine.classify(input)
            income[index] += assessment.incomeContributionKopecks
            expense[index] += assessment.expenseContributionKopecks - assessment.refundContributionKopecks
        }
        return buckets.enumerated().map { ReportFlowPoint(bucket: $1, incomeKopecks: income[$0], expenseKopecks: expense[$0]) }
    }

    // MARK: Balances

    /// The balance of the accounts at the end of every bucket, in total and per account.
    static func balances(_ history: SavedHistory, accounts: [Account], buckets: [DateInterval]) -> [ReportBalancePoint] {
        let moments = buckets.map(\.end)
        var perAccount: [[Int64]] = []
        for account in accounts { perAccount.append(history.accountBalances(account, at: moments)) }
        return buckets.enumerated().map { index, bucket in
            var byAccount: [UUID: Int64] = [:]
            var total: Int64 = 0
            for (accountIndex, account) in accounts.enumerated() {
                let value = perAccount[accountIndex][index]
                byAccount[account.id] = value
                total += value
            }
            return ReportBalancePoint(bucket: bucket, totalKopecks: total, byAccount: byAccount)
        }
    }
}
