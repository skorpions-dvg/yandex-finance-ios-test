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
        // Variable baseline: median 30 000, quartiles 29 250 and 30 750. 12 000 in 10 days is a pace of 1.24,
        // so the rest of the month adds 12 000 × 21 / 10 = 25 200 to the 12 000 spent and 20 249 still expected.
        require(forecast.projectedExpenseKopecks == 57_449, "spent + recurring still expected + variable tail")
        require(forecast.projectedExpenseLowKopecks == 56_819 && forecast.projectedExpenseHighKopecks == 58_079, "range from the interpolated quartiles")
        require(forecast.projectedIncomeKopecks == 100_000 && forecast.projectedBalanceKopecks == 42_551,
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
        let pace = 1 + (0.6 - 1) * 2.0 / 7
        let expectedTail = Int64((30_000.0 / 31 * pace * 29).rounded())
        require(early.projectedExpenseKopecks == 60_000 + 20_249 + expectedTail,
                "the one-off counts as spent but does not drive the pace; the empty pace is floored at 0.6 and softened")

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
        let elizaveta = "Исходящий перевод СБП, Елизавета Павловна В., +7 923 000-00-00, Сбербанк"
        let transfers: [(Int, Int, Int64)] = [(7, 2, 25_000), (7, 21, 16_000), (8, 9, 20_000), (9, 4, 20_000), (9, 23, 12_000)]
        for (month, day, amount) in transfers {
            habits.append(op(-amount, kind: "transfer", category: "Перевод", description: elizaveta, date: iso(month, day)))
        }
        let bills: [Int64] = [25_147, 18_310, 22_905]
        let groceries: [[Int64]] = [[1_100, 2_700], [900, 3_400], [1_800, 2_200]]
        for (index, month) in [7, 8, 9].enumerated() {
            habits.append(op(-bills[index], kind: "expense", category: "ЖКХ", description: "ЭЭ \(index + 3).24, ГВС 8501.79 <ЛСИ62952740715;ПРД0\(month).2026>", date: iso(month, 12)))
            habits.append(op(-groceries[index][0], kind: "expense", category: "Супермаркеты", description: "Пятёрочка", date: iso(month, 6)))
            habits.append(op(-groceries[index][1], kind: "expense", category: "Супермаркеты", description: "Пятёрочка", date: iso(month, 19)))
        }
        habits.append(op(-66_000, kind: "transfer", category: "Перевод", description: "Исходящий перевод СБП, Юрий Олегович А., +7 996 000-00-00", date: iso(9, 25)))
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
            (op(-1_000, kind: "transfer", category: "Перевод"), FinanceCategoryPath(group: "Другое", subcategory: "Переводы другим")),
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
        require(FinancialEngine.expenseCategory(for: op(-880, kind: "transfer", category: "Перевод", description: "Получатель Иван", purpose: "Личный перевод")) == FinanceCategoryPath(group: "Другое", subcategory: "Переводы другим"), "ordinary external transfer must stay external transfer")
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
        require(taxonomyReport.expenseLines.contains { $0.title == "Другое" && $0.children.contains { $0.title == "Переводы другим" } }, "other group includes external transfers")
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

        print("Finance engine tests passed")
    }
}
