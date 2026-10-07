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
