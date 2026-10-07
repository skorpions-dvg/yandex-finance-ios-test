import Foundation

/// Presentation data only; every amount comes from the existing report engine.
enum ReportSeries {
    struct Period: Identifiable {
        let interval: DateInterval
        let report: FinanceReport
        var id: Date { interval.start }
    }

    struct Average: Equatable {
        let incomeKopecks: Int64
        let expenseKopecks: Int64
        let activePeriods: Int
    }

    struct CategoryPoint: Identifiable {
        let date: Date
        let amountKopecks: Int64
        var id: Date { date }
    }

    enum AccountRange: String, CaseIterable, Identifiable {
        case days30, days90, year
        var id: String { rawValue }
        var title: String {
            switch self {
            case .days30: return "30 дней"
            case .days90: return "90 дней"
            case .year: return "Год"
            }
        }
    }

    struct BalancePoint: Identifiable {
        /// The day whose closing balance is displayed.
        let date: Date
        /// Exclusive upper boundary passed to the existing balance API.
        let moment: Date
        let amountKopecks: Int64
        var id: Date { date }
    }

    struct AccountPeriod {
        let movements: [AccountMovement]
        let incomingKopecks: Int64
        let outgoingKopecks: Int64
    }

    struct AccountDay: Identifiable {
        let date: Date
        let movements: [AccountMovement]
        var id: Date { date }
    }

    static func accountInterval(range: AccountRange, now: Date = Date(),
                                calendar: Calendar = .current) -> DateInterval {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let start: Date
        switch range {
        case .days30: start = calendar.date(byAdding: .day, value: -30, to: end)!
        case .days90: start = calendar.date(byAdding: .day, value: -90, to: end)!
        case .year: start = calendar.date(byAdding: .year, value: -1, to: end)!
        }
        return DateInterval(start: start, end: end)
    }

    static func balanceMoments(interval: DateInterval, range: AccountRange,
                               calendar: Calendar = .current) -> [Date] {
        var moment = interval.start
        var result: [Date] = []
        while moment < interval.end {
            moment = min(calendar.date(byAdding: .day, value: range == .year ? 7 : 1, to: moment)!, interval.end)
            result.append(moment)
        }
        return result
    }

    static func balancePoints(_ history: SavedHistory, account: Account, interval: DateInterval,
                              range: AccountRange, calendar: Calendar = .current) -> [BalancePoint] {
        let moments = balanceMoments(interval: interval, range: range, calendar: calendar)
        let balances = history.accountBalances(account, at: moments)
        return zip(moments, balances).map { moment, balance in
            BalancePoint(date: calendar.startOfDay(for: moment.addingTimeInterval(-1)), moment: moment,
                         amountKopecks: balance)
        }
    }

    static func accountPeriod(_ movements: [AccountMovement], interval: DateInterval) -> AccountPeriod {
        let visible = movements.filter { $0.date >= interval.start && $0.date < interval.end }
        return AccountPeriod(movements: visible,
                             incomingKopecks: visible.filter { $0.delta > 0 }.reduce(0) { $0 + $1.delta },
                             outgoingKopecks: visible.filter { $0.delta < 0 }.reduce(0) { $0 - $1.delta })
    }

    static func accountDays(_ movements: [AccountMovement], calendar: Calendar = .current) -> [AccountDay] {
        let grouped = Dictionary(grouping: movements) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            AccountDay(date: day, movements: grouped[day]!.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date })
        }
    }

    static func categoryPoints(_ periods: [Period], group: String) -> [CategoryPoint] {
        periods.map { period in
            CategoryPoint(date: period.id,
                          amountKopecks: period.report.expenseLines.first { $0.title == group }?.amountKopecks ?? 0)
        }
    }

    static func defaultGroup(_ report: FinanceReport, groups: [ExpenseCategoryGroup]) -> ExpenseCategoryGroup? {
        let largest = report.expenseLines.max { $0.amountKopecks < $1.amountKopecks }?.title
        return groups.first { $0.name == largest } ?? groups.first
    }

    static func intervals(selectedStart: Date, unit: ReportUnit,
                          calendar: Calendar = .current) -> [DateInterval] {
        let component: Calendar.Component = unit == .day ? .day : .month
        let count = unit == .day ? 14 : 12
        let first: Date
        if unit == .year {
            first = reportStart(of: selectedStart, unit: .year, calendar: calendar)
        } else {
            let last = reportStart(of: selectedStart, unit: unit, calendar: calendar)
            first = calendar.date(byAdding: component, value: -(count - 1), to: last)!
        }
        return (0..<count).map { offset in
            let start = calendar.date(byAdding: component, value: offset, to: first)!
            let end = calendar.date(byAdding: component, value: 1, to: start)!
            return DateInterval(start: start, end: end)
        }
    }

    static func periods(inputs: [FinancialOperationInput], intervals: [DateInterval],
                        taxonomy: ExpenseTaxonomy) -> [Period] {
        intervals.map { Period(interval: $0, report: FinancialEngine.report(inputs, in: $0, taxonomy: taxonomy)) }
    }

    static func average(_ periods: [Period]) -> Average {
        let active = periods.filter { $0.report.operationCount > 0 }
        guard !active.isEmpty else { return Average(incomeKopecks: 0, expenseKopecks: 0, activePeriods: 0) }
        let count = Int64(active.count)
        return Average(incomeKopecks: active.reduce(0) { $0 + $1.report.incomeKopecks } / count,
                       expenseKopecks: active.reduce(0) { $0 + $1.report.netExpenseKopecks } / count,
                       activePeriods: active.count)
    }
}
