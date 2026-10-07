import Foundation

@main
struct FinanceEngineTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func op(_ amount: Int64, kind: String, status: String = "Выполнено", category: String = "Тест",
                   description: String = "Синтетическая операция", mcc: String? = nil, purpose: String? = nil,
                   providers: [String] = [], components: [Int64] = [], date: String = "2032-06-02T10:00:00Z") -> FinancialOperationInput {
        FinancialOperationInput(occurredAt: date, description: description, amountKopecks: amount,
                                status: status, category: category, mcc: mcc, purpose: purpose,
                                providers: providers, kind: kind, componentAmountsKopecks: components)
    }

    static func testPeriodSelection() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }

        let dec2023 = date(2023, 12)
        let jan2024 = date(2024, 1)
        let feb2024 = date(2024, 2)
        let mar2024 = date(2024, 3)

        require(nextMonthIfAllowed(selectedStart: feb2024, currentDate: feb2024, calendar: calendar) == nil,
                "current month must not allow moving forward")
        require(nextMonthIfAllowed(selectedStart: feb2024, currentDate: date(2024, 2, 15), calendar: calendar) == nil,
                "current month must stay blocked in the middle of the month")
        require(nextMonthIfAllowed(selectedStart: mar2024, currentDate: feb2024, calendar: calendar) == nil,
                "future month must not allow moving forward")
        require(nextMonthIfAllowed(selectedStart: jan2024, currentDate: feb2024, calendar: calendar) == feb2024,
                "January must advance to February")
        require(nextMonthIfAllowed(selectedStart: dec2023, currentDate: jan2024, calendar: calendar) == jan2024,
                "December 2023 must advance to January 2024")
        require(nextMonthIfAllowed(selectedStart: date(2024, 1, 31), currentDate: feb2024, calendar: calendar) == feb2024,
                "navigation must return the next month start, not the same day number")
        require(nextMonthIfAllowed(selectedStart: date(2024, 2, 29), currentDate: mar2024, calendar: calendar) == mar2024,
                "leap February must advance to March 1")
    }

    static func testMonthComparisonPeriods() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int = 1, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        func interval(_ start: Date, _ end: Date) -> DateInterval { DateInterval(start: start, end: end) }

        let finished = monthComparisonPeriods(selectedStart: date(2024, 1), currentDate: date(2024, 3, 10), calendar: calendar)
        require(!finished.isPartial, "finished month is not partial")
        require(finished.current == interval(date(2024, 1), date(2024, 2)), "finished month covers the whole month")
        require(finished.previous == interval(date(2023, 12), date(2024, 1)), "previous of January is the whole December, not two months")

        let partial = monthComparisonPeriods(selectedStart: date(2024, 2), currentDate: date(2024, 2, 6, 10), calendar: calendar)
        require(partial.isPartial, "month in progress is partial")
        require(partial.current == interval(date(2024, 2), date(2024, 2, 7)), "partial month covers elapsed days including today")
        require(partial.previous == interval(date(2024, 1), date(2024, 1, 7)), "previous month uses the same 6 calendar days")

        let firstDay = monthComparisonPeriods(selectedStart: date(2024, 2), currentDate: date(2024, 2), calendar: calendar)
        require(firstDay.previous == interval(date(2024, 1), date(2024, 1, 2)), "first day compares with the first day")

        let yearBoundary = monthComparisonPeriods(selectedStart: date(2024, 1), currentDate: date(2024, 1, 15, 12), calendar: calendar)
        require(yearBoundary.previous == interval(date(2023, 12), date(2023, 12, 16)), "January compares with December of the previous year")

        // Reports by day and by year.
        let now = date(2024, 3, 5, 15)
        require(reportStart(of: now, unit: .day, calendar: calendar) == date(2024, 3, 5), "day start")
        require(reportStart(of: now, unit: .year, calendar: calendar) == date(2024, 1), "year start")
        require(reportInterval(start: date(2024, 1), unit: .year, calendar: calendar) == interval(date(2024, 1), date(2025, 1)), "a year interval")
        require(shiftedReportStart(date(2024, 3, 5), unit: .day, by: 1, currentDate: now, calendar: calendar) == nil, "no future day")
        require(shiftedReportStart(date(2024, 3, 5), unit: .day, by: -1, currentDate: now, calendar: calendar) == date(2024, 3, 4), "previous day")
        require(shiftedReportStart(date(2024, 1), unit: .year, by: -1, currentDate: now, calendar: calendar) == date(2023, 1), "previous year")
        require(shiftedReportStart(date(2023, 1), unit: .year, by: 1, currentDate: now, calendar: calendar) == date(2024, 1), "back to this year")
        let today = reportComparisonPeriods(start: date(2024, 3, 5), unit: .day, currentDate: now, calendar: calendar)
        require(today.isPartial && today.current == interval(date(2024, 3, 5), now)
                && today.previous == interval(date(2024, 3, 4), date(2024, 3, 4, 15)), "today compares with yesterday up to the same hour")
        let pastDay = reportComparisonPeriods(start: date(2024, 3, 1), unit: .day, currentDate: now, calendar: calendar)
        require(!pastDay.isPartial && pastDay.previous == interval(date(2024, 2, 29), date(2024, 3, 1)), "a past day compares with the whole previous day")
        let thisYear = reportComparisonPeriods(start: date(2024, 1), unit: .year, currentDate: now, calendar: calendar)
        require(thisYear.isPartial && thisYear.current == interval(date(2024, 1), date(2024, 3, 6))
                && thisYear.previous == interval(date(2023, 1), date(2023, 3, 6)), "this year compares the same elapsed days")
        let pastYear = reportComparisonPeriods(start: date(2023, 1), unit: .year, currentDate: now, calendar: calendar)
        require(!pastYear.isPartial && pastYear.previous == interval(date(2022, 1), date(2023, 1)), "a past year compares with the whole previous year")
        require(reportComparisonPeriods(start: date(2024, 2), unit: .month, currentDate: date(2024, 2, 6, 10), calendar: calendar) == partial,
                "months keep their existing comparison")

        let longerThanFebruary = monthComparisonPeriods(selectedStart: date(2024, 3), currentDate: date(2024, 3, 31, 23), calendar: calendar)
        require(longerThanFebruary.current == interval(date(2024, 3), date(2024, 4)), "31 elapsed days cover all of March")
        require(longerThanFebruary.previous == interval(date(2024, 2), date(2024, 3)), "shorter February is used whole and does not spill into March")

        let leapDayCount = monthComparisonPeriods(selectedStart: date(2024, 3), currentDate: date(2024, 3, 29), calendar: calendar)
        require(leapDayCount.previous == interval(date(2024, 2), date(2024, 3)), "29 days of leap February is the whole month")
        let nonLeap = monthComparisonPeriods(selectedStart: date(2023, 3), currentDate: date(2023, 3, 29), calendar: calendar)
        require(nonLeap.previous == interval(date(2023, 2), date(2023, 3)), "28-day February is used whole for day 29")
    }

    static func testMonthlyComparison() {
        let january = DateInterval(start: BankDateParser.parse("2024-01-01T00:00:00Z")!, end: BankDateParser.parse("2024-02-01T00:00:00Z")!)
        let february = DateInterval(start: BankDateParser.parse("2024-02-01T00:00:00Z")!, end: BankDateParser.parse("2024-03-01T00:00:00Z")!)

        let taxi = { (amount: Int64, date: String) in op(amount, kind: "expense", category: "Такси", date: date) }
        let groceries = { (amount: Int64, date: String) in op(amount, kind: "expense", category: "Супермаркеты", date: date) }
        let transferToPerson = op(-20_000, kind: "transfer", category: "Перевод", description: "Перевод Ивану", date: "2024-02-10T10:00:00Z")
        let split = op(-9_000, kind: "installment_payment", category: "Сплит", date: "2024-02-11T10:00:00Z")
        let refund = op(1_000, kind: "refund", category: "Возврат", date: "2024-01-20T10:00:00Z")

        require(FinancialEngine.expenseCategory(for: taxi(-1, "2024-01-01T00:00:00Z")) == FinanceCategoryPath(group: "Транспорт", subcategory: "Такси"), "fixture: taxi category")
        require(FinancialEngine.expenseCategory(for: groceries(-1, "2024-01-01T00:00:00Z")) == FinanceCategoryPath(group: "Еда", subcategory: "Супермаркеты"), "fixture: grocery category")
        require(FinancialEngine.classify(transferToPerson).type == .expense, "fixture: transfer to a person is an expense")
        require(FinancialEngine.expenseCategory(for: transferToPerson).subcategory == "Переводы другим", "fixture: transfer category")
        require(FinancialEngine.classify(split).type == .split, "fixture: split")

        let operations = [
            op(10_000, kind: "income", date: "2024-01-05T10:00:00Z"),
            taxi(-2_000, "2024-01-06T10:00:00Z"),
            groceries(-5_000, "2024-01-07T10:00:00Z"),
            refund,
            op(12_000, kind: "income", date: "2024-02-05T10:00:00Z"),
            taxi(-1_000, "2024-02-06T10:00:00Z"),
            groceries(-8_000, "2024-02-07T10:00:00Z"),
            transferToPerson,
            split,
        ]
        let comparison = FinancialEngine.compareReports(operations, currentInterval: february, previousInterval: january)
        require(comparison.income == FinancialEngine.MonthlyChange(current: 12_000, previous: 10_000), "income for both months")
        require(comparison.income.delta == 2_000, "income absolute change")
        require(comparison.income.relative == .percent(20), "income +20%")
        require(comparison.netExpense == FinancialEngine.MonthlyChange(current: 29_000, previous: 6_000), "net expense after refunds, split excluded")
        require(comparison.difference == FinancialEngine.MonthlyChange(current: -17_000, previous: 4_000), "income minus net expense")
        require(comparison.topExpenseGrowth == FinancialEngine.CategoryGrowth(group: "Еда", subcategory: "Супермаркеты",
                                                                             change: FinancialEngine.MonthlyChange(current: 8_000, previous: 5_000)),
                "largest growth ignores transfers to people and split")
        require(comparison.topExpenseGrowth?.change.relative == .percent(60), "grocery growth +60%")

        let decline = [
            taxi(-2_000, "2024-01-06T10:00:00Z"), groceries(-5_000, "2024-01-07T10:00:00Z"),
            taxi(-1_000, "2024-02-06T10:00:00Z"), groceries(-5_000, "2024-02-07T10:00:00Z"),
        ]
        let noGrowth = FinancialEngine.compareReports(decline, currentInterval: february, previousInterval: january)
        require(noGrowth.topExpenseGrowth == nil, "no category grew, so there is no growth leader")

        let fromZero = FinancialEngine.compareReports([taxi(-1_500, "2024-02-06T10:00:00Z")], currentInterval: february, previousInterval: january)
        require(fromZero.topExpenseGrowth?.change == FinancialEngine.MonthlyChange(current: 1_500, previous: 0), "growth from an empty month")
        require(fromZero.topExpenseGrowth?.change.relative == .new, "growth from zero is new, not a division by zero")
        require(fromZero.income.relative == .notApplicable, "zero against zero is not applicable")
        require(fromZero.difference.relative == .notApplicable, "negative or zero base is not applicable")
        require(FinancialEngine.MonthlyChange(current: 0, previous: 3_000).relative == .percent(-100), "drop to zero is -100%")

        let tie = [taxi(-1_000, "2024-02-06T10:00:00Z"), groceries(-1_000, "2024-02-07T10:00:00Z")]
        require(FinancialEngine.compareReports(tie, currentInterval: february, previousInterval: january).topExpenseGrowth?.subcategory == "Супермаркеты",
                "equal growth is resolved by the fixed category order")

        // Half-open partial periods: the first moment after the compared days is excluded.
        let partialPrevious = DateInterval(start: january.start, end: BankDateParser.parse("2024-01-07T00:00:00Z")!)
        let boundary = [taxi(-300, "2024-01-06T23:59:59Z"), taxi(-700, "2024-01-07T00:00:00Z")]
        let boundaryComparison = FinancialEngine.compareReports(boundary, currentInterval: february, previousInterval: partialPrevious)
        require(boundaryComparison.netExpense.previous == 300, "operation right after the compared days is not counted")
    }

    static func testDailyNetExpense() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2024, month: 2, day: day))! }

        let operations = [
            op(-1_000, kind: "expense", category: "Такси", date: "2024-02-01T10:00:00Z"),
            op(-9_000, kind: "installment_payment", category: "Сплит", date: "2024-02-02T10:00:00Z"),
            op(-500, kind: "expense", category: "Супермаркеты", date: "2024-02-03T09:00:00Z"),
            op(200, kind: "refund", category: "Возврат", date: "2024-02-03T18:00:00Z"),
            op(5_000, kind: "income", date: "2024-02-04T10:00:00Z"),
            op(-700, kind: "expense", category: "Такси", date: "2024-02-05T00:00:00Z"),
        ]
        let interval = DateInterval(start: date(1), end: date(5))
        let days = FinancialEngine.dailyNetExpense(operations, in: interval, calendar: calendar)
        require(days.map(\.day) == [date(1), date(2), date(3), date(4)], "one entry per day of the half-open interval")
        require(days.map(\.amountKopecks) == [1_000, 0, 300, 0], "daily net expense: split and income excluded, refund reduces its day")
        require(days.reduce(0) { $0 + $1.amountKopecks } == FinancialEngine.report(operations, in: interval).netExpenseKopecks,
                "daily amounts add up to the period's net expense")

        let partial = FinancialEngine.dailyNetExpense(operations, in: DateInterval(start: date(3), end: date(3).addingTimeInterval(12 * 3600)), calendar: calendar)
        require(partial.map(\.amountKopecks) == [500], "a partial last day only counts operations inside the interval")
    }

    static func testExpenseByGroup() {
        let interval = DateInterval(start: BankDateParser.parse("2024-02-01T00:00:00Z")!, end: BankDateParser.parse("2024-03-01T00:00:00Z")!)
        let operations = [
            op(-1_000, kind: "expense", category: "Такси", date: "2024-02-01T10:00:00Z"),
            op(-500, kind: "expense", category: "Супермаркеты", date: "2024-02-02T10:00:00Z"),
            op(-300, kind: "expense", category: "Кафе", date: "2024-02-03T10:00:00Z"),
            op(-9_000, kind: "installment_payment", category: "Сплит", date: "2024-02-04T10:00:00Z"),
            op(200, kind: "refund", category: "Возврат", date: "2024-02-05T10:00:00Z"),
            op(-4_000, kind: "internal_transfer", category: "Переводы между своими счетами", date: "2024-02-06T10:00:00Z"),
        ]
        let report = FinancialEngine.report(operations, in: interval)
        let groups = FinancialEngine.expenseByGroup(report)
        require(groups == [FinancialEngine.CategoryAmount(title: "Еда", amountKopecks: 800),
                           FinancialEngine.CategoryAmount(title: "Транспорт", amountKopecks: 1_000)],
                "groups in taxonomy order; split, refunds and own transfers are not groups")
        require(groups.reduce(0) { $0 + $1.amountKopecks } == report.grossExpenseKopecks, "groups add up to gross expense")
        require(FinancialEngine.expenseByGroup(FinancialEngine.report([], in: interval)).isEmpty, "no spending, no groups")
    }

    static func testHistoryInterval() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2024, month: month, day: day, hour: hour))!
        }
        let now = date(2, 6, 10)
        require(historyInterval(.lastDays(7), now: now, calendar: calendar) == DateInterval(start: date(1, 31), end: date(2, 7)),
                "7 days are today and the six days before it")
        require(historyInterval(.lastDays(30), now: now, calendar: calendar) == DateInterval(start: date(1, 8), end: date(2, 7)),
                "30 days end with today")
        require(historyInterval(.allTime, now: now, calendar: calendar) == DateInterval(start: .distantPast, end: date(2, 7)),
                "all history ends with today")
        require(historyInterval(.custom(from: date(2, 10, 15), through: date(2, 1, 8)), now: now, calendar: calendar)
                    == DateInterval(start: date(2, 1), end: date(2, 11)),
                "custom dates are whole days in either order, the last day included")
    }

    static func testMonthForecast() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: 2024, month: month, day: day, hour: hour))!
        }
        func iso(_ month: Int, _ day: Int) -> String { String(format: "2024-%02d-%02dT10:00:00Z", month, day) }

        // Six full months: salary on the 5th, rent on the 15th, phone on the 20th, groceries of varying size.
        let variableTotals: [Int64] = [30_000, 31_000, 29_000, 32_000, 28_000, 30_000]
        var history: [FinancialOperationInput] = []
        for month in 1...6 {
            history.append(op(100_000, kind: "income", category: "Зарплата", description: "ООО Ромашка", date: iso(month, 5)))
            history.append(op(-20_000, kind: "expense", category: "ЖКХ", description: "УК Жилищник", date: iso(month, 15)))
            history.append(op(-249, kind: "expense", category: "Связь", description: "Rush", date: iso(month, 20)))
            let total = variableTotals[month - 1]
            history.append(op(-total / 3, kind: "expense", category: "Супермаркеты", description: "Пятёрочка", date: iso(month, 3)))
            history.append(op(-(total - total / 3), kind: "expense", category: "Супермаркеты", description: "Пятёрочка", date: iso(month, 18)))
        }
        let july = history + [
            op(100_000, kind: "income", category: "Зарплата", description: "ООО Ромашка", date: iso(7, 5)),
            op(-12_000, kind: "expense", category: "Супермаркеты", description: "Пятёрочка", date: iso(7, 3)),
        ]

        let patterns = FinancialEngine.recurringPatterns(july, now: at(7, 10), calendar: calendar)
        require(patterns.map(\.title) == ["Rush", "УК Жилищник", "ООО Ромашка"], "salary, rent and phone are recurring; groceries of varying size are not")
        require(patterns.allSatisfy { $0.intervalDays == 30 }, "all three repeat monthly")
        require(patterns.first { $0.title == "УК Жилищник" }?.typicalAmountKopecks == 20_000, "typical amount is the median")

        let forecast = FinancialEngine.monthForecast(july, now: at(7, 10), calendar: calendar)
        require(forecast.historyMonths == 6 && forecast.elapsedDays == 10 && forecast.daysInMonth == 31, "six months of history, day 10 of 31")
        require(forecast.upcoming == [
            FinancialEngine.UpcomingPayment(title: "УК Жилищник", amountKopecks: 20_000, date: at(7, 15), isIncome: false, overdue: false),
            FinancialEngine.UpcomingPayment(title: "Rush", amountKopecks: 249, date: at(7, 20), isIncome: false, overdue: false),
        ], "rent and phone are still expected this month; this month's salary already came")
        // Variable baseline: median 30 000, quartiles 29 250 and 30 750. The usual daily rate (base / 31) is blended
        // with this month's own (12 000 in 10 days) with the weight 30 : 10, and carries over the 21 days left.
        func blendedTail(_ base: Double, spent: Double, elapsed: Double, daysLeft: Double) -> Int64 {
            let rate = (base / 31 * 30 + spent / elapsed * elapsed) / (30 + elapsed)
            return Int64((rate * daysLeft).rounded())
        }
        let expectedTail10 = blendedTail(30_000, spent: 12_000, elapsed: 10, daysLeft: 21)
        require(forecast.projectedExpenseKopecks == 12_000 + 20_249 + expectedTail10, "spent + recurring still expected + variable tail")
        require(forecast.projectedExpenseLowKopecks == 12_000 + 20_249 + blendedTail(29_250, spent: 12_000, elapsed: 10, daysLeft: 21)
                && forecast.projectedExpenseHighKopecks == 12_000 + 20_249 + blendedTail(30_750, spent: 12_000, elapsed: 10, daysLeft: 21),
                "range from the interpolated quartiles")
        require(forecast.projectedIncomeKopecks == 100_000 && forecast.projectedBalanceKopecks == 100_000 - forecast.projectedExpenseKopecks,
                "salary already received, no other income usual")
        require(forecast.previousMonthIncomeKopecks == 100_000, "previous month income")

        require(forecast.oneOffKopecks == 0, "an ordinary grocery run is not one-off")
        require(forecast.baselineMonths.count == 6 && forecast.baselineMonths[0].month == at(6, 1, 0), "breakdown lists the six months, newest first")
        require(forecast.baselineMonths.map(\.variableKopecks) == variableTotals.reversed(), "breakdown variable spending matches the baseline input")
        require(forecast.baselineMonths.allSatisfy { $0.recurringKopecks == 20_249 && $0.oneOffKopecks == 0 && $0.netExpenseKopecks == $0.variableKopecks + 20_249 },
                "each month splits into recurring and variable spending")

        let late = FinancialEngine.monthForecast(july, now: at(7, 25), calendar: calendar)
        require(late.upcoming.map(\.overdue) == [true, true], "rent and phone that have not come by the 25th are flagged as overdue")

        // A big purchase on the first day must not be stretched over the whole month.
        let bigStart = history + [op(-60_000, kind: "expense", category: "Электроника", description: "DNS", date: iso(7, 1))]
        let early = FinancialEngine.monthForecast(bigStart, now: at(7, 2), calendar: calendar)
        require(early.oneOffKopecks == 60_000, "a purchase far above the usual spending is one-off")
        let expectedTail = blendedTail(30_000, spent: 0, elapsed: 2, daysLeft: 29)
        require(early.projectedExpenseKopecks == 60_000 + 20_249 + expectedTail,
                "the one-off counts as spent but does not drive the rate; the usual rate is only slightly pulled by the empty first days")

        // The forecast must not jump from day to day. Real purchases (day 1, 4 and 8) move the month by their own amount;
        // what is left of a day's change after taking that amount out is the forecast's own reaction, and it stays small.
        let purchases: [Int: Int64] = [1: 3_000, 4: 2_500, 8: 4_000]
        let withShop = history + purchases.map { day, amount in
            op(-amount, kind: "expense", category: "Супермаркеты", description: "Пятёрочка", date: iso(7, day))
        }
        var maxReaction = 0.0
        var previousValue: Int64?
        var trace: [Int64] = []
        for day in 2...12 {
            let value = FinancialEngine.monthForecast(withShop, now: at(7, day), calendar: calendar).projectedExpenseKopecks
            trace.append(value)
            if let previousValue {
                let reaction = value - previousValue - (purchases[day] ?? 0)
                maxReaction = max(maxReaction, Double(abs(reaction)) / Double(previousValue))
            }
            previousValue = value
        }
        require(maxReaction < 0.04, "apart from the purchases themselves the forecast moves by less than 4 % a day (it moved by \(maxReaction): \(trace))")

        // Last month brought 200 000 and 100 000 was spent; this month 100 000 came and 100 000 is gone in 6 days.
        let lowerIncome = [
            op(200_000, kind: "income", description: "Перевод от Ивана", date: iso(1, 5)),
            op(-100_000, kind: "expense", category: "Электроника", description: "DNS", date: iso(1, 10)),
            op(-1_000, kind: "expense", category: "Супермаркеты", description: "Магнит", date: iso(1, 11)),
            op(-1_000, kind: "expense", category: "Супермаркеты", description: "Магнит", date: iso(1, 12)),
            op(100_000, kind: "income", description: "Перевод от Ивана", date: iso(2, 5)),
            op(-100_000, kind: "expense", category: "Электроника", description: "М.Видео", date: iso(2, 6)),
        ]
        let tight = FinancialEngine.monthForecast(lowerIncome, now: at(2, 6), calendar: calendar)
        require(tight.projectedIncomeKopecks == 100_000, "irregular income is not assumed: only what came counts")
        require(tight.typicalIrregularIncomeKopecks == 200_000, "the usual irregular income is reported separately")
        require(tight.oneOffKopecks == 100_000, "a big purchase from a new payee is one-off")
        require(tight.projectedExpenseKopecks < 110_000, "the one-off is not stretched over the month")
        require(tight.balanceWithTypicalIncomeKopecks == tight.projectedBalanceKopecks + 100_000,
                "the optimistic scenario adds only the part of the usual irregular income that has not come yet")

        // A history that starts mid-month: that partial month must not enter the baseline.
        let partial = [
            op(-1_000, kind: "expense", category: "Супермаркеты", description: "Магнит", date: iso(3, 20)),
            op(-10_000, kind: "expense", category: "Супермаркеты", description: "Магнит", date: iso(4, 10)),
            op(-10_000, kind: "expense", category: "Супермаркеты", description: "Магнит", date: iso(4, 17)),
            op(-10_000, kind: "expense", category: "Супермаркеты", description: "Магнит", date: iso(4, 24)),
        ]
        let fromPartial = FinancialEngine.monthForecast(partial, now: at(5, 10), calendar: calendar)
        require(fromPartial.historyMonths == 1, "March is only partly covered and is skipped; April counts")

        // Shaped like the real archive: transfers to one person of varying size, a utility bill whose text carries
        // the amounts and the period, groceries, and one large transfer to someone new.
        var habits: [FinancialOperationInput] = [op(-500, kind: "expense", category: "Такси", description: "Такси", date: iso(4, 3))]
        let personA = "Исходящий перевод СБП, Мария Ивановна П., +7 923 000-00-00, Сбербанк"
        let transfers: [(Int, Int, Int64)] = [(7, 2, 25_000), (7, 21, 16_000), (8, 9, 20_000), (9, 4, 20_000), (9, 23, 12_000)]
        for (month, day, amount) in transfers {
            habits.append(op(-amount, kind: "transfer", category: "Перевод", description: personA, date: iso(month, day)))
        }
        let bills: [Int64] = [25_147, 18_310, 22_905]
        let groceries: [[Int64]] = [[1_100, 2_700], [900, 3_400], [1_800, 2_200]]
        for (index, month) in [7, 8, 9].enumerated() {
            habits.append(op(-bills[index], kind: "expense", category: "ЖКХ", description: "ЭЭ \(index + 3).24, ГВС 8501.79 <ЛСИ62952740715;ПРД0\(month).2026>", date: iso(month, 12)))
            habits.append(op(-groceries[index][0], kind: "expense", category: "Супермаркеты", description: "Пятёрочка", date: iso(month, 6)))
            habits.append(op(-groceries[index][1], kind: "expense", category: "Супермаркеты", description: "Пятёрочка", date: iso(month, 19)))
        }
        habits.append(op(-66_000, kind: "transfer", category: "Перевод", description: "Исходящий перевод СБП, Пётр Сергеевич К., +7 996 000-00-00", date: iso(9, 25)))
        // A utility bill paid once under a new name and a small purchase in a rare category are not one-offs.
        habits.append(op(-25_147, kind: "expense", category: "ЖКХ", description: "ЖКУ сентябрь, лицевой счёт", date: iso(9, 14)))
        habits.append(op(-1_200, kind: "expense", category: "Развлечения", description: "KDTS MAIAKOVSKII", date: iso(8, 15)))
        let habitual = FinancialEngine.monthForecast(habits, now: at(10, 6), calendar: calendar)
        require(habitual.historyMonths == 3, "April with a single expense is not representative; July to September are")
        require(habitual.baselineMonths.map(\.oneOffKopecks) == [66_000, 0, 0],
                "transfers to the same person every month and the utility bill with changing numbers are habits; only the new payee is one-off")
        require(habitual.baselineMonths[0].variableKopecks == 20_000 + 12_000 + 4_000 + 25_147 && habitual.baselineMonths[0].recurringKopecks == 22_905,
                "September keeps the usual transfers and groceries as variable; the monthly bill is recognised as recurring")

        let empty = FinancialEngine.monthForecast([], now: calendar.date(from: DateComponents(year: 2024, month: 3, day: 1))!, calendar: calendar)
        require(empty.elapsedDays == 1 && empty.projectedExpenseKopecks == 0 && empty.projectedIncomeKopecks == 0 && empty.historyMonths == 0,
                "first day of an empty month")
    }

    static func testOperationSearch() {
        let restaurant = op(-155_500, kind: "expense", category: "Фастфуд", description: "Ресторан", date: "2024-02-05T10:00:00Z")
        let grocery = op(-143_693, kind: "expense", category: "Супермаркеты", description: "Пятёрочка", mcc: "5411", date: "2024-02-05T11:00:00Z")
        let deposit = op(1_100_000, kind: "refund", category: "Денежные переводы", description: "Пополнение наличными", date: "2024-02-04T10:00:00Z")
        func finds(_ operation: FinancialOperationInput, _ query: String) -> Bool { FinancialEngine.operationMatches(operation, query: query) }

        require(finds(grocery, "пятерочка") && finds(grocery, "ПЯТЁРОЧКА"), "title, any case, ё and е alike")
        require(finds(grocery, "супермаркет") && finds(grocery, "еда"), "bank category and the app's group")
        require(finds(grocery, "5411"), "MCC")
        require(finds(restaurant, "1555") && finds(restaurant, "1 555") && finds(restaurant, "1555,00") && finds(restaurant, "-1555"),
                "whole rubles in any spelling")
        require(finds(grocery, "1436,93") && finds(grocery, "1436"), "exact amount with kopecks, or its whole rubles")
        require(!finds(grocery, "1437") && !finds(restaurant, "155"), "a different number is not a match")
        require(finds(deposit, "пополнения") && finds(deposit, "доход"), "income subcategory and financial type")
        require(finds(grocery, "пятерочка 1436") && !finds(grocery, "пятерочка такси"), "every word has to match")
        require(!finds(grocery, "   "), "an empty query finds nothing")
    }

    static func testBackup() {
        let cash = AccountGroup(name: "Наличные")
        var history = SavedHistory()
        history.accountGroups = [cash]
        history.accounts = [Account(name: "Наличные", icon: "banknote", color: "green", groupID: cash.id,
                                    startBalanceKopecks: 1_500_000, startDate: Date(timeIntervalSince1970: 1_790_000_000))]
        history.statementOperationCount = 453
        do {
            let restored = try HistoryBackup.decode(HistoryBackup.encode(history))
            require(restored.accounts == history.accounts && restored.accountGroups == history.accountGroups, "accounts and groups survive a backup")
            require(restored.statementOperationCount == 453, "history fields survive a backup")
        } catch { require(false, "backup round trip failed: \(error)") }
        require((try? HistoryBackup.decode(Data("{\"operations\":[]}".utf8))) == nil, "a file that is not a backup is refused")
        // Data saved before accounts existed still decodes.
        let old = try? JSONDecoder().decode(SavedHistory.self, from: Data("{\"operations\":[]}".utf8))
        require(old != nil && old?.accounts == nil, "older saved history without accounts still opens")
    }

    static func testAccountBalance() {
        let since = BankDateParser.parse("2024-02-05T12:00:00Z")!
        let operations = [
            op(-1_000, kind: "expense", category: "Такси", date: "2024-02-05T11:59:00Z"),
            op(-2_000, kind: "expense", category: "Такси", date: "2024-02-05T12:00:00Z"),
            op(50_000, kind: "income", date: "2024-02-06T10:00:00Z"),
            op(-3_000, kind: "expense", status: "В обработке", category: "Супермаркеты", date: "2024-02-06T11:00:00Z"),
            op(-9_000, kind: "expense", status: "Отменена", category: "Супермаркеты", date: "2024-02-06T12:00:00Z"),
        ]
        require(FinancialEngine.accountBalance(startKopecks: 100_000, since: since, tracksBankCard: true, operations: operations) == 145_000,
                "card balance: start + movements from the moment it was entered, pending included, cancelled not")
        require(FinancialEngine.accountBalance(startKopecks: 100_000, since: since, tracksBankCard: false, operations: operations) == 100_000,
                "an account not linked to the card keeps its entered balance")
    }

    static func testAccountReorder() {
        let a = AccountGroup(name: "A"), b = AccountGroup(name: "B")
        func account(_ name: String, _ group: AccountGroup?) -> Account {
            Account(name: name, icon: "banknote", color: "gray", groupID: group?.id, startBalanceKopecks: 0, startDate: Date(timeIntervalSince1970: 0))
        }
        let a1 = account("a1", a), a2 = account("a2", a), b1 = account("b1", b), u1 = account("u1", nil)
        let groups = [a, b], accounts = [a1, a2, b1, u1]
        let items = AccountListItem.flatten(groups: groups, accounts: accounts)
        typealias I = AccountListItem
        require(items == [I.group(a.id), .account(a1.id), .account(a2.id), .group(b.id), .account(b1.id), .ungroupedHeader, .account(u1.id)],
                "flat list: each group with its accounts, then the ungrouped ones")
        func names(_ moved: [AccountListItem]) -> String {
            let result = AccountListItem.apply(moved, groups: groups, accounts: accounts)
            return result.groups.map(\.name).joined(separator: ",") + " | " +
                result.accounts.map { acc in "\(acc.name)@\(result.groups.first { $0.id == acc.groupID }?.name ?? "-")" }.joined(separator: ",")
        }
        require(names(AccountListItem.move(items, from: [2], to: 4)) == "A,B | a1@A,a2@B,b1@B,u1@-", "an account dragged under another header changes group")
        require(names(AccountListItem.move(items, from: [3], to: 0)) == "B,A | b1@B,a1@A,a2@A,u1@-", "a group dragged up takes its accounts along")
        require(names(AccountListItem.move(items, from: [3], to: 1)) == "B,A | b1@B,a1@A,a2@A,u1@-", "a group dropped inside another group's accounts lands before that group")
        require(names(AccountListItem.move(items, from: [0], to: 7)) == "B,A | b1@B,a1@A,a2@A,u1@-", "a group dragged to the end stays above the ungrouped accounts")
        require(names(AccountListItem.move(items, from: [0], to: 2)) == "A,B | a1@A,a2@A,b1@B,u1@-", "a group dropped inside its own block does not move")
        require(names(AccountListItem.move(items, from: [6], to: 1)) == "A,B | u1@A,a1@A,a2@A,b1@B", "an ungrouped account dragged into a group joins it")
        require(AccountListItem.move(items, from: [5], to: 0) == items, "the ungrouped header does not move")
    }

    static func testMonthReserve() {
        let forecast = FinancialEngine.MonthForecast(spentKopecks: 24_913, incomeKopecks: 11_000, projectedExpenseKopecks: 129_940,
                                                     projectedExpenseLowKopecks: 117_098, projectedExpenseHighKopecks: 144_877,
                                                     projectedIncomeKopecks: 11_000, previousMonthIncomeKopecks: 252_693,
                                                     typicalIrregularIncomeKopecks: 224_000, irregularIncomeSoFarKopecks: 11_000,
                                                     oneOffKopecks: 0,
                                                     upcoming: [
                                                        FinancialEngine.UpcomingPayment(title: "Зарплата", amountKopecks: 50_000, date: Date(timeIntervalSince1970: 2_000_000_000),
                                                                                        isIncome: true, overdue: false),
                                                        FinancialEngine.UpcomingPayment(title: "Аванс", amountKopecks: 30_000, date: Date(timeIntervalSince1970: 1_900_000_000),
                                                                                        isIncome: true, overdue: true),
                                                        FinancialEngine.UpcomingPayment(title: "Аренда", amountKopecks: 20_000, date: Date(timeIntervalSince1970: 2_000_000_100),
                                                                                        isIncome: false, overdue: false),
                                                     ], historyMonths: 3, baselineMonths: [],
                                                     elapsedDays: 6, daysInMonth: 31)
        let reserve = FinancialEngine.monthReserve(balanceKopecks: 80_460, forecast: forecast)
        require(forecast.expectedIncomeLeftKopecks == 50_000, "a regular income whose day passed without it arriving is not counted")
        require(reserve == 80_460 - (129_940 - 24_913) + 50_000, "reserve = balance minus the spending still expected plus the regular income still expected")
        let range = FinancialEngine.monthReserveRange(balanceKopecks: 80_460, forecast: forecast)
        require(range.low == 80_460 - (144_877 - 24_913) + 50_000 && range.high == 80_460 - (117_098 - 24_913) + 50_000
                && range.low <= reserve && reserve <= range.high, "the range follows the low and high spending")
        require(FinancialEngine.monthReserveWithTypicalIncome(balanceKopecks: 80_460, forecast: forecast) == reserve + (224_000 - 11_000),
                "with the usual irregular income only the part that has not come yet is added")
        require(FinancialEngine.reserveStatus(FinancialEngine.monthReserve(balanceKopecks: 10_000, forecast: forecast), bufferKopecks: 25_000) == .short,
                "a negative reserve is short")
        require(FinancialEngine.reserveStatus(reserve, bufferKopecks: 30_000) == .tight, "a reserve below the buffer is tight")
        require(FinancialEngine.reserveStatus(8_400, bufferKopecks: 25_000) == .tight, "below the buffer is tight")
        require(FinancialEngine.reserveStatus(25_000, bufferKopecks: 25_000) == .fine, "at least the buffer is fine")
        require(FinancialEngine.reserveStatus(0, bufferKopecks: 25_000) == .tight, "zero is tight, not short")
    }

    static func testReserveAccounts() {
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        let group = AccountGroup(name: "Копилки")
        let card = Account(name: "Карта", icon: "creditcard", color: "yellow", startBalanceKopecks: 10_000, startDate: day)
        let savings = Account(name: "Копилка", icon: "banknote", color: "green", groupID: group.id, startBalanceKopecks: 80_000, startDate: day)
        let hidden = Account(name: "Скрытый", icon: "banknote", color: "gray", startBalanceKopecks: 5_000, startDate: day, showsBalance: false)
        var history = SavedHistory()
        history.accountGroups = [group]
        history.accounts = [card, savings, hidden]
        require(history.reserveBalanceKopecks == 90_000, "by default the reserve counts every account of the balance")
        history.setReserveCounting(false, accountIDs: [savings.id])
        require(history.reserveBalanceKopecks == 10_000, "money put aside is out of the reserve")
        require(history.accounts?.first { $0.id == savings.id }?.contributesToBalance(groups: [group]) == true,
                "but it stays in the current balance")
        history.setReserveCounting(true, accountIDs: [savings.id, hidden.id])
        require(history.reserveBalanceKopecks == 90_000, "an account that is not in the balance never enters the reserve")
        do {
            let restored = try HistoryBackup.decode(HistoryBackup.encode(history))
            require(restored.accounts == history.accounts, "the choice survives a backup")
            let old = try JSONDecoder().decode(Account.self, from: Data("""
                {"id":"00000000-0000-0000-0000-000000000001","name":"Старый","icon":"banknote","color":"green","startBalanceKopecks":0,"startDate":0,"showsBalance":true,"tracksBankCard":false}
                """.utf8))
            require(old.countsInReserve == nil && old.contributesToReserve(groups: []), "old accounts are counted")
        } catch { require(false, "reserve accounts backup failed: \(error)") }
    }

    static func testManualOperations() {
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        let cash = Account(name: "Наличные", icon: "banknote", color: "green", startBalanceKopecks: 500_000, startDate: day)
        let card = Account(name: "Карта", icon: "creditcard", color: "yellow", startBalanceKopecks: 1_000_000, startDate: day, tracksBankCard: true)
        let coffee = ManualOperation(kind: .expense, amountKopecks: 25_000, date: day.addingTimeInterval(60), accountID: cash.id,
                                     group: "Еда", subcategory: "Кафе и рестораны", note: "Кофе")
        let gift = ManualOperation(kind: .income, amountKopecks: 300_000, date: day.addingTimeInterval(120), accountID: cash.id,
                                   subcategory: "Переводы от других", note: "Подарок")
        let toCard = ManualOperation(kind: .transfer, amountKopecks: 100_000, date: day.addingTimeInterval(180), accountID: cash.id, toAccountID: card.id)
        let before = ManualOperation(kind: .expense, amountKopecks: 9_900, date: day.addingTimeInterval(-60), accountID: cash.id,
                                     group: "Еда", subcategory: "Супермаркеты")
        let manual = [coffee, gift, toCard, before]

        let coffeeInput = coffee.bankOperation.financialInput
        require(FinancialEngine.classify(coffeeInput).type == .expense, "manual expense is an expense")
        require(FinancialEngine.expenseCategory(for: coffeeInput) == FinanceCategoryPath(group: "Еда", subcategory: "Кафе и рестораны"),
                "the chosen category wins over the text guess")
        let giftInput = gift.bankOperation.financialInput
        require(FinancialEngine.classify(giftInput).type == .income && FinancialEngine.incomeCategory(for: giftInput) == "Переводы от других",
                "manual income keeps its chosen subcategory")
        require(FinancialEngine.classify(toCard.bankOperation.financialInput).type == .internalTransfer, "a transfer between own accounts is a movement")
        require(coffee.bankOperation.isManual && coffee.bankOperation.manualID == coffee.id, "the record points back to its manual operation")

        var history = SavedHistory()
        history.manualOperations = manual
        let interval = DateInterval(start: day.addingTimeInterval(-3_600), end: day.addingTimeInterval(3_600))
        let report = FinancialEngine.report(history.allOperations.map(\.financialInput), in: interval)
        require(report.incomeKopecks == 300_000 && report.netExpenseKopecks == 25_000 + 9_900,
                "manual income and expenses enter the report; the transfer does not")

        require(cash.balance(bankOperations: [], manual: manual) == 500_000 - 25_000 + 300_000 - 100_000,
                "cash balance: entered balance, then expenses, income and transfers from its start date; earlier entries are already in it")
        require(card.balance(bankOperations: [], manual: manual) == 1_000_000,
                "the scanned card is moved only by the bank, never by manual entries")
        do {
            let restored = try HistoryBackup.decode(HistoryBackup.encode(history))
            require(restored.manualOperations == manual, "manual operations survive a backup")
        } catch { require(false, "backup with manual operations failed: \(error)") }
    }

    static func testGroupBalanceVisibility() {
        do {
            let legacy = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Legacy\"}".utf8)
            var group = try JSONDecoder().decode(AccountGroup.self, from: legacy)
            let day = BankDateParser.parse("2032-06-02T00:00:00Z")!
            var cash = Account(name: "Cash", icon: "banknote", color: "orange", groupID: group.id,
                               startBalanceKopecks: 100_000, startDate: day)
            let other = Account(name: "Other", icon: "wallet.pass", color: "blue", groupID: nil,
                                startBalanceKopecks: 200_000, startDate: day)
            require(cash.contributesToBalance(groups: [group]), "old groups remain included without the new optional field")
            group.includesInBalance = false
            require(!cash.contributesToBalance(groups: [group]), "a hidden group excludes all of its accounts")
            require(other.contributesToBalance(groups: [group]), "ungrouped accounts are unaffected")
            require(cash.contributesToBalance(groups: []), "deleting a group makes its orphaned accounts included again")
            var history = SavedHistory()
            history.accounts = [cash, other]
            history.accountGroups = [group]
            let expense = ManualOperation(kind: .expense, amountKopecks: 25_000, date: day.addingTimeInterval(60),
                                          accountID: cash.id, group: "Еда", subcategory: "Кафе и рестораны")
            history.manualOperations = [expense]
            let restored = try HistoryBackup.decode(HistoryBackup.encode(history))
            require(restored.accountGroups?.first?.includesInBalance == false, "group visibility survives a backup")
            let total = (restored.accounts ?? []).filter { $0.contributesToBalance(groups: restored.accountGroups ?? []) }
                .reduce(Int64(0)) { $0 + $1.balance(bankOperations: [], manual: restored.manualOperations ?? []) }
            require(total == 200_000, "overall balance excludes the hidden group")
            require(cash.balance(bankOperations: [], manual: [expense]) == 75_000, "hidden accounts still keep their actual balances")
            require(FinancialEngine.report(restored.allOperations.map(\.financialInput),
                                          in: DateInterval(start: day, duration: 86400)).netExpenseKopecks == 25_000,
                    "hiding a balance group must not hide its expenses from reports")
            group.includesInBalance = true
            cash.showsBalance = false
            require(!cash.contributesToBalance(groups: [group]), "showing a group preserves each account's own visibility setting")
        } catch { require(false, "group visibility regression failed: \(error)") }
    }

    static func testBackdatedManualOperation() {
        let now = BankDateParser.parse("2032-06-03T10:00:00Z")!
        let yesterday = now.addingTimeInterval(-86400)
        let account = Account(name: "Cash", icon: "banknote", color: "green", groupID: nil,
                              startBalanceKopecks: 100_000, startDate: yesterday.addingTimeInterval(-86400))
        let expense = ManualOperation(kind: .expense, amountKopecks: 25_000, date: yesterday,
                                      accountID: account.id, group: "Еда", subcategory: "Кафе и рестораны")
        var history = SavedHistory()
        history.accounts = [account]
        history.manualOperations = [expense]
        do {
            let restored = try HistoryBackup.decode(HistoryBackup.encode(history))
            require(restored.manualOperations == [expense], "yesterday's manual expense persists with its exact date")
            let operation = restored.allOperations[0]
            require(BankDateParser.parse(operation.occurredAt) == yesterday, "history keeps yesterday's date")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let yesterdayInterval = historyInterval(.custom(from: yesterday, through: yesterday), now: now, calendar: calendar)
            require(yesterdayInterval.contains(yesterday), "the selected past day reveals the saved expense")
            require(FinancialEngine.report(restored.allOperations.map(\.financialInput), in: yesterdayInterval).netExpenseKopecks == 25_000,
                    "yesterday's expense appears in its period report")
            require(account.balance(bankOperations: [], manual: restored.manualOperations ?? []) == 75_000,
                    "yesterday's expense changes an account opened before that date")
        } catch { require(false, "backdated manual expense failed: \(error)") }
    }

    static func bankOp(_ identity: String, _ amount: Int64, description: String, mcc: String? = nil,
                       kind: String = "expense", date: String = "2032-06-02T10:00:00Z") -> BankOperation {
        BankOperation(identity: identity, occurredAt: date, timePrecision: "exact", description: description,
                      amountKopecks: amount, currency: "RUB", status: "Выполнено", category: "Тест", mcc: mcc,
                      purpose: nil, paymentMethod: nil, providers: [], kind: kind)
    }

    static func testExpenseCategories() {
        let day = BankDateParser.parse("2032-06-02T00:00:00Z")!
        let interval = DateInterval(start: day, duration: 86400)
        let shop1 = bankOp("b1", -100_000, description: "ВкусВилл 0412", mcc: "5411")
        let shop2 = bankOp("b2", -50_000, description: "ВкусВилл 0977", mcc: "5411")
        let other = bankOp("b3", -30_000, description: "Перекрёсток", mcc: "5411")
        let salary = bankOp("b4", 900_000, description: "Зарплата", kind: "income")
        var history = SavedHistory()
        history.operations = [shop1, shop2, other, salary]
        let coffee = ManualOperation(kind: .expense, amountKopecks: 20_000, date: day.addingTimeInterval(3600),
                                     accountID: nil, group: "Еда", subcategory: "Кафе и рестораны")
        history.manualOperations = [coffee]

        // Untouched: the built-in tree, same results as before.
        require(history.expenseCategories == nil && history.expenseTaxonomy == .builtin, "no edits keep the built-in tree")
        let builtinReport = FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy)
        require(builtinReport.expenseLines.first?.children.first { $0.title == "Супермаркеты" }?.amountKopecks == 180_000,
                "built-in guess still applies without edits")
        let supermarkets = history.categoryTree[0].categories[0].id
        require(history.expenseCategoryID(for: shop1) == supermarkets, "a bank expense resolves to its built-in category id")
        require(history.expenseCategoryID(for: salary) == nil, "income has no expense category")

        // A new category and a payee rule move every expense of that payee, but not other shops.
        let food = history.categoryTree[0].id
        guard let healthyFood = history.addExpenseCategory(name: " Полезная еда ", groupID: food) else {
            return require(false, "a category is added")
        }
        require(history.expenseCategoryID(for: shop1) == supermarkets, "ids of the built-in tree survive the first edit")
        require(history.addExpenseCategory(name: "Полезная еда", groupID: food) == nil, "names are unique within a group")
        require(history.addExpenseCategory(name: "Еда/кафе", groupID: food) == nil, "a slash is not allowed in a name")
        require(history.addExpenseGroup(name: "Возвраты") == nil, "report rows cannot become groups")
        require(history.setExpenseCategory(healthyFood, for: shop1, forPayee: true), "a payee rule is made")
        require(history.categoryRules?.count == 1 && history.expenseCategoryID(for: shop2) == healthyFood,
                "the rule covers other operations of the same payee despite different numbers")
        require(history.expenseCategoryID(for: other) == supermarkets, "another payee keeps its category")
        require(!history.setExpenseCategory(healthyFood, for: salary, forPayee: false), "income cannot get an expense category")

        // One operation by hand wins over the rule.
        require(history.setExpenseCategory(supermarkets, for: shop2, forPayee: false), "a single operation is moved")
        require(history.expenseCategoryID(for: shop2) == supermarkets && history.expenseCategoryID(for: shop1) == healthyFood,
                "the single choice wins over the payee rule")
        var report = FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy)
        let foodLine = report.expenseLines.first { $0.title == "Еда" }
        require(foodLine?.children.map(\.title) == ["Супермаркеты", "Кафе и рестораны", "Полезная еда"],
                "categories follow the tree order, the new one last")
        require(foodLine?.children.first { $0.title == "Полезная еда" }?.amountKopecks == 100_000, "the rule moves the money in reports")
        require(report.netExpenseKopecks == 200_000, "changing categories never changes the totals")
        require(FinancialEngine.operationMatches(history.financialInput(for: shop1), query: "полезная"), "search finds the chosen category")

        // Renaming keeps rules and manual entries; moving a category changes its group in reports.
        let cafes = history.categoryTree[0].categories[1].id
        require(history.renameExpenseCategory(cafes, to: "Кафе"), "rename")
        require(history.manualOperations?.first?.subcategory == "Кафе", "a manual entry follows the rename")
        require(history.expenseCategoryID(for: history.allOperations.first { $0.isManual }!) == cafes, "the manual entry stays in its category")
        require(history.renameExpenseGroup(food, to: "Продукты"), "group rename")
        require(history.manualOperations?.first?.group == "Продукты", "a manual entry follows the group rename")
        require(!history.renameExpenseGroup(food, to: "Транспорт"), "group names are unique")
        guard let leisure = history.addExpenseGroup(name: "Досуг") else { return require(false, "a group is added") }
        require(history.moveExpenseCategory(cafes, toGroup: leisure, at: 0), "a category moves to another group")
        require(history.manualOperations?.first?.group == "Досуг", "a manual entry follows the move")
        require(history.moveExpenseGroup(leisure, to: 0), "groups reorder")
        report = FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy)
        require(report.expenseLines.first?.title == "Досуг" && report.expenseLines.first?.amountKopecks == 20_000,
                "a reordered group comes first in reports")

        // Deleting merges: the rule, single choices, built-in sources and manual entries go to the target.
        require(!history.deleteExpenseCategory(healthyFood, mergingInto: healthyFood), "cannot merge into itself")
        require(history.deleteExpenseCategory(healthyFood, mergingInto: supermarkets), "delete with merge")
        require(history.categoryRules?.first?.categoryID == supermarkets && history.expenseCategoryID(for: shop1) == supermarkets,
                "the rule follows the merge")
        require(history.deleteExpenseGroup(leisure, mergingInto: supermarkets), "delete a group")
        require(history.manualOperations?.first?.group == "Продукты" && history.manualOperations?.first?.subcategory == "Супермаркеты",
                "manual entries of a deleted group move to the target")
        require(history.expenseCategoryID(for: bankOp("b5", -5_000, description: "Кофейня", mcc: "5814")) == supermarkets,
                "built-in guesses of a deleted category land in the target")
        require(!history.deleteExpenseGroup(food, mergingInto: supermarkets), "a group cannot merge into its own category")
        report = FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy)
        require(report.netExpenseKopecks == 200_000, "totals survive every edit")

        history.removeCategoryRule(history.categoryRules![0].id)
        require(history.expenseCategoryID(for: shop1) == supermarkets && history.categoryRules?.isEmpty == true, "a rule can be removed")

        // Everything survives a backup, and an old backup without the new fields still opens.
        do {
            let restored = try HistoryBackup.decode(HistoryBackup.encode(history))
            require(restored.expenseCategories == history.expenseCategories && restored.categoryOverrides == history.categoryOverrides,
                    "the tree and choices survive a backup")
            let old = try JSONDecoder().decode(SavedHistory.self, from: Data("{\"operations\":[]}".utf8))
            require(old.expenseCategories == nil && old.categoryTree == ExpenseCategoryGroup.builtin, "old data opens with the built-in tree")
        } catch { require(false, "category backup failed: \(error)") }
    }

    static func testFixedCostGroups() {
        // A big payment in a group marked as fixed costs is never a one-off in the forecast.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = BankDateParser.parse("2032-06-20T10:00:00Z")!
        var inputs: [FinancialOperationInput] = []
        for month in 1...5 {
            for day in [3, 10, 17] {
                inputs.append(op(-200_000, kind: "expense", description: "Магазин", mcc: "5411",
                                 date: String(format: "2032-%02d-%02dT10:00:00Z", month, day)))
            }
        }
        var big = op(-3_000_000, kind: "expense", description: "Ремонт", date: "2032-06-05T10:00:00Z")
        big.categoryPath = "Дом/Ремонт"
        inputs.append(big)
        var plain = ExpenseTaxonomy.builtin
        plain.groups.append(.init(name: "Дом", subcategories: ["Ремонт"], isFixedCosts: false))
        var fixed = plain
        fixed.groups[fixed.groups.count - 1].isFixedCosts = true
        let asOneOff = FinancialEngine.monthForecast(inputs, now: now, calendar: calendar, taxonomy: plain)
        let asFixed = FinancialEngine.monthForecast(inputs, now: now, calendar: calendar, taxonomy: fixed)
        require(asOneOff.oneOffKopecks == 3_000_000, "a big rare payment is a one-off normally")
        require(asFixed.oneOffKopecks == 0, "a fixed-cost group is never a one-off")
    }

    static func testIncomeCategories() {
        let day = BankDateParser.parse("2032-06-02T00:00:00Z")!
        let interval = DateInterval(start: day, duration: 86400)
        let pay1 = bankOp("i1", 100_000, description: "Перевод от Иванов И. 0412", kind: "income")
        let pay2 = bankOp("i2", 50_000, description: "Перевод от Иванов И. 0977", kind: "income")
        let other = bankOp("i3", 30_000, description: "Магазин возврат подарка", kind: "income")
        let own = bankOp("i4", 70_000, description: "Перевод между счетами одного клиента", kind: "transfer")
        let refund = bankOp("i5", 20_000, description: "Возврат покупки", kind: "refund")
        let shop = bankOp("i6", -10_000, description: "Магазин", mcc: "5411")
        var history = SavedHistory()
        history.operations = [pay1, pay2, other, own, refund, shop]
        let before = FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy)
        let guessed = history.incomeCategory(for: pay1)
        require(guessed != nil, "an income has a category")
        require(history.incomeCategory(for: shop) == nil && history.incomeCategory(for: refund) == nil, "only income has an income category")

        require(history.setIncomeCategory("Зарплата и выплаты", for: pay1, forSender: true), "a sender rule is made")
        require(history.incomeCategory(for: pay2) == "Зарплата и выплаты", "the rule covers the same sender with other numbers")
        require(history.incomeCategory(for: other) != "Зарплата и выплаты", "another sender keeps its category")
        require(history.setIncomeCategory("Кэшбэк", for: pay2, forSender: false), "one income is moved")
        require(history.incomeCategory(for: pay2) == "Кэшбэк" && history.incomeCategory(for: pay1) == "Зарплата и выплаты",
                "the single choice wins over the rule")
        let after = FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy)
        require(after.incomeKopecks == before.incomeKopecks && after.netExpenseKopecks == before.netExpenseKopecks
                && after.movementKopecks == before.movementKopecks && after.refundsKopecks == before.refundsKopecks,
                "choosing categories never changes the totals")
        require(after.incomeLines.first { $0.title == "Зарплата и выплаты" }?.amountKopecks == 100_000, "the money moves in reports")
        require(FinancialEngine.operationMatches(history.financialInput(for: pay1), query: "зарплата"), "search finds the chosen category")

        // Nothing but income can get an income category.
        let snapshot = history.incomeCategoryOverrides
        require(!history.setIncomeCategory("Кэшбэк", for: refund, forSender: true), "a refund never becomes income")
        require(!history.setIncomeCategory("Кэшбэк", for: own, forSender: true), "an own transfer never becomes income")
        require(!history.setIncomeCategory("Кэшбэк", for: shop, forSender: false), "an expense never becomes income")
        require(!history.setIncomeCategory("Несуществующая", for: pay1, forSender: false), "unknown category is rejected")
        let pending = BankOperation(identity: "i7", occurredAt: "2032-06-02T10:00:00Z", timePrecision: "exact", description: "Перевод от Иванов И.",
                                    amountKopecks: 5_000, currency: "RUB", status: "В обработке", category: "Тест", mcc: nil, purpose: nil,
                                    paymentMethod: nil, providers: [], kind: "income")
        require(!history.setIncomeCategory("Кэшбэк", for: pending, forSender: false), "a pending operation never becomes income")
        let split = bankOp("i8", -5_000, description: "Yandex*5399*Ysplit")
        require(!history.setIncomeCategory("Кэшбэк", for: split, forSender: false), "Split never becomes income")
        require(history.incomeCategoryOverrides == snapshot && history.incomeCategoryRules?.count == 1, "a refused change saves nothing")

        // A rule on a sender does not leak into refunds or transfers that share its words.
        var tricky = history
        tricky.operations.append(bankOp("i9", 9_000, description: "Перевод от Иванов И.", kind: "refund"))
        require(FinancialEngine.report(tricky.financialInputs, in: interval, taxonomy: tricky.expenseTaxonomy).refundsKopecks == before.refundsKopecks + 9_000,
                "a refund of the same sender stays a refund")

        // A manual income takes the choice directly.
        let manual = ManualOperation(kind: .income, amountKopecks: 10_000, date: day.addingTimeInterval(60), accountID: nil, subcategory: "Прочие доходы")
        history.manualOperations = [manual]
        require(history.setIncomeCategory("Кэшбэк", for: manual.bankOperation, forSender: true), "manual income is changed")
        require(history.manualOperations?.first?.subcategory == "Кэшбэк" && history.incomeCategoryRules?.count == 1, "a manual income makes no rule")

        history.removeIncomeCategoryRule(history.incomeCategoryRules![0].id)
        require(history.incomeCategory(for: pay1) == guessed, "removing the rule returns the old guess")
        require(history.incomeCategory(for: pay2) == "Кэшбэк", "single choices stay after the rule is removed")

        do {
            let restored = try HistoryBackup.decode(HistoryBackup.encode(history))
            require(restored.incomeCategoryOverrides == history.incomeCategoryOverrides, "income choices survive a backup")
            let old = try JSONDecoder().decode(SavedHistory.self, from: Data("{\"operations\":[]}".utf8))
            require(old.incomeCategoryRules == nil && old.incomeCategoryOverrides == nil, "old data opens without the new fields")
        } catch { require(false, "income category backup failed: \(error)") }
    }

    static func testSaveStatementSource() {
        let start = BankDateParser.parse("2032-06-01T00:00:00Z")!
        let interval = DateInterval(start: start, end: BankDateParser.parse("2032-07-01T00:00:00Z")!)
        let card = [op(-50_000, kind: "internal_transfer", description: "Перевод между счетами одного клиента"),
                    op(10_000, kind: "internal_transfer", description: "Перевод между счетами одного клиента"),
                    op(-2_000, kind: "expense")]
        var depositIn = op(50_000, kind: "internal_transfer", description: "Перевод между счетами одного клиента")
        depositIn.paymentMethod = "Сейв (выписка)"
        var depositOut = op(-10_000, kind: "internal_transfer", description: "Перевод между счетами одного клиента")
        depositOut.paymentMethod = "Сейв (выписка)"
        var interest = op(123, kind: "interest_income", description: "Капитализация процентов")
        interest.paymentMethod = "Сейв (выписка)"
        let both = card + [depositIn, depositOut, interest]
        let before = FinancialEngine.report(card, in: interval), after = FinancialEngine.report(both, in: interval)
        require(after.incomeKopecks == before.incomeKopecks + 123 && after.netExpenseKopecks == before.netExpenseKopecks, "both statements add only deposit interest to report")
        require(after.movementKopecks == before.movementKopecks && after.bankDebitKopecks == before.bankDebitKopecks
                && after.bankCreditKopecks == before.bankCreditKopecks, "the deposit side of own transfers is not counted twice in movements or card turnover")
        let save = FinancialEngine.saveAccountSummary(both, in: interval), old = FinancialEngine.saveAccountSummary(card, in: interval)
        require(save.toSaveKopecks == old.toSaveKopecks && save.fromSaveKopecks == old.fromSaveKopecks && save.interestIncomeKopecks == old.interestIncomeKopecks + 123, "deposit transfers never double Save totals")
        require(FinancialEngine.accountBalance(startKopecks: 100_000, since: start, tracksBankCard: true, operations: both) == FinancialEngine.accountBalance(startKopecks: 100_000, since: start, tracksBankCard: true, operations: card), "deposit rows do not move card balance")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = BankDateParser.parse("2032-06-15T00:00:00Z")!
        let forecast = FinancialEngine.monthForecast(card, now: now, calendar: calendar)
        let combinedForecast = FinancialEngine.monthForecast(both, now: now, calendar: calendar)
        require(combinedForecast.spentKopecks == forecast.spentKopecks && combinedForecast.projectedExpenseKopecks == forecast.projectedExpenseKopecks, "deposit transfers do not affect expense forecast")
        require(combinedForecast.incomeKopecks == forecast.incomeKopecks + 123, "forecast includes only deposit interest")
    }

    static func testUncategorizedReview() {
        let a = bankOp("review-a", -10_000, description: "Непонятный магазин")
        let b = bankOp("review-b", -5_000, description: "Непонятный магазин", date: "2032-06-03T10:00:00Z")
        let ruled = bankOp("review-rule", -1_000, description: "Магазин с правилом")
        let unnamed = bankOp("review-no-title", -900, description: "12345")
        let unnamed2 = bankOp("review-no-title-2", -800, description: "12345")
        let income = bankOp("review-income", 7_000, description: "Отправитель", kind: "income")
        let income2 = bankOp("review-income-2", 3_000, description: "Отправитель", kind: "income")
        let food = bankOp("review-food", -400, description: "Продукты", mcc: "5411")
        let transfer = bankOp("review-transfer", -20_000, description: "Перевод", kind: "internal_transfer")
        let refund = bankOp("review-refund", 300, description: "Возврат", kind: "refund")
        var history = SavedHistory()
        history.operations = [a, b, ruled, unnamed, unnamed2, income, income2, food, transfer, refund]
        let other = UncategorizedReview.otherExpenseID
        require(history.setExpenseCategory(other, for: ruled, forPayee: true), "review fixture has a rule even for Other")
        let groups = UncategorizedReview.groups(history)
        require(groups.count == 4, "review combines payees, keeps empty names individual and excludes known/rule/transfer/refund")
        require(groups[0].amountKopecks == 15_000 && groups[0].operations.count == 2, "review sorts by magnitude and sums expense group")
        require(groups[0].latestDate == BankDateParser.parse(b.occurredAt), "review shows latest date")
        require(groups.filter { $0.kind == .income }.first?.amountKopecks == 10_000, "review includes Other income with correct sum")
        require(groups.filter { $0.key.isEmpty }.count == 2 && groups.filter { $0.key.isEmpty }.allSatisfy { !$0.appliesToAll }, "unnamed transactions never form an all-payee rule")
        let interval = DateInterval(start: BankDateParser.parse("2032-06-01T00:00:00Z")!, duration: 30 * 86400)
        let before = FinancialEngine.report(history.financialInputs, in: interval)
        let category = history.categoryTree[0].categories[0].id
        require(history.setExpenseCategory(category, for: a, forPayee: true), "review expense assignment creates rule")
        require(!UncategorizedReview.groups(history).contains { $0.id == groups[0].id }, "assigned expense payee leaves review")
        require(history.setIncomeCategory("Зарплата и выплаты", for: income, forSender: true), "review income assignment creates rule")
        require(!UncategorizedReview.groups(history).contains { $0.kind == .income }, "assigned income sender leaves review")
        let after = FinancialEngine.report(history.financialInputs, in: interval)
        require(before.netExpenseKopecks == after.netExpenseKopecks && before.incomeKopecks == after.incomeKopecks,
                "review category changes preserve income and expense totals")
        history.operations.append(bankOp("review-future-expense", -200, description: a.description))
        history.operations.append(bankOp("review-future-income", 500, description: income.description, kind: "income"))
        require(!UncategorizedReview.groups(history).contains { $0.key == FinancialEngine.counterpartyKey(a.description)
                    || $0.key == FinancialEngine.counterpartyKey(income.description) }, "review rules classify future operations as well")
        require(history.setExpenseCategory(category, for: unnamed, forPayee: false), "unnamed review assigns only one operation")
        require(UncategorizedReview.groups(history).filter { $0.key.isEmpty }.count == 1, "other unnamed operation remains")
        var renamed = SavedHistory()
        renamed.operations = [a]
        require(renamed.renameExpenseCategory(other, to: "Разобрать"), "review fixture renames built-in category")
        require(renamed.moveExpenseCategory(other, toGroup: renamed.categoryTree[0].id, at: 0), "review fixture moves category")
        require(UncategorizedReview.groups(renamed).count == 1, "review uses stable category id after rename and move")
        let date = BankDateParser.parse(a.occurredAt)!
        renamed = SavedHistory()
        renamed.manualOperations = [
            ManualOperation(kind: .expense, amountKopecks: 100, date: date, accountID: nil, group: "Другое", subcategory: "Прочее", note: "Одинаковый комментарий"),
            ManualOperation(kind: .expense, amountKopecks: 200, date: date, accountID: nil, group: "Другое", subcategory: "Прочее", note: "Одинаковый комментарий")
        ]
        let manual = UncategorizedReview.groups(renamed)
        require(manual.count == 2 && manual.allSatisfy { !$0.appliesToAll }, "manual operations stay individual because existing setters do not create rules for them")
    }

    static func testCardToSaveTransfer() {
        // The bank's shared history lists a card → Save transfer as two rows titled after the Save account.
        let day = BankDateParser.parse("2026-10-07T00:00:00Z")!
        let start = day.addingTimeInterval(-86400)
        var cardRow = op(-7_000_000, kind: "internal_transfer", category: "Переводы между своими счетами",
                         description: "Счёт в Сейвах", date: "2026-10-07T09:04:56.635Z")
        cardRow.paymentMethod = "Карта Пэй"
        var saveRow = op(7_000_000, kind: "internal_transfer", category: "Переводы между своими счетами",
                         description: "Счёт в Сейвах", date: "2026-10-07T09:04:56.874Z")
        saveRow.paymentMethod = "Счёт в Сейвах"
        let shop = op(-100_000, kind: "expense", description: "Магазин", mcc: "5411", date: "2026-10-07T10:00:00Z")
        let card = FinancialEngine.accountBalance(startKopecks: 8_046_052, since: start, tracksBankCard: true,
                                                  operations: [cardRow, saveRow, shop])
        require(card == 8_046_052 - 7_000_000 - 100_000, "the card takes only its own part of the transfer")
        let interval = DateInterval(start: day, duration: 86400)
        let report = FinancialEngine.report([cardRow, saveRow, shop], in: interval)
        require(report.incomeKopecks == 0 && report.netExpenseKopecks == 100_000 && report.refundsKopecks == 0,
                "a card ↔ Save transfer is neither income, expense nor refund")
        require(report.movementKopecks == 7_000_000, "the movement is counted once, not for both rows")

        // Rows saved before the scanner knew the account: the old «Переводы другим» and «Возврат» guesses are gone.
        let oldCard = op(-7_000_000, kind: "transfer", category: "Перевод", description: "Счёт в Сейвах", date: "2026-10-07T09:04:56.635Z")
        let oldSave = op(7_000_000, kind: "refund", category: "Перевод", description: "Счёт в Сейвах", date: "2026-10-07T09:04:56.874Z")
        require(FinancialEngine.classify(oldCard).type == .internalTransfer && FinancialEngine.classify(oldSave).type == .internalTransfer,
                "old Save rows are own transfers, not a payment to others or a refund")
        let oldReport = FinancialEngine.report([oldCard, oldSave], in: interval)
        require(oldReport.netExpenseKopecks == 0 && oldReport.refundsKopecks == 0 && oldReport.incomeKopecks == 0,
                "old Save rows change no totals")

        // The same pair when the scanner could not tell the accounts apart: the title names the destination.
        let card80 = FinancialEngine.accountBalance(startKopecks: 8_046_052, since: start, tracksBankCard: true,
                                                    operations: [oldCard, oldSave])
        require(card80 == 8_046_052 - 7_000_000, "card → Save without account tags: the card keeps only its debit (10 460,52 ₽)")
        require(FinancialEngine.report([oldCard, oldSave], in: interval).movementKopecks == 7_000_000, "the untagged pair is one movement")
        let back = op(-500_000, kind: "internal_transfer", description: "Счёт в Сейвах → Карта Пэй", date: "2026-10-07T12:00:00.100Z")
        let backCard = op(500_000, kind: "internal_transfer", description: "Счёт в Сейвах → Карта Пэй", date: "2026-10-07T12:00:00.400Z")
        require(FinancialEngine.accountBalance(startKopecks: 0, since: start, tracksBankCard: true, operations: [back, backCard]) == 500_000,
                "Save → card: the card keeps the credit")
        let lonely = op(7_000_000, kind: "refund", category: "Перевод", description: "Счёт в Сейвах", date: "2026-10-05T09:00:00Z")
        require(FinancialEngine.accountBalance(startKopecks: 0, since: start.addingTimeInterval(-7 * 86400), tracksBankCard: true,
                                               operations: [lonely]) == 7_000_000, "a row without its pair is never dropped")

        // Save interest stays income; an arrow title between own accounts is a transfer.
        var interest = op(214, kind: "interest_income", description: "Выплата процентов", date: "2026-10-07T03:00:00Z")
        interest.paymentMethod = "Счёт в Сейвах"
        require(FinancialEngine.classify(interest).type == .interestIncome, "Save interest is still income")
        require(FinancialEngine.classify(op(-50_000, kind: "transfer", description: "Карта Пэй → Счёт в Сейвах")).type == .internalTransfer,
                "an arrow title card → Save is an own transfer")
        var paidFromSave = op(-2_500, kind: "transfer", description: "Исходящий перевод СБП, Тестовый получатель")
        paidFromSave.paymentMethod = "Сейв (выписка)"
        require(FinancialEngine.classify(paidFromSave).type == .expense, "a payment to someone else from the Save stays an expense")

        // The manual entry of the same transfer moves the hand-kept Save account, never the scanned card.
        let cardAccount = Account(name: "Яндекс банк", icon: "creditcard", color: "yellow", startBalanceKopecks: 8_046_052,
                                  startDate: start, tracksBankCard: true)
        let saveAccount = Account(name: "Сейв", icon: "building.columns", color: "blue", startBalanceKopecks: 214, startDate: start)
        let manual = ManualOperation(kind: .transfer, amountKopecks: 7_000_000, date: BankDateParser.parse("2026-10-07T09:06:00Z")!,
                                     accountID: cardAccount.id, toAccountID: saveAccount.id)
        require(cardAccount.balance(bankOperations: [cardRow, saveRow, shop], manual: [manual]) == 8_046_052 - 7_000_000 - 100_000,
                "the card is not moved twice by the manual entry")
        require(saveAccount.balance(bankOperations: [cardRow, saveRow, shop], manual: [manual]) == 214 + 7_000_000,
                "the Save account receives the transfer once")
    }

    static func testOperationLooks() {
        let first = bankOp("l1", -30_000, description: "IP TESTOV A.A. 0412", mcc: "5814")
        let second = bankOp("l2", -45_000, description: "IP TESTOV A.A. 0977", mcc: "5814")
        let other = bankOp("l3", -10_000, description: "Магазин", mcc: "5411")
        var history = SavedHistory()
        history.operations = [first, second, other]
        let before = FinancialEngine.report(history.financialInputs, in: DateInterval(start: .distantPast, end: .distantFuture))
        require(history.look(for: first).isEmpty, "no look until the user sets one")

        history.setLook(title: " Кофейня у дома ", icon: "cup.and.saucer", for: first, forPayee: true)
        require(history.look(for: second).title == "Кофейня у дома" && history.look(for: second).icon == "cup.and.saucer",
                "a payee rule covers the payee's other operations despite different numbers")
        require(history.look(for: other).isEmpty, "another payee keeps the bank title")

        history.setLook(title: "Обед с коллегами", icon: nil, for: second, forPayee: false)
        require(history.look(for: second).title == "Обед с коллегами" && history.look(for: second).icon == "cup.and.saucer",
                "a single choice wins over the rule for what it sets, the rule fills the rest")
        history.setNote("  оплатил за двоих ", for: second)
        require(history.look(for: second).note == "оплатил за двоих" && history.look(for: first).note == nil, "a comment belongs to one operation")

        history.setLook(title: "", icon: nil, for: first, forPayee: true)
        require(history.payeeLookRules?.isEmpty == true && history.look(for: first).title == nil, "clearing the rule returns the bank title")
        history.setLook(title: "IP TESTOV A.A. 0412", icon: nil, for: first, forPayee: false)
        require(history.operationLooks?[first.identity] == nil, "the bank's own title is not stored as a custom one")
        history.setNote("", for: second)
        require(history.operationLooks?[second.identity]?.note == nil && history.look(for: second).title == "Обед с коллегами",
                "removing the comment keeps the title")

        let after = FinancialEngine.report(history.financialInputs, in: DateInterval(start: .distantPast, end: .distantFuture))
        require(after.netExpenseKopecks == before.netExpenseKopecks && after.expenseLines.map(\.amountKopecks) == before.expenseLines.map(\.amountKopecks),
                "titles, icons and comments never change categories or totals")
        do {
            let restored = try HistoryBackup.decode(HistoryBackup.encode(history))
            require(restored.operationLooks == history.operationLooks && restored.payeeLookRules == history.payeeLookRules,
                    "looks survive a backup")
        } catch { require(false, "look backup failed: \(error)") }
    }

    static func testOtherShrinks() {
        func path(_ description: String, category: String = "Не определено", kind: String = "expense", mcc: String? = nil) -> String {
            let p = FinancialEngine.expenseCategory(for: op(-10_000, kind: kind, category: category, description: description, mcc: mcc))
            return p.group + "/" + p.subcategory
        }
        // Statement rows have no MCC and Latin titles.
        require(path("Оплата товаров и услуг MAGNIT MM TEST") == "Еда/Супермаркеты", "Magnit in Latin is a supermarket")
        require(path("Оплата товаров и услуг YANDEX*5411*DK") == "Еда/Супермаркеты", "MCC inside a Yandex title")
        require(path("Оплата товаров и услуг YANDEX*5399*MARKET") == "Покупки/Маркетплейсы", "Yandex Market")
        require(path("Оплата товаров и услуг YANDEX*4121*FASTEN") == "Транспорт/Такси", "taxi by embedded MCC")
        require(path("Оплата товаров и услуг YANDEX*4215*DOSTAVKA") == "Другое/Доставка и курьеры", "courier by embedded MCC")
        require(path("Оплата товаров и услуг ETK77_CITY_TPP") == "Транспорт/Общественный транспорт", "city transport card")
        require(path("Оплата СБП QR (Лемана ПРО СБП онлайн)") == "Покупки/Дом и быт", "Lemana Pro")
        require(path("Оплата товаров и услуг LEMANAPROGPB088") == "Покупки/Дом и быт", "Lemana Pro in Latin")
        require(path("Оплата товаров и услуг APTEKA TEST 1") == "Обязательные/Здоровье", "pharmacy in Latin")
        require(path("Оплата товаров и услуг DZHINSY TUT") == "Покупки/Одежда", "clothes")
        require(path("Оплата СБП QR (Tutu_SBP4)") == "Другое/Путешествия", "tickets")
        // What cannot be known from the title stays where it was.
        require(path("Оплата СБП QR (Сервисы Яндекса)") == "Другое/Прочее", "Yandex services are not guessed")
        require(path("Оплата товаров и услуг IP TESTOV A.A.") == "Другое/Прочее", "a sole trader is not guessed")
        require(FinancialEngine.embeddedMCC("YANDEX*5411*DK") == "5411" && FinancialEngine.embeddedMCC("Магазин 5411") == "", "embedded MCC only between stars")
        // A real MCC wins over the title.
        require(path("YANDEX*5411*DK", mcc: "5812") == "Еда/Кафе и рестораны", "the card's own MCC wins")

        // Transfers to people: own group; ids of the old tree stay, so earlier choices keep their category.
        require(path("Исходящий перевод СБП, Тест Т.", category: "Перевод", kind: "transfer") == "Переводы/Переводы другим", "transfers have their own group")
        let tree = ExpenseCategoryGroup.builtin
        let transfers = tree.flatMap(\.categories).first { $0.name == "Переводы другим" }!
        require(transfers.id == UUID(uuidString: "00000000-0000-4000-8000-000005000005")!, "the transfers category keeps its old id")
        require(tree.flatMap(\.categories).first { $0.name == "Прочее" }!.id == UUID(uuidString: "00000000-0000-4000-8000-000005000007")!,
                "«Прочее» keeps its old id")
        require(tree.flatMap(\.categories).first { $0.name == "Комиссии" }!.id == UUID(uuidString: "00000000-0000-4000-8000-000005000006")!,
                "«Комиссии» keeps its old id")
        let ids = tree.flatMap { [$0.id] + $0.categories.map(\.id) }
        require(Set(ids).count == ids.count, "built-in ids are unique")

        // A manual entry saved with the old names and a tree edited before the change still find the category.
        var history = SavedHistory()
        let gift = ManualOperation(kind: .expense, amountKopecks: 5_000, date: Date(timeIntervalSince1970: 1_960_000_000), accountID: nil,
                                   group: "Другое", subcategory: "Переводы другим")
        history.manualOperations = [gift]
        require(history.expenseCategoryID(for: gift.bankOperation) == transfers.id, "old manual entries land in the transfers category")
        var oldTree = ExpenseTaxonomy.builtin.groups.map { $0 }
        oldTree.removeLast()
        oldTree[4].subcategories.insert("Переводы другим", at: 4)
        var edited = SavedHistory()
        edited.expenseCategories = oldTree.enumerated().map { groupIndex, group in
            ExpenseCategoryGroup(name: group.name, isFixedCosts: group.isFixedCosts,
                                 categories: group.subcategories.map { ExpenseCategory(name: $0, sources: [group.name + "/" + $0]) })
        }
        let person = bankOp("t1", -20_000, description: "Исходящий перевод СБП, Тест Т.", kind: "transfer")
        let oldID = edited.categoryTree[4].categories[4].id
        require(edited.expenseCategoryID(for: person) == oldID, "an edited old tree still resolves the new transfer path")
        edited.moveTransfersToOwnGroup()
        require(edited.categoryTree.first { $0.name == "Переводы" }?.categories.first?.id == oldID
                && !(edited.categoryTree.first { $0.name == "Другое" }!.categories.contains { $0.id == oldID }),
                "the edited tree moves transfers into their own group, same category")
        require(edited.transfersGroupMoved == true, "the move is remembered")
        edited.moveExpenseCategory(oldID, toGroup: edited.categoryTree.first { $0.name == "Другое" }!.id, at: 0)
        edited.moveTransfersToOwnGroup()
        require(edited.categoryTree.first { $0.name == "Другое" }!.categories.contains { $0.id == oldID }, "a move back by the user stays")
        // A damaged statement title names nobody: no payee rule may join such rows.
        let junk = "28.09.2026 в 16:39 28.09.2026 –232,00 ₽ –232,00 ₽"
        require(FinancialEngine.payeeRuleKey(junk) == "" && FinancialEngine.payeeRuleKey("АБ") == "", "no rule key without a real name")
        require(FinancialEngine.payeeRuleKey("Оплата товаров и услуг MAGNIT") == FinancialEngine.counterpartyKey("Оплата товаров и услуг MAGNIT"),
                "real names keep their key, so existing rules still apply")
        var damaged = SavedHistory()
        let junk1 = bankOp("j1", -22_200, description: junk), junk2 = bankOp("j2", -34_900, description: junk)
        damaged.operations = [junk1, junk2]
        let food = damaged.categoryTree[0].categories[0].id
        require(damaged.setExpenseCategory(food, for: junk1, forPayee: true), "a damaged row can still get a category")
        require((damaged.categoryRules ?? []).isEmpty && damaged.expenseCategoryID(for: junk1) == food && damaged.expenseCategoryID(for: junk2) != food,
                "but only for itself, never as a rule for every damaged row")
        damaged.setLook(title: "Магазин", icon: nil, for: junk1, forPayee: true)
        require((damaged.payeeLookRules ?? []).isEmpty && damaged.look(for: junk2).title == nil, "the same for own titles")
        require(UncategorizedReview.groups(damaged).allSatisfy { $0.operations.count == 1 }, "damaged rows are reviewed one by one")

        var untouched = SavedHistory()
        untouched.moveTransfersToOwnGroup()
        require(untouched.expenseCategories == nil, "the built-in tree is not materialized by the move")
    }

    static func testAccountMovements() {
        let start = BankDateParser.parse("2032-06-01T00:00:00Z")!
        let card = Account(name: "Карта", icon: "creditcard", color: "yellow", startBalanceKopecks: 100_000, startDate: start, tracksBankCard: true)
        let cash = Account(name: "Наличные", icon: "banknote", color: "green", startBalanceKopecks: 50_000, startDate: start)
        let save = Account(name: "Сейв", icon: "building.columns", color: "blue", startBalanceKopecks: 0, startDate: start)
        var history = SavedHistory()
        history.accounts = [card, cash, save]
        let before = bankOp("m0", -9_000, description: "Магазин", mcc: "5411", date: "2032-05-30T10:00:00Z")
        let shop = bankOp("m1", -10_000, description: "Магазин", mcc: "5411", date: "2032-06-02T10:00:00Z")
        var cancelled = bankOp("m2", -7_000, description: "Магазин", mcc: "5411", date: "2032-06-02T11:00:00Z")
        cancelled = BankOperation(identity: cancelled.identity, occurredAt: cancelled.occurredAt, timePrecision: "exact",
                                  description: cancelled.description, amountKopecks: cancelled.amountKopecks, currency: "RUB",
                                  status: "Отменено", category: "Тест", mcc: "5411", purpose: nil, paymentMethod: nil, providers: [], kind: "expense")
        let toSave = bankOp("m3", -20_000, description: "Счёт в Сейвах", kind: "internal_transfer", date: "2032-06-03T09:00:00.100Z")
        let saveSide = bankOp("m4", 20_000, description: "Счёт в Сейвах", kind: "internal_transfer", date: "2032-06-03T09:00:00.300Z")
        history.operations = [before, shop, cancelled, toSave, saveSide]
        let coffee = ManualOperation(kind: .expense, amountKopecks: 3_000, date: start.addingTimeInterval(86400), accountID: cash.id,
                                     group: "Еда", subcategory: "Кафе и рестораны")
        let deposit = ManualOperation(kind: .transfer, amountKopecks: 20_000, date: start.addingTimeInterval(2 * 86400 + 3600),
                                      accountID: card.id, toAccountID: save.id)
        let fromCash = ManualOperation(kind: .transfer, amountKopecks: 5_000, date: start.addingTimeInterval(3 * 86400),
                                       accountID: cash.id, toAccountID: save.id)
        history.manualOperations = [coffee, deposit, fromCash]

        let cardMoves = history.accountMovements(card)
        require(cardMoves.map(\.operation.identity) == ["m3", "m1"], "the card: its own rows from the start, newest first, no cancelled or Save side")
        require(cardMoves.map(\.delta) == [-20_000, -10_000], "card deltas are the bank amounts")
        let cashMoves = history.accountMovements(cash)
        require(cashMoves.map(\.delta) == [-5_000, -3_000], "cash: an expense and a transfer out")
        let saveMoves = history.accountMovements(save)
        require(saveMoves.map(\.delta) == [5_000, 20_000], "the Save receives both transfers as positive")

        for account in [card, cash, save] {
            let now = history.accountBalances(account, at: [.distantFuture])[0]
            require(now == account.balance(bankOperations: history.operations.map(\.financialInput), manual: history.manualOperations ?? []),
                    "the balance series ends at the account balance: \(account.name)")
        }
        let days = (0...4).map { start.addingTimeInterval(Double($0) * 86400) }
        require(history.accountBalances(cash, at: days) == [50_000, 50_000, 47_000, 47_000, 42_000], "cash balance day by day")
        require(history.accountBalances(card, at: [start.addingTimeInterval(-86400)]) == [100_000], "before the start the entered balance")
    }

    static func testReportSeries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day))!
        }
        let months = ReportSeries.intervals(selectedStart: date(2032, 6, 17), unit: .month, calendar: calendar)
        require(months.count == 12 && months.first?.start == date(2031, 7) && months.last?.start == date(2032, 6),
                "trend: twelve months ending with the selected month")
        for index in 1..<months.count {
            require(months[index - 1].end == months[index].start, "trend months have no gaps or overlap")
        }
        let year = ReportSeries.intervals(selectedStart: date(2032, 6, 17), unit: .year, calendar: calendar)
        require(year.count == 12 && year.first?.start == date(2032, 1) && year.last?.end == date(2033, 1),
                "year trend contains January through December of that year")
        let days = ReportSeries.intervals(selectedStart: date(2032, 3, 3), unit: .day, calendar: calendar)
        require(days.count == 14 && days.first?.start == date(2032, 2, 19) && days.last?.end == date(2032, 3, 4),
                "day trend contains fourteen days, including leap February")
        for index in 1..<days.count {
            require(days[index - 1].end == days[index].start, "trend days have no gaps or overlap")
        }
        let inputs = [op(-10_000, kind: "expense", date: "2032-05-02T10:00:00Z"),
                      op(6_000, kind: "income", date: "2032-05-04T10:00:00Z"),
                      op(-30_000, kind: "expense", date: "2032-06-02T10:00:00Z")]
        let periods = ReportSeries.periods(inputs: inputs, intervals: months, taxonomy: .builtin)
        require(ReportSeries.average(periods) == ReportSeries.Average(incomeKopecks: 3_000, expenseKopecks: 20_000, activePeriods: 2),
                "trend average includes only months with operations, including months without income")
        require(periods[10].report.netExpenseKopecks == 10_000 && periods[11].report.netExpenseKopecks == 30_000,
                "trend amounts come from the existing reports for each interval")
        let empty = ReportSeries.periods(inputs: [], intervals: months, taxonomy: .builtin)
        require(ReportSeries.average(empty) == ReportSeries.Average(incomeKopecks: 0, expenseKopecks: 0, activePeriods: 0),
                "empty trend has a zero average without division by zero")
        let foodInputs = [op(-10_000, kind: "expense", mcc: "5411", date: "2032-05-02T10:00:00Z"),
                          op(-30_000, kind: "expense", mcc: "5411", date: "2032-06-02T10:00:00Z")]
        let foodPeriods = ReportSeries.periods(inputs: foodInputs, intervals: months, taxonomy: .builtin)
        let points = ReportSeries.categoryPoints(foodPeriods, group: "Еда")
        require(points.count == 12 && points.map(\.date) == months.map(\.start), "category trend keeps every period")
        require(points.prefix(10).allSatisfy { $0.amountKopecks == 0 }
                && points[10].amountKopecks == 10_000 && points[11].amountKopecks == 30_000,
                "category trend includes zero periods and uses the category's reported amounts")
        require(ReportSeries.categoryPoints(foodPeriods, group: "Новая группа").allSatisfy { $0.amountKopecks == 0 },
                "a group without expenses has a zero point in each period")
        require(ReportSeries.defaultGroup(foodPeriods[11].report, groups: ExpenseCategoryGroup.builtin)?.name == "Еда",
                "default category trend is the largest expense group of the selected period")
        require(ReportSeries.defaultGroup(empty[0].report, groups: []) == nil, "no picker selection for an empty category tree")
    }

    static func testAccountSeries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = BankDateParser.parse("2032-06-01T00:00:00Z")!
        let now = BankDateParser.parse("2032-06-05T12:00:00Z")!
        let cash = Account(name: "Тестовый счёт", icon: "banknote", color: "green", startBalanceKopecks: 50_000, startDate: start)
        let other = Account(name: "Второй счёт", icon: "wallet.pass", color: "blue", startBalanceKopecks: 10_000, startDate: start)
        let expense = ManualOperation(kind: .expense, amountKopecks: 3_000,
                                      date: BankDateParser.parse("2032-06-02T10:00:00Z")!, accountID: cash.id,
                                      group: "Еда", subcategory: "Супермаркеты")
        let transfer = ManualOperation(kind: .transfer, amountKopecks: 5_000,
                                       date: BankDateParser.parse("2032-06-03T12:00:00Z")!,
                                       accountID: other.id, toAccountID: cash.id)
        var history = SavedHistory()
        history.accounts = [cash, other]
        history.manualOperations = [expense, transfer]
        let interval = ReportSeries.accountInterval(range: .days30, now: now, calendar: calendar)
        let points = ReportSeries.balancePoints(history, account: cash, interval: interval, range: .days30, calendar: calendar)
        require(points.count == 30 && points.last?.date == calendar.startOfDay(for: now)
                && points.last?.moment == interval.end, "thirty closing balances, ending with today's closing balance")
        require(points.map(\.amountKopecks) == history.accountBalances(cash, at: points.map(\.moment)),
                "account chart amounts match the existing accountBalances API")
        require(points.first?.amountKopecks == 50_000 && points.last?.amountKopecks == 52_000,
                "balance chart has the entered balance before activity and the actual balance after activity")
        let june2 = points.first { $0.date == BankDateParser.parse("2032-06-02T00:00:00Z")! }
        require(june2?.amountKopecks == 47_000, "a chart date labels that day's closing balance, not the next day")
        require(points.last?.amountKopecks == history.accountBalances(cash, at: [.distantFuture])[0],
                "the latest closing balance equals the current balance when all operations are in the past")
        let movements = history.accountMovements(cash)
        let period = ReportSeries.accountPeriod(movements, interval: interval)
        require(period.incomingKopecks == 5_000 && period.outgoingKopecks == 3_000,
                "account turnover sums this account's positive and negative deltas")
        require(period.movements.first?.delta == 5_000 && history.accountMovements(other).first?.delta == -5_000,
                "the same transfer is positive on its destination and negative on its source")
        let days = ReportSeries.accountDays(period.movements, calendar: calendar)
        require(days.count == 2 && days[0].date > days[1].date && days[0].movements[0].id == transfer.bankOperation.id,
                "account operations are grouped by day, newest first")
        let lower = AccountMovement(operation: expense.bankOperation, date: interval.start, delta: -3_000)
        let upper = AccountMovement(operation: transfer.bankOperation, date: interval.end, delta: 5_000)
        let bounded = ReportSeries.accountPeriod([lower, upper], interval: interval)
        require(bounded.movements.count == 1 && bounded.outgoingKopecks == 3_000 && bounded.incomingKopecks == 0,
                "account intervals include their start and exclude their end")
        let quarter = ReportSeries.accountInterval(range: .days90, now: now, calendar: calendar)
        require(ReportSeries.balanceMoments(interval: quarter, range: .days90, calendar: calendar).count == 90,
                "ninety daily balance samples")
        let year = ReportSeries.accountInterval(range: .year, now: now, calendar: calendar)
        let weekly = ReportSeries.balanceMoments(interval: year, range: .year, calendar: calendar)
        require(weekly.count == 53 && weekly.last == year.end, "a year uses weekly samples and includes the final partial week")
        for index in 1..<(weekly.count - 1) {
            require(calendar.date(byAdding: .day, value: 7, to: weekly[index - 1]) == weekly[index], "weekly samples use calendar weeks")
        }
        require(ReportSeries.accountDays([], calendar: calendar).isEmpty,
                "an account without operations has no operation sections")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = calendar.date(from: DateComponents(year: 2032, month: 3, day: 20))!
        let dst = ReportSeries.accountInterval(range: .days30, now: dstNow, calendar: calendar)
        let dstPoints = ReportSeries.balanceMoments(interval: dst, range: .days30, calendar: calendar)
        require(dstPoints.count == 30 && dstPoints.last == dst.end, "daylight saving does not add or remove chart days")
        for index in 1..<dstPoints.count {
            require(calendar.date(byAdding: .day, value: 1, to: dstPoints[index - 1]) == dstPoints[index],
                    "daily balances advance by calendar days across daylight saving")
        }
    }

    static func testReportEngine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func day(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2032, month: month, day: day))! }
        func iso(_ month: Int, _ day: Int) -> String { String(format: "2032-%02d-%02dT10:00:00Z", month, day) }
        let now = day(9, 20)

        // Periods
        require(ReportPeriod.month(day(9, 17)).interval(now: now, calendar: calendar) == DateInterval(start: day(9, 1), end: day(10, 1)), "a month")
        require(ReportPeriod.year(day(5, 3)).interval(now: now, calendar: calendar) == DateInterval(start: day(1, 1), end: day(10, 1)),
                "the current year ends with the current month: no months that have not come yet")
        let lastYear = calendar.date(from: DateComponents(year: 2031, month: 6, day: 1))!
        require(ReportPeriod.year(lastYear).interval(now: now, calendar: calendar)
                == DateInterval(start: calendar.date(from: DateComponents(year: 2031, month: 1, day: 1))!, end: day(1, 1)), "a past year is whole")
        let sampleBuckets = ReportEngine.buckets(DateInterval(start: day(1, 1), end: day(10, 1)), step: .month, calendar: calendar)
        require(ReportEngine.trimmed(sampleBuckets, from: day(7, 15)).map(\.start) == [day(7, 1), day(8, 1), day(9, 1)],
                "balances start from the month of the first operation")
        require(ReportEngine.trimmed(sampleBuckets, from: nil).count == 9, "without a first date nothing is trimmed")
        require(ReportEngine.trimmed(sampleBuckets, from: day(12, 1)).count == 9, "a first date after the period trims nothing")
        require(ReportPeriod.lastDays(7).interval(now: now, calendar: calendar) == DateInterval(start: day(9, 14), end: day(9, 21)), "the last 7 days include today")
        require(ReportPeriod.custom(from: day(9, 10), through: day(9, 3)).interval(now: now, calendar: calendar) == DateInterval(start: day(9, 3), end: day(9, 11)),
                "own dates in any order, the last day included")
        require(ReportPeriod.allHistory.interval(now: now, firstDate: day(7, 15), calendar: calendar) == DateInterval(start: day(7, 15), end: day(9, 21)), "all history")
        require(ReportPeriod.months(from: day(7, 15), now: now, calendar: calendar) == [day(7, 1), day(8, 1), day(9, 1)], "the ribbon of months, oldest first")
        require(ReportPeriod.months(from: nil, now: now, calendar: calendar) == [day(9, 1)], "without history only the current month")

        // Steps and buckets
        let september = ReportPeriod.month(day(9, 1)).interval(now: now, calendar: calendar)
        require(ReportEngine.step(.automatic, for: september, calendar: calendar) == .day, "a month is shown by days")
        let half = DateInterval(start: day(4, 1), end: day(9, 1))
        require(ReportEngine.step(.automatic, for: half, calendar: calendar) == .month, "several months are shown by months")
        let days = ReportEngine.buckets(september, step: .day, calendar: calendar)
        require(days.count == 30 && days.first?.start == day(9, 1) && days.last?.end == day(10, 1), "30 daily buckets cover September")
        let weeks = ReportEngine.buckets(september, step: .week, calendar: calendar)
        require(weeks.count == 5 && weeks.last?.end == day(10, 1) && weeks[1].start == day(9, 8), "weeks run from the start of the period; the last is shorter")
        let months = ReportEngine.buckets(DateInterval(start: day(7, 15), end: day(9, 21)), step: .month, calendar: calendar)
        require(months.map(\.start) == [day(7, 15), day(8, 1), day(9, 1)] && months.last?.end == day(9, 21), "calendar months, the first and the last cut to the period")
        for set in [days, weeks, months] { for (a, b) in zip(set, set.dropFirst()) { require(a.end == b.start, "buckets are contiguous") } }
        require(ReportEngine.step(.day, for: DateInterval(start: day(1, 1), end: day(12, 31)), calendar: calendar) == .week, "too many days fall back to weeks")

        // Structure
        let taxonomy = ExpenseTaxonomy.builtin
        var inputs: [FinancialOperationInput] = []
        func expense(_ amount: Int64, _ description: String, _ category: String, _ date: String, mcc: String? = nil) -> FinancialOperationInput {
            op(-amount, kind: "expense", category: category, description: description, mcc: mcc, date: date)
        }
        inputs.append(expense(30_000, "Пятёрочка", "Супермаркеты", iso(9, 3)))
        inputs.append(expense(10_000, "Пятёрочка", "Супермаркеты", iso(9, 4)))
        inputs.append(expense(20_000, "Кофейня", "Кафе", iso(9, 4)))
        inputs.append(expense(15_000, "Такси", "Такси", iso(9, 10)))
        inputs.append(expense(99_000, "Старый месяц", "Супермаркеты", iso(8, 30)))
        inputs.append(op(5_000, kind: "refund", category: "Возврат", description: "Возврат Пятёрочка", date: iso(9, 5)))
        inputs.append(op(-70_000, kind: "internal_transfer", description: "Перевод между счетами одного клиента", date: iso(9, 6)))
        inputs.append(op(200_000, kind: "income", category: "Зарплата", description: "ООО Ромашка", date: iso(9, 5)))
        let slices = ReportEngine.slices(inputs, in: september, mode: .expenses, grouping: .categories, taxonomy: taxonomy)
        require(slices.map(\.title) == ["Еда", "Транспорт"], "groups of September, the largest first; other months and transfers are out")
        require(slices[0].amountKopecks == 60_000 && slices[0].count == 3, "the group sums its operations")
        require(slices[0].children.map(\.title) == ["Супермаркеты", "Кафе и рестораны"] && slices[0].children.map(\.amountKopecks) == [40_000, 20_000],
                "subcategories inside, the largest first")
        let payees = ReportEngine.slices(inputs, in: september, mode: .expenses, grouping: .payees, taxonomy: taxonomy)
        require(payees.first?.title == "Пятёрочка" && payees.first?.amountKopecks == 40_000 && payees.first?.count == 2, "payees group the same shop")
        let income = ReportEngine.slices(inputs, in: september, mode: .income, grouping: .categories, taxonomy: taxonomy)
        require(income.map(\.amountKopecks) == [200_000], "income by its category")
        let report = FinancialEngine.report(inputs, in: september, taxonomy: taxonomy)
        require(slices.reduce(0) { $0 + $1.amountKopecks } == report.grossExpenseKopecks, "the groups add up to the report's gross expense")
        let damaged = [expense(10_000, "28.09.2026 в 16:39 28.09.2026 –232,00 ₽", "Тест", iso(9, 7))]
        require(ReportEngine.slices(damaged, in: september, mode: .expenses, grouping: .payees, taxonomy: taxonomy).first?.title == "Без названия",
                "a damaged title is shown as an unnamed payee, never as a payee")

        // Dynamics: every bucket is present, the axis does not depend on what was tapped
        let bars = ReportEngine.bars(inputs, buckets: days, mode: .expenses, grouping: .categories)
        require(bars.count == 3 && bars.map(\.label).sorted() == ["Еда", "Еда", "Транспорт"], "stacked bars: a group per day with operations")
        let totals = ReportEngine.totals(bars, buckets: days)
        require(totals.count == 30 && totals[3] == 60_000 - 30_000 && totals[2] == 30_000 && totals[9] == 15_000 && totals[0] == 0,
                "totals per bucket, empty days are zero")
        let focused = ReportEngine.bars(inputs, buckets: days, mode: .expenses, grouping: .categories, focus: "Еда")
        require(focused.map(\.label).sorted() == ["Кафе и рестораны", "Супермаркеты", "Супермаркеты"], "a focused group is split by its subcategories")
        require(ReportEngine.bars(inputs, buckets: [], mode: .expenses, grouping: .categories).isEmpty, "no buckets, no bars")

        // Income and expenses
        let flow = ReportEngine.flow(inputs, buckets: weeks)
        require(flow.map(\.incomeKopecks) == [200_000, 0, 0, 0, 0], "income by week")
        require(flow.map(\.expenseKopecks) == [60_000 - 5_000, 15_000, 0, 0, 0] || flow[0].expenseKopecks == 75_000 - 5_000,
                "net expense by week: refunds are taken off, transfers are not counted")
        require(flow.reduce(0) { $0 + $1.expenseKopecks } == report.netExpenseKopecks, "the weeks add up to the report's net expense")
        require(flow.reduce(0) { $0 + $1.incomeKopecks } == report.incomeKopecks, "the weeks add up to the report's income")

        // Balances
        let start = day(8, 1)
        let cash = Account(name: "Наличные", icon: "banknote", color: "green", startBalanceKopecks: 100_000, startDate: start)
        var history = SavedHistory()
        history.accounts = [cash]
        history.manualOperations = [
            ManualOperation(kind: .expense, amountKopecks: 10_000, date: day(9, 3), accountID: cash.id, group: "Еда", subcategory: "Кафе и рестораны"),
            ManualOperation(kind: .income, amountKopecks: 5_000, date: day(9, 12), accountID: cash.id, subcategory: "Прочие доходы"),
        ]
        let points = ReportEngine.balances(history, accounts: [cash], buckets: weeks)
        require(points.map(\.totalKopecks) == [90_000, 95_000, 95_000, 95_000, 95_000], "the balance at the end of every week")
        require(points.last?.totalKopecks == cash.balance(bankOperations: [], manual: history.manualOperations ?? []), "the last point is the current balance")
        require(ReportEngine.balances(history, accounts: [], buckets: weeks).allSatisfy { $0.totalKopecks == 0 }, "no accounts, no balance")
    }

    static func main() {
        require(FinancialEngine.classify(op(-10_000, kind: "expense")).type == .expense, "expense")
        require(FinancialEngine.classify(op(5_000, kind: "income")).type == .income, "explicit income")
        require(FinancialEngine.classify(op(5_100, kind: "unclassified_income")).type == .unknown, "technical unclassified income must stay unknown")
        require(FinancialEngine.classify(op(5_200, kind: "unclassified_income", category: "Зарплата", description: "Зарплата за месяц")).type == .income, "salary text confirms income")
        require(FinancialEngine.classify(op(5_300, kind: "unclassified_income", description: "Кэшбэк 5 процентов")).type == .income, "cashback with percent text remains cashback income")
        require(FinancialEngine.classify(op(3_000, kind: "refund", category: "Возврат")).type == .refund, "refund")
        let cashDeposit = op(1_100_000, kind: "refund", category: "Денежные переводы", description: "Пополнение наличными", mcc: "6012")
        require(FinancialEngine.classify(cashDeposit).type == .income, "cash deposit tagged as refund by the collector is income")
        require(FinancialEngine.incomeCategory(for: cashDeposit) == "Пополнения", "cash deposit goes to Пополнения")
        let depositReport = FinancialEngine.report([cashDeposit], in: DateInterval(start: BankDateParser.parse("2032-06-01T00:00:00Z")!, end: BankDateParser.parse("2032-07-01T00:00:00Z")!))
        require(depositReport.incomeKopecks == 1_100_000 && depositReport.refundsKopecks == 0, "cash deposit is income and does not reduce expenses")
        require(FinancialEngine.classify(op(50_000, kind: "internal_transfer", category: "Переводы между своими счетами")).type == .internalTransfer, "internal transfer")
        let saveOut = op(-50_000, kind: "transfer", category: "Перевод", description: "Перевод между счетами одного клиента")
        let saveBack = op(20_000, kind: "transfer", category: "Перевод", description: "Перевод между счетами одного клиента")
        require(FinancialEngine.classify(saveOut).type == .internalTransfer, "statement/live Save transfer must be internal")
        require(FinancialEngine.movementCategory(for: saveOut) == "Сейв", "Save movement gets its own account bucket")
        require(FinancialEngine.saveTransferDirection(for: saveOut) == "Карта → Сейв", "negative own transfer moves money to Save")
        require(FinancialEngine.saveTransferDirection(for: saveBack) == "Сейв → Карта", "positive own transfer moves money back to card")
        require(FinancialEngine.classify(op(31, kind: "transfer", category: "Пополнение", description: "Начисление процентов по Сейву")).type == .interestIncome, "explicit Save interest beats generic top-up label")
        require(FinancialEngine.classify(op(30, kind: "interest_income", category: "Проценты")).type == .interestIncome, "interest")
        require(FinancialEngine.classify(op(-199, kind: "expense", description: "Комиссия банка")).type == .commission, "commission")
        require(FinancialEngine.classify(op(-200, kind: "expense", description: "Покупка без комиссии")).type == .expense, "no-commission phrase must not become a fee")
        require(FinancialEngine.classify(op(-201, kind: "expense", description: "Комиссия за перевод между своими счетами")).type == .commission, "own-transfer fee stays commission")
        require(FinancialEngine.classify(op(-50_000, kind: "expense", description: "Снятие наличных в банкомате")).type == .internalTransfer, "cash withdrawal")
        require(FinancialEngine.classify(op(-250, kind: "expense", description: "Комиссия за снятие наличных в банкомате")).type == .commission, "cash withdrawal fee stays commission")
        require(FinancialEngine.classify(op(-20_000, kind: "installment_payment", providers: ["BNPL"])).type == .split, "split")
        require(FinancialEngine.classify(op(-4_000, kind: "expense", status: "В обработке")).type == .pending, "pending")
        require(FinancialEngine.classify(op(-5_000, kind: "expense", status: "Отменено")).type == .cancelled, "cancelled")
        require(FinancialEngine.classify(op(-6_000, kind: "legacy_kind")).type == .expense, "completed negative unknown kind is an expense")
        require(FinancialEngine.classify(op(-6_100, kind: "unclassified_income")).type == .expense, "legacy negative income kind falls back to expense")
        require(FinancialEngine.classify(op(-6_200, kind: "income")).type == .expense, "legacy negative explicit income kind falls back to expense")
        require(FinancialEngine.classify(op(-6_300, kind: "refund", category: "Возврат")).type == .expense, "negative stale refund metadata falls back to expense")
        require(FinancialEngine.classify(op(-6_400, kind: "interest_income", category: "Проценты")).type == .expense, "negative stale interest metadata falls back to expense")
        require(FinancialEngine.classify(op(6_000, kind: "legacy_kind")).type == .unknown, "positive unknown kind must not be guessed as income")
        require(FinancialEngine.classify(op(-7_000, kind: "transfer")).type == .expense, "external outgoing transfer")
        require(FinancialEngine.classify(op(8_000, kind: "transfer")).type == .income, "external incoming transfer")
        require(FinancialEngine.classify(op(8_010, kind: "unclassified_income", category: "Переводы")).type == .income, "plural transfer category confirms income")
        require(FinancialEngine.classify(op(8_020, kind: "unclassified_income", category: "Пополнения")).type == .income, "plural top-up category confirms income")
        require(FinancialEngine.classify(op(-8_030, kind: "expense", category: "Перевод между своими счетами")).type == .internalTransfer, "singular own-transfer category remains internal")
        require(FinancialEngine.classify(op(8_040, kind: "transfer", category: "Перевод", description: "Возврат долга")).type == .income, "debt repayment transfer is not a purchase refund")
        require(FinancialEngine.classify(op(8_041, kind: "transfer", category: "Перевод", description: "Возврат средств от друга")).type == .income, "transfer metadata wins over generic refund wording")
        require(FinancialEngine.classify(op(8_050, kind: "unclassified_income", description: "Проценты по кредиту")).type == .unknown, "generic interest wording must not invent interest income")
        require(FinancialEngine.classify(op(8_100, kind: "grouped_operation", category: "Перевод")).type == .income, "grouped positive transfer category remains income")
        require(FinancialEngine.classify(op(8_200, kind: "unclassified_income", category: "Проценты", description: "Проценты")).type == .interestIncome, "plain interest category remains interest income")

        // v34.2: split refunds cannot reduce expenses while split purchases are excluded.
        require(FinancialEngine.classify(op(12_000, kind: "refund", category: "Возврат", providers: ["BNPL"])).type == .split,
                "BNPL refund stays with excluded split movements")
        require(FinancialEngine.classify(op(12_000, kind: "installment_payment", description: "Кэшбэк Сплита")).type == .split,
                "explicit split kind wins over unverified income wording")

        require(FinancialEngine.classify(op(100, kind: "interest_income", category: "Перевод", purpose: "Отдал проценты по долгу")).type == .income,
                "explicit bank transfer outranks stale collector interest kind")
        require(FinancialEngine.classify(op(0, kind: "expense")).reason.contains("Нулевая"), "zero amount has an accurate explanation")
        for name in ["Метрополис", "МЕТРО Cash&Carry", "METRO Cash&Carry", "Газсервис"] {
            require(FinancialEngine.expenseCategory(for: op(-100, kind: "expense", category: "Не определено", description: name)).subcategory == "Прочее", "merchant substring must not invent transport/fuel: " + name)
        }
        require(FinancialEngine.expenseCategory(for: op(-100, kind: "expense", category: "Аксессуары для телефона")).subcategory == "Прочее", "generic accessories are not automatically clothing")
        require(FinancialEngine.expenseCategory(for: op(-100, kind: "expense", description: "Проезд в метро")).subcategory == "Общественный транспорт", "whole-word metro remains transport")
        require(FinancialEngine.expenseCategory(for: op(-100, kind: "expense", description: "АЗС номер 1")).subcategory == "Топливо", "whole-word fuel station remains fuel")

        let grouped = op(-146_800, kind: "grouped_operation", components: [-178_000, 31_200])
        let groupedAssessment = FinancialEngine.classify(grouped)
        require(groupedAssessment.type == .expense, "grouped type")
        require(groupedAssessment.expenseContributionKopecks == 146_800, "grouped parent total only")
        require(FinancialEngine.classify(op(14_680, kind: "grouped_operation", components: [17_800, -3_120])).type == .unknown, "positive grouped operation is not guessed as income")

        let formatter = ISO8601DateFormatter()
        let interval = DateInterval(start: formatter.date(from: "2032-06-01T00:00:00Z")!,
                                    end: formatter.date(from: "2032-07-01T00:00:00Z")!)
        let splitPair = FinancialEngine.report([
            op(-12_000, kind: "installment_payment", providers: ["BNPL"]),
            op(12_000, kind: "refund", category: "Возврат", providers: ["BNPL"])
        ], in: interval)
        require(splitPair.grossExpenseKopecks == 0 && splitPair.refundsKopecks == 0 && splitPair.incomeKopecks == 0,
                "excluded split pair cannot create an artificial gain in ordinary totals")
        require(splitPair.bankDebitKopecks == 12_000 && splitPair.bankCreditKopecks == 12_000,
                "split pair is still visible in bank card turnover")

        let saveSummary = FinancialEngine.saveAccountSummary([
            saveOut, saveBack,
            op(31, kind: "transfer", category: "Пополнение", description: "Начисление процентов по Сейву")
        ], in: interval)
        require(saveSummary.toSaveKopecks == 50_000, "Save incoming transfer total")
        require(saveSummary.fromSaveKopecks == 20_000, "Save outgoing transfer total")
        require(saveSummary.netTransferKopecks == 30_000, "Save net transfer")
        require(saveSummary.interestIncomeKopecks == 31, "Save interest total")

        let summary = FinancialEngine.summarize([
            op(-10_000, kind: "expense"),
            op(3_000, kind: "refund", category: "Возврат"),
            op(5_000, kind: "income"),
            op(30, kind: "interest_income", category: "Проценты"),
            op(50_000, kind: "internal_transfer", category: "Переводы между своими счетами"),
            op(-199, kind: "expense", description: "Комиссия банка"),
            op(-20_000, kind: "installment_payment", providers: ["BNPL"]),
            op(-4_000, kind: "expense", status: "В обработке"),
            op(-5_000, kind: "expense", status: "Отменено"),
            grouped,
            op(-99_999, kind: "expense", date: "2032-05-31T23:59:59Z")
        ], in: interval)

        require(summary.operationCount == 10, "period filtering")
        require(summary.grossExpenseKopecks == 156_999, "gross expenses use parent group once")
        require(summary.refundsKopecks == 3_000, "refund contribution")
        require(summary.netExpenseKopecks == 153_999, "net expense")
        require(summary.incomeKopecks == 5_030, "ordinary + interest income")
        require(summary.netCashFlowKopecks == -148_969, "net cash flow")
        require(summary.counts[.internalTransfer] == 1, "internal transfer bucket")
        require(summary.counts[.split] == 1, "split bucket")
        require(summary.counts[.pending] == 1, "pending bucket")
        require(summary.counts[.cancelled] == 1, "cancelled bucket")
        require(summary.signedAmounts[.expense] == -156_800, "component amounts must not be added to type totals")

        let dateInterval = DateInterval(start: formatter.date(from: "2033-02-01T00:00:00Z")!,
                                        end: formatter.date(from: "2033-03-01T00:00:00Z")!)
        let dateFormats = FinancialEngine.summarize([
            op(-111, kind: "expense", date: "2033-02-14T12:34:56.789Z"),
            op(-222, kind: "expense", date: "2033-02-15T12:34:56Z"),
            op(-333, kind: "expense", date: "2033-02-16T15:34:56.123+03:00"),
            op(-444, kind: "expense", date: "2033-03-01T00:00:00Z"),
            op(-555, kind: "expense", date: "not-a-date")
        ], in: dateInterval)
        require(dateFormats.operationCount == 3, "fractional and plain ISO8601 dates must be included")
        require(dateFormats.grossExpenseKopecks == 666, "period totals must include fractional-second timestamps")
        require(dateFormats.invalidDateCount == 1, "invalid dates must be surfaced instead of silently disappearing")

        let report = FinancialEngine.report([
            op(-123_400, kind: "legacy_purchase", category: "Супермаркеты"),
            op(12_300, kind: "refund", category: "Возврат"),
            op(-45_600, kind: "expense", status: "В обработке"),
            op(-78_900, kind: "internal_transfer", category: "Переводы между своими счетами"),
            op(-22_200, kind: "installment_payment", providers: ["BNPL"]),
            op(33_300, kind: "legacy_credit", description: "Непонятное поступление"),
            op(777, kind: "interest_income", category: "Проценты"),
            op(-66_600, kind: "expense", status: "Отменено")
        ], in: interval)
        require(report.operationCount == 8, "report count")
        require(report.grossExpenseKopecks == 123_400, "legacy debit is an expense")
        require(report.refundsKopecks == 12_300, "refund reduces expense")
        require(report.netExpenseKopecks == 111_100, "net expense")
        require(report.pendingDebitKopecks == 45_600, "pending stays out of final expense")
        require(report.incomeKopecks == 777, "only confirmed income enters income total")
        require(report.movementKopecks == 78_900, "confirmed own transfer is movement")
        require(report.bankDebitKopecks == 270_100, "bank debit turnover includes expense, pending, movement and split but excludes cancelled")
        require(report.bankCreditKopecks == 46_377, "bank credit turnover includes positive bank movements")
        require(report.unknownCount == 1, "unknown credit remains visible")
        let unknownLine = report.incompleteLines.first { $0.title == "Не определено" }
        require(unknownLine?.children.count == 1, "unknown operations expose diagnostics")
        require(unknownLine?.children.first?.title == "Непонятное поступление", "unknown diagnostic shows operation title")
        require(unknownLine?.children.first?.amountKopecks == 33_300, "unknown diagnostic shows operation amount")
        require(unknownLine?.children.first?.note?.contains("может быть перевод между своими счетами") == true, "unknown diagnostic shows classification reason")
        require(report.expenseLines.contains { $0.title == "Еда" && $0.children.contains { $0.title == "Супермаркеты" } }, "food category expands to supermarkets")
        require(report.expenseLines.contains { $0.title == "Возвраты" }, "refund is shown inside expenses")
        require(report.expenseLines.contains { $0.title == "Сплит" }, "split is shown separately")
        require(report.incomeLines.contains { $0.title == "Проценты" }, "interest subgroup")

        let positiveSafetyReport = FinancialEngine.report([
            op(20_000, kind: "unclassified_income", description: "Неизвестное поступление"),
            op(3_500, kind: "unclassified_income", description: "Кэшбэк 5 процентов")
        ], in: interval)
        require(positiveSafetyReport.incomeKopecks == 3_500, "only explicitly recognized cashback enters income")
        require(positiveSafetyReport.unknownCount == 1, "generic positive fallback remains unknown")
        require(positiveSafetyReport.incomeLines.contains { $0.title == "Кэшбэк" && $0.amountKopecks == 3_500 }, "cashback has priority over percent wording")
        let positiveUnknown = positiveSafetyReport.incompleteLines.first { $0.title == "Не определено" }?.children.first
        require(positiveUnknown?.note?.contains("Тип: unclassified_income") == true, "unknown diagnostic includes raw kind")

        let staleMetadataReport = FinancialEngine.report([
            op(-21_000, kind: "refund", category: "Возврат"),
            op(-34_000, kind: "interest_income", category: "Проценты"),
            op(5_500, kind: "refund", category: "Возврат")
        ], in: interval)
        require(staleMetadataReport.grossExpenseKopecks == 55_000, "negative stale refund/interest metadata contributes to expense")
        require(staleMetadataReport.refundsKopecks == 5_500, "positive refund still reduces expense")
        require(staleMetadataReport.netExpenseKopecks == 49_500, "stale metadata report net expense")
        require(staleMetadataReport.unknownCount == 0, "negative stale metadata must not remain unknown")


        let withdrawalReport = FinancialEngine.report([
            op(-75_000, kind: "expense", description: "Снятие наличных"),
            op(-300, kind: "expense", description: "Комиссия за снятие наличных")
        ], in: interval)
        require(withdrawalReport.movementLines.contains { $0.title == "Снятие наличных" && $0.amountKopecks == 75_000 }, "cash withdrawal is shown as movement")
        require(withdrawalReport.expenseLines.contains { $0.title == "Другое" && $0.children.contains { $0.title == "Комиссии" && $0.amountKopecks == 300 } }, "cash withdrawal fee remains expense")
        require(withdrawalReport.netExpenseKopecks == 300, "cash withdrawal itself is excluded from financial expense")

        let categoryCases: [(FinancialOperationInput, FinanceCategoryPath)] = [
            (op(-1_000, kind: "expense", category: "Супермаркеты"), FinanceCategoryPath(group: "Еда", subcategory: "Супермаркеты")),
            (op(-1_000, kind: "expense", category: "Кафе и рестораны"), FinanceCategoryPath(group: "Еда", subcategory: "Кафе и рестораны")),
            (op(-1_000, kind: "expense", description: "Доставка еды"), FinanceCategoryPath(group: "Еда", subcategory: "Доставка еды")),
            (op(-1_000, kind: "expense", category: "Такси"), FinanceCategoryPath(group: "Транспорт", subcategory: "Такси")),
            (op(-1_000, kind: "expense", category: "Метро"), FinanceCategoryPath(group: "Транспорт", subcategory: "Общественный транспорт")),
            (op(-1_000, kind: "expense", category: "АЗС"), FinanceCategoryPath(group: "Транспорт", subcategory: "Топливо")),
            (op(-1_000, kind: "expense", category: "Автосервис"), FinanceCategoryPath(group: "Транспорт", subcategory: "Авто")),
            (op(-1_000, kind: "expense", category: "Маркетплейсы"), FinanceCategoryPath(group: "Покупки", subcategory: "Маркетплейсы")),
            (op(-1_000, kind: "expense", category: "Одежда и обувь"), FinanceCategoryPath(group: "Покупки", subcategory: "Одежда")),
            (op(-1_000, kind: "expense", category: "Электроника"), FinanceCategoryPath(group: "Покупки", subcategory: "Электроника")),
            (op(-1_000, kind: "expense", category: "Товары для дома"), FinanceCategoryPath(group: "Покупки", subcategory: "Дом и быт")),
            (op(-1_000, kind: "expense", category: "ЖКХ"), FinanceCategoryPath(group: "Обязательные", subcategory: "ЖКХ")),
            (op(-1_000, kind: "expense", category: "Мобильная связь"), FinanceCategoryPath(group: "Обязательные", subcategory: "Связь и интернет")),
            (op(-1_000, kind: "expense", category: "Подписки"), FinanceCategoryPath(group: "Обязательные", subcategory: "Подписки")),
            (op(-1_000, kind: "expense", category: "Аптеки"), FinanceCategoryPath(group: "Обязательные", subcategory: "Здоровье")),
            (op(-1_000, kind: "expense", category: "Развлечения"), FinanceCategoryPath(group: "Другое", subcategory: "Развлечения")),
            (op(-1_000, kind: "expense", category: "Путешествия"), FinanceCategoryPath(group: "Другое", subcategory: "Путешествия")),
            (op(-1_000, kind: "expense", category: "Подарки"), FinanceCategoryPath(group: "Другое", subcategory: "Подарки")),
            (op(-1_000, kind: "transfer", category: "Перевод"), FinanceCategoryPath(group: "Переводы", subcategory: "Переводы другим")),
            (op(-1_000, kind: "expense", description: "Комиссия банка"), FinanceCategoryPath(group: "Другое", subcategory: "Комиссии")),
            (op(-1_000, kind: "expense", category: "Цветы", description: "Интернет-магазин цветов"), FinanceCategoryPath(group: "Другое", subcategory: "Подарки")),
            (op(-1_000, kind: "expense", category: "Товары", description: "Покупка в интернет-магазине"), FinanceCategoryPath(group: "Другое", subcategory: "Прочее")),
            (op(-1_000, kind: "expense", category: "Мобильные приложения", description: "Подписка на сервис"), FinanceCategoryPath(group: "Обязательные", subcategory: "Подписки")),
            (op(-1_000, kind: "expense", category: "Товары", mcc: "5411"), FinanceCategoryPath(group: "Еда", subcategory: "Супермаркеты")),
            (op(-1_000, kind: "expense", category: "Товары", mcc: "MCC 4812"), FinanceCategoryPath(group: "Покупки", subcategory: "Электроника")),
            (op(-1_000, kind: "expense", category: "Товары", mcc: "MCC 4814"), FinanceCategoryPath(group: "Обязательные", subcategory: "Связь и интернет")),
            (op(-1_000, kind: "expense", category: "Товары", mcc: "4816"), FinanceCategoryPath(group: "Обязательные", subcategory: "Связь и интернет")),
            (op(-1_000, kind: "expense", category: "Товары", mcc: "4899"), FinanceCategoryPath(group: "Обязательные", subcategory: "Подписки")),
            (op(-1_000, kind: "expense", category: "Товары", mcc: "5816"), FinanceCategoryPath(group: "Другое", subcategory: "Развлечения")),
            (op(-1_000, kind: "expense", category: "Такси", mcc: "5411"), FinanceCategoryPath(group: "Транспорт", subcategory: "Такси")),
            (op(-1_000, kind: "expense", category: "Неизвестная категория"), FinanceCategoryPath(group: "Другое", subcategory: "Прочее"))
        ]
        for (operation, expected) in categoryCases {
            require(FinancialEngine.expenseCategory(for: operation) == expected, "expense category mapping: \(expected.group) / \(expected.subcategory)")
        }
        require(FinancialEngine.expenseCategory(for: op(-200, kind: "expense", description: "Покупка без комиссии")) == FinanceCategoryPath(group: "Другое", subcategory: "Прочее"), "no-commission purchase must not enter commission category")
        require(FinancialEngine.expenseCategory(for: op(-201, kind: "expense", description: "Комиссия за перевод между своими счетами")) == FinanceCategoryPath(group: "Другое", subcategory: "Комиссии"), "own-transfer fee uses commission category")

        require(FinancialEngine.expenseCategory(for: op(-490, kind: "expense", category: "Цифровые товары", description: "Плюс", mcc: "5815", purpose: "Яндекс Плюс / Yandex Plus")) == FinanceCategoryPath(group: "Обязательные", subcategory: "Подписки"), "Yandex Plus purpose overrides digital entertainment MCC")
        require(FinancialEngine.expenseCategory(for: op(-770, kind: "expense", category: "Яндекс", description: "Яндекс.Доставка", mcc: "3990")) == FinanceCategoryPath(group: "Другое", subcategory: "Доставка и курьеры"), "Yandex courier delivery has its own subgroup")
        require(FinancialEngine.expenseCategory(for: op(-12_340, kind: "transfer", category: "Перевод", description: "ООО УК Дом-Сервис", purpose: "Лицевой счёт: 123456 Без НДС")) == FinanceCategoryPath(group: "Обязательные", subcategory: "ЖКХ"), "housing management transfer with personal account is utilities")
        require(FinancialEngine.expenseCategory(for: op(-650, kind: "transfer", category: "Перевод", description: "АО Севергоргаз", purpose: "Лицевой счёт: 987654 Без НДС")) == FinanceCategoryPath(group: "Обязательные", subcategory: "ЖКХ"), "city gas transfer with personal account is utilities")
        require(FinancialEngine.expenseCategory(for: op(-880, kind: "transfer", category: "Перевод", description: "Получатель Иван", purpose: "Личный перевод")) == FinanceCategoryPath(group: "Переводы", subcategory: "Переводы другим"), "ordinary external transfer must stay external transfer")
        require(FinancialEngine.expenseCategory(for: op(-1_100, kind: "expense", category: "АЗС", description: "АЗС Газ-Сервис")) == FinanceCategoryPath(group: "Транспорт", subcategory: "Топливо"), "fuel purchase must not be confused with gas utilities")

        let v344Report = FinancialEngine.report([
            op(-490, kind: "expense", category: "Цифровые товары", description: "Плюс", mcc: "5815", purpose: "Яндекс Плюс / Yandex Plus"),
            op(-770, kind: "expense", category: "Яндекс", description: "Яндекс.Доставка", mcc: "3990"),
            op(-12_340, kind: "transfer", category: "Перевод", description: "ООО УК Дом-Сервис", purpose: "Лицевой счёт: 123456 Без НДС"),
            op(-650, kind: "transfer", category: "Перевод", description: "АО Севергоргаз", purpose: "Лицевой счёт: 987654 Без НДС")
        ], in: interval)
        require(v344Report.grossExpenseKopecks == 14_250, "v34.4 category refinements must not change gross expense")
        require(v344Report.expenseLines.contains { $0.title == "Обязательные" && $0.children.contains { $0.title == "Подписки" && $0.amountKopecks == 490 } }, "subscription refinement appears in report")
        require(v344Report.expenseLines.contains { $0.title == "Обязательные" && $0.children.contains { $0.title == "ЖКХ" && $0.amountKopecks == 12_990 } }, "utility transfer refinements appear in report")
        require(v344Report.expenseLines.contains { $0.title == "Другое" && $0.children.contains { $0.title == "Доставка и курьеры" && $0.amountKopecks == 770 } }, "courier delivery refinement appears in report")

        let mccCases: [(String, FinanceCategoryPath)] = [
            ("5411", FinanceCategoryPath(group: "Еда", subcategory: "Супермаркеты")),
            ("5812", FinanceCategoryPath(group: "Еда", subcategory: "Кафе и рестораны")),
            ("4121", FinanceCategoryPath(group: "Транспорт", subcategory: "Такси")),
            ("4111", FinanceCategoryPath(group: "Транспорт", subcategory: "Общественный транспорт")),
            ("5541", FinanceCategoryPath(group: "Транспорт", subcategory: "Топливо")),
            ("4812", FinanceCategoryPath(group: "Покупки", subcategory: "Электроника")),
            ("4814", FinanceCategoryPath(group: "Обязательные", subcategory: "Связь и интернет")),
            ("4816", FinanceCategoryPath(group: "Обязательные", subcategory: "Связь и интернет")),
            ("4899", FinanceCategoryPath(group: "Обязательные", subcategory: "Подписки")),
            ("4900", FinanceCategoryPath(group: "Обязательные", subcategory: "ЖКХ")),
            ("5912", FinanceCategoryPath(group: "Обязательные", subcategory: "Здоровье")),
            ("5815", FinanceCategoryPath(group: "Другое", subcategory: "Развлечения")),
            ("5816", FinanceCategoryPath(group: "Другое", subcategory: "Развлечения")),
            ("7832", FinanceCategoryPath(group: "Другое", subcategory: "Развлечения")),
            ("4511", FinanceCategoryPath(group: "Другое", subcategory: "Путешествия")),
            ("4722", FinanceCategoryPath(group: "Другое", subcategory: "Путешествия")),
            ("7011", FinanceCategoryPath(group: "Другое", subcategory: "Путешествия"))
        ]
        for (mcc, expected) in mccCases {
            let actual = FinancialEngine.expenseCategory(for: op(-999, kind: "expense", category: "Товары", mcc: mcc))
            require(actual == expected, "MCC category mapping: \(mcc) -> \(expected.group) / \(expected.subcategory)")
        }

        require(FinancialEngine.incomeCategory(for: op(8_010, kind: "unclassified_income", category: "Переводы")) == "Переводы от других", "plural transfer uses transfer income subgroup")
        require(FinancialEngine.incomeCategory(for: op(8_020, kind: "unclassified_income", category: "Пополнения")) == "Пополнения", "plural top-up uses top-up income subgroup")

        let taxonomyReport = FinancialEngine.report([
            op(-12_000, kind: "expense", category: "Супермаркеты"),
            op(-8_000, kind: "expense", category: "Кафе и рестораны"),
            op(-6_000, kind: "expense", category: "Такси"),
            op(-4_000, kind: "expense", category: "Подписки"),
            op(-2_000, kind: "transfer", category: "Перевод")
        ], in: interval)
        require(taxonomyReport.expenseLines.first?.title == "Еда", "expense groups use stable user-facing order")
        require(taxonomyReport.expenseLines.first?.children.map(\.title) == ["Супермаркеты", "Кафе и рестораны"], "food subcategories use stable order")
        require(taxonomyReport.expenseLines.contains { $0.title == "Транспорт" && $0.children.contains { $0.title == "Такси" } }, "transport group exists")
        require(taxonomyReport.expenseLines.contains { $0.title == "Обязательные" && $0.children.contains { $0.title == "Подписки" } }, "required group exists")
        require(taxonomyReport.expenseLines.contains { $0.title == "Переводы" && $0.children.contains { $0.title == "Переводы другим" } }, "transfers to people have their own group")
        let taxonomyGroupSum = taxonomyReport.expenseLines
            .filter { FinancialEngine.expenseGroupOrder.contains($0.title) }
            .reduce(Int64(0)) { $0 + $1.amountKopecks }
        require(taxonomyGroupSum == taxonomyReport.grossExpenseKopecks, "user-facing expense groups must reconcile to gross expense")
        for line in taxonomyReport.expenseLines where FinancialEngine.expenseGroupOrder.contains(line.title) {
            let childSum = line.children.reduce(Int64(0)) { $0 + $1.amountKopecks }
            let childCount = line.children.reduce(0) { $0 + $1.count }
            require(childSum == line.amountKopecks, "expense group child amounts must reconcile: \(line.title)")
            require(childCount == line.count, "expense group child counts must reconcile: \(line.title)")
        }

        let incomeTaxonomy = FinancialEngine.report([
            op(1_000, kind: "transfer", category: "Переводы"),
            op(2_000, kind: "unclassified_income", category: "Пополнения"),
            op(3_000, kind: "unclassified_income", category: "Зарплата", description: "Зарплата"),
            op(4_000, kind: "unclassified_income", description: "Кэшбэк"),
            op(5_000, kind: "interest_income", category: "Проценты")
        ], in: interval)
        require(incomeTaxonomy.incomeLines.reduce(Int64(0)) { $0 + $1.amountKopecks } == incomeTaxonomy.incomeKopecks, "income subgroups must reconcile to income total")

        let policyNow = ISO8601DateFormatter().date(from: "2033-03-20T12:00:00Z")!
        let recentCompleted = policyNow.addingTimeInterval(-1 * 86400)
        let policyBase = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: "not-a-date", status: "Выполнено")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(policyBase.days == 8, "completed operations do not need date parsing or widen refresh")

        let processing = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: "2033-03-01T12:00:00.123+03:00", status: "Обрабатывается")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(processing.days >= 20, "Обрабатывается must widen the refresh window")
        require(processing.stalePendingCount == 0, "recent processing is actively watched")

        let stalePending = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: "2032-12-01T12:00:00Z", status: "Pending")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(stalePending.days == 8, "stale pending must not widen every refresh for months")
        require(stalePending.stalePendingCount == 1, "stale pending is surfaced separately")

        let recentNoStatus = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: "2033-03-10T12:00:00Z", status: "Не указан")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(recentNoStatus.days >= 11, "recent status-less operation remains watched")

        let oldNoStatus = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: "2033-02-01T12:00:00Z", status: "Не указан")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(oldNoStatus.days == 8, "old status-less operation no longer widens refresh")

        require(FinancialEngine.isPendingStatus("Обрабатывается"), "processing status must be pending")
        require(FinancialEngine.isPendingStatus("Ожидает подтверждения"), "waiting status must be pending")
        require(FinancialEngine.isPendingStatus("hold"), "hold status must be pending")
        require(!FinancialEngine.isPendingStatus("Обработана"), "completed processed status must not be pending")
        require(FinancialEngine.classify(op(-12_345, kind: "expense", status: "Обработана")).type == .expense, "completed processed debit remains expense")

        let iso = ISO8601DateFormatter()
        let exactly14 = iso.string(from: policyNow.addingTimeInterval(-Double(IncrementalSyncPolicy.noStatusWatchDays) * 86400))
        let justOlder14 = iso.string(from: policyNow.addingTimeInterval(-Double(IncrementalSyncPolicy.noStatusWatchDays) * 86400 - 1))
        let noStatusBoundary = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: exactly14, status: "Не указан")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(noStatusBoundary.days == IncrementalSyncPolicy.noStatusWatchDays + 1, "status-less operation exactly at 14-day boundary is still watched")
        let noStatusPastBoundary = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: justOlder14, status: "Не указан")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(noStatusPastBoundary.days == 8, "status-less operation just older than 14 days no longer widens refresh")

        let exactly45 = iso.string(from: policyNow.addingTimeInterval(-Double(IncrementalSyncPolicy.pendingWatchDays) * 86400))
        let justOlder45 = iso.string(from: policyNow.addingTimeInterval(-Double(IncrementalSyncPolicy.pendingWatchDays) * 86400 - 1))
        let holdBoundary = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: exactly45, status: "hold")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(holdBoundary.days == IncrementalSyncPolicy.pendingWatchDays + 1, "pending exactly at 45-day boundary is still watched")
        require(holdBoundary.stalePendingCount == 0, "45-day boundary pending is not stale")
        let holdPastBoundary = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: justOlder45, status: "hold")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(holdPastBoundary.days == 8, "pending just older than 45 days no longer widens refresh")
        require(holdPastBoundary.stalePendingCount == 1, "pending just older than 45 days is surfaced as stale")

        let processedStatus = IncrementalSyncPolicy.calculate([
            SyncStatusInput(occurredAt: iso.string(from: policyNow.addingTimeInterval(-15 * 86400)), status: "Обработана")
        ], lastCompletedSync: recentCompleted, now: policyNow)
        require(processedStatus.days == 8, "completed 'Обработана' status must not widen refresh")

        testPeriodSelection()
        testMonthComparisonPeriods()
        testMonthlyComparison()
        testDailyNetExpense()
        testExpenseByGroup()
        testHistoryInterval()
        testMonthForecast()
        testOperationSearch()
        testBackup()
        testAccountBalance()
        testAccountReorder()
        testMonthReserve()
        testManualOperations()
        testGroupBalanceVisibility()
        testBackdatedManualOperation()
        testExpenseCategories()
        testUncategorizedReview()
        testFixedCostGroups()
        testIncomeCategories()
        testSaveStatementSource()
        testCardToSaveTransfer()
        testOperationLooks()
        testOtherShrinks()
        testReserveAccounts()
        testReportEngine()
        testAccountMovements()
        testReportSeries()
        testAccountSeries()

        print("Finance engine tests passed")
    }
}
