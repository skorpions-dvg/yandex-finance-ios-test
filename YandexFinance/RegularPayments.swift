import Foundation

/// Presentation of the patterns already found by the financial engine.
enum RegularPayments {
    static func periodTitle(intervalDays: Int) -> String {
        switch intervalDays {
        case 7: return "Каждую неделю"
        case 14: return "Раз в две недели"
        case 30: return "Каждый месяц"
        case 365: return "Раз в год"
        default: return "Раз в \(intervalDays) дн."
        }
    }

    /// The next occurrence after the last recorded payment, today included even if its time has passed.
    /// Calendar steps match the forecast: months and years are not fixed numbers of seconds or days.
    static func nextDate(of pattern: FinancialEngine.RecurringPattern, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let unit: Calendar.Component = pattern.intervalDays == 30 ? .month : (pattern.intervalDays == 365 ? .year : .day)
        let count = unit == .day ? max(1, pattern.intervalDays) : 1
        // Counted from the last payment, as the forecast does: the 31st stays the 31st after a short month.
        var periods = 1
        var next = calendar.date(byAdding: unit, value: count * periods, to: pattern.lastDate)!
        while next < today {
            periods += 1
            next = calendar.date(byAdding: unit, value: count * periods, to: pattern.lastDate)!
        }
        return next
    }

    /// An estimate for a 30-day month, rounded once to a whole kopeck.
    static func monthlyKopecks(of pattern: FinancialEngine.RecurringPattern) -> Int64 {
        let amount = Decimal(pattern.typicalAmountKopecks)
        var monthly: Decimal
        switch pattern.intervalDays {
        case 30: monthly = amount
        case 365: monthly = amount / 12
        default: monthly = amount * 30 / Decimal(max(1, pattern.intervalDays))
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &monthly, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}
