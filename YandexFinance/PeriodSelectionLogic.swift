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
