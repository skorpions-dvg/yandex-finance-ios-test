import Foundation

/// How a budget stands: calm up to 90 % of the limit, a warning from 90 % to the limit, exceeded above it.
enum BudgetLevel: Equatable {
    case calm, warning, exceeded
}

/// One limit of a month with what has been spent against it.
struct BudgetStatus: Identifiable, Equatable {
    /// A group name of the user's tree; nil: the whole month.
    let group: String?
    let limitKopecks: Int64
    let spentKopecks: Int64
    /// The limit was set for this month only (not for every month).
    let isMonthOnly: Bool

    var id: String { group ?? "—month" }
    var remainingKopecks: Int64 { limitKopecks - spentKopecks }
    var fraction: Double { limitKopecks > 0 ? Double(spentKopecks) / Double(limitKopecks) : 0 }
    /// Whole percent spent, rounded down (99.9 % is still 99 %).
    var percent: Int { limitKopecks > 0 ? Int(max(0, spentKopecks) * 100 / limitKopecks) : 0 }
    var level: BudgetLevel { BudgetEngine.level(spent: spentKopecks, limit: limitKopecks) }
}

/// A line for the main screen: which groups have used up their limit or are about to.
struct BudgetNotice: Identifiable, Equatable {
    let level: BudgetLevel
    let text: String
    var id: String { text }
}

enum BudgetEngine {
    /// The groups over their limit, then the groups from 90 % of it. The limit of the whole month is shown by its own bar.
    static func notices(_ statuses: [BudgetStatus]) -> [BudgetNotice] {
        let groups = statuses.filter { $0.group != nil }
        var result: [BudgetNotice] = []
        let exceeded = groups.filter { $0.level == .exceeded }.compactMap(\.group)
        let warning = groups.filter { $0.level == .warning }.compactMap(\.group)
        if !exceeded.isEmpty { result.append(BudgetNotice(level: .exceeded, text: "Превышен бюджет: " + exceeded.joined(separator: ", "))) }
        if !warning.isEmpty { result.append(BudgetNotice(level: .warning, text: "Почти исчерпан бюджет: " + warning.joined(separator: ", "))) }
        return result
    }

    static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func monthInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// Spent against a limit: up to 90 % calm, from 90 % up to and including the limit a warning, above it exceeded.
    static func level(spent: Int64, limit: Int64) -> BudgetLevel {
        guard limit > 0 else { return .calm }
        if spent > limit { return .exceeded }
        return spent * 10 >= limit * 9 ? .warning : .calm
    }

    /// The limit that holds in a month: the limit of that month, or else the one of every month.
    static func limit(_ budgets: [Budget], group: String?, monthKey: String) -> (limitKopecks: Int64, isMonthOnly: Bool)? {
        let ofGroup = budgets.filter { $0.group == group && $0.limitKopecks > 0 }
        if let own = ofGroup.first(where: { $0.month == monthKey }) { return (own.limitKopecks, true) }
        if let general = ofGroup.first(where: { $0.month == nil }) { return (general.limitKopecks, false) }
        return nil
    }

    /// The limits of the month with what is spent against each: the whole month first, then the groups in the order of
    /// the user's tree (groups that are no longer in the tree last, by name). Expenses are counted as in the reports:
    /// the whole month net of refunds, a group as its purchases.
    static func statuses(inputs: [FinancialOperationInput], budgets: [Budget], month: Date, taxonomy: ExpenseTaxonomy,
                         calendar: Calendar = .current) -> [BudgetStatus] {
        let key = monthKey(month, calendar: calendar)
        let names = Set(budgets.filter { $0.month == nil || $0.month == key }.map(\.group))
        guard !names.isEmpty else { return [] }
        let interval = monthInterval(containing: month, calendar: calendar)
        let spentByGroup = Dictionary(
            ReportEngine.slices(inputs, in: interval, mode: .expenses, grouping: .categories, taxonomy: taxonomy)
                .map { ($0.title, $0.amountKopecks) },
            uniquingKeysWith: +)
        let order = taxonomy.groupNames
        let groups = names.compactMap { $0 }.sorted { left, right in
            let l = order.firstIndex(of: left) ?? Int.max, r = order.firstIndex(of: right) ?? Int.max
            return l == r ? left < right : l < r
        }
        var result: [BudgetStatus] = []
        if names.contains(nil), let held = limit(budgets, group: nil, monthKey: key) {
            let spent = FinancialEngine.report(inputs, in: interval, taxonomy: taxonomy).netExpenseKopecks
            result.append(BudgetStatus(group: nil, limitKopecks: held.limitKopecks, spentKopecks: spent, isMonthOnly: held.isMonthOnly))
        }
        for group in groups {
            guard let held = limit(budgets, group: group, monthKey: key) else { continue }
            result.append(BudgetStatus(group: group, limitKopecks: held.limitKopecks, spentKopecks: spentByGroup[group] ?? 0,
                                       isMonthOnly: held.isMonthOnly))
        }
        return result
    }
}
