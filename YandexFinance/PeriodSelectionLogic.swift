import Foundation

/// Return the first day of the month for a given date.
public func monthStart(of date: Date, calendar: Calendar = .current) -> Date {
    let components = calendar.dateComponents([.year, .month], from: date)
    return calendar.date(from: components)!
}

/// Return the next month start, unless the selected month is current or in the future.
public func nextMonthIfAllowed(
    selectedStart: Date,
    currentDate: Date = Date(),
    calendar: Calendar = .current
) -> Date? {
    let selectedMonth = monthStart(of: selectedStart, calendar: calendar)
    let currentMonth = monthStart(of: currentDate, calendar: calendar)
    guard selectedMonth < currentMonth else { return nil }
    return calendar.date(byAdding: .month, value: 1, to: selectedMonth)
}

/// Use the same navigation rule as the application and its tests.
public func canGoToNextMonth(
    selectedStart: Date,
    currentDate: Date = Date(),
    calendar: Calendar = .current
) -> Bool {
    nextMonthIfAllowed(selectedStart: selectedStart, currentDate: currentDate, calendar: calendar) != nil
}

/// Period chosen on the operations screen.
public enum HistoryPeriod: Hashable {
    /// The last N calendar days, today included.
    case lastDays(Int)
    case allTime
    /// Whole calendar days from one date through another, both included.
    case custom(from: Date, through: Date)
}

/// Half-open interval for a history period; it always ends at the end of today (or of the last custom day).
public func historyInterval(_ period: HistoryPeriod, now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
    let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
    switch period {
    case .lastDays(let days):
        return DateInterval(start: calendar.date(byAdding: .day, value: -max(days, 1), to: endOfToday)!, end: endOfToday)
    case .allTime:
        return DateInterval(start: .distantPast, end: endOfToday)
    case .custom(let from, let through):
        let first = calendar.startOfDay(for: min(from, through))
        let last = calendar.startOfDay(for: max(from, through))
        return DateInterval(start: first, end: calendar.date(byAdding: .day, value: 1, to: last)!)
    }
}

/// Half-open periods used to compare the selected month with the previous one.
public struct MonthComparisonPeriods: Equatable {
    public let current: DateInterval
    public let previous: DateInterval
    /// True when the selected month is still in progress and only elapsed days are compared.
    public let isPartial: Bool
}

/// A finished month is compared with the whole previous month. For the month in progress the
/// same number of elapsed calendar days (today included) is compared; when the previous month
/// is shorter than that, the whole previous month is used.
public func monthComparisonPeriods(
    selectedStart: Date,
    currentDate: Date = Date(),
    calendar: Calendar = .current
) -> MonthComparisonPeriods {
    let start = monthStart(of: selectedStart, calendar: calendar)
    let end = calendar.date(byAdding: .month, value: 1, to: start)!
    let previousStart = calendar.date(byAdding: .month, value: -1, to: start)!
    guard currentDate >= start && currentDate < end else {
        return MonthComparisonPeriods(current: DateInterval(start: start, end: end),
                                      previous: DateInterval(start: previousStart, end: start),
                                      isPartial: false)
    }
    let elapsedDays = calendar.component(.day, from: currentDate)
    let currentEnd = calendar.date(byAdding: .day, value: elapsedDays, to: start)!
    let previousEnd = min(calendar.date(byAdding: .day, value: elapsedDays, to: previousStart)!, start)
    return MonthComparisonPeriods(current: DateInterval(start: start, end: currentEnd),
                                  previous: DateInterval(start: previousStart, end: previousEnd),
                                  isPartial: true)
}

// MARK: - Reports by day, month or year

/// The length of the period shown in «Отчёты».
public enum ReportUnit: String, CaseIterable, Identifiable {
    case day, month, year
    public var id: String { rawValue }

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .month: return .month
        case .year: return .year
        }
    }
}

/// Start of the day, month or year that contains `date`.
public func reportStart(of date: Date, unit: ReportUnit, calendar: Calendar = .current) -> Date {
    switch unit {
    case .day: return calendar.startOfDay(for: date)
    case .month: return monthStart(of: date, calendar: calendar)
    case .year: return calendar.date(from: calendar.dateComponents([.year], from: date))!
    }
}

public func reportInterval(start: Date, unit: ReportUnit, calendar: Calendar = .current) -> DateInterval {
    DateInterval(start: start, end: calendar.date(byAdding: unit.component, value: 1, to: start)!)
}

/// The previous or next period; nil when it would start in the future.
public func shiftedReportStart(_ start: Date, unit: ReportUnit, by step: Int, currentDate: Date = Date(),
                               calendar: Calendar = .current) -> Date? {
    let target = calendar.date(byAdding: unit.component, value: step, to: reportStart(of: start, unit: unit, calendar: calendar))!
    return target > currentDate ? nil : target
}

/// What a period is compared with. A finished period is compared with the whole previous one. The period in
/// progress is compared with the same elapsed part of the previous one: the same elapsed days for a month, up to
/// the same calendar date for a year, the elapsed time of today for a day.
public func reportComparisonPeriods(start: Date, unit: ReportUnit, currentDate: Date = Date(),
                                    calendar: Calendar = .current) -> MonthComparisonPeriods {
    let start = reportStart(of: start, unit: unit, calendar: calendar)
    if unit == .month { return monthComparisonPeriods(selectedStart: start, currentDate: currentDate, calendar: calendar) }
    let end = calendar.date(byAdding: unit.component, value: 1, to: start)!
    let previousStart = calendar.date(byAdding: unit.component, value: -1, to: start)!
    guard currentDate >= start && currentDate < end else {
        return MonthComparisonPeriods(current: DateInterval(start: start, end: end),
                                      previous: DateInterval(start: previousStart, end: start), isPartial: false)
    }
    if unit == .day {
        let elapsed = currentDate.timeIntervalSince(start)
        return MonthComparisonPeriods(current: DateInterval(start: start, end: currentDate),
                                      previous: DateInterval(start: previousStart, end: previousStart.addingTimeInterval(elapsed)),
                                      isPartial: true)
    }
    // A year in progress is compared up to the same calendar date a year earlier.
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: currentDate))!
    let previousEnd = min(calendar.date(byAdding: unit.component, value: -1, to: tomorrow)!, start)
    return MonthComparisonPeriods(current: DateInterval(start: start, end: tomorrow),
                                  previous: DateInterval(start: previousStart, end: previousEnd), isPartial: true)
}
