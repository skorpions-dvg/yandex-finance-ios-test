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

    static func testAppLockLogic() {
        for good in ["0000", "1234", "9876"] { require(AppLockLogic.isValid(pin: good), "a code of four digits: \(good)") }
        for bad in ["", "123", "12345", "12a4", "١٢٣٤", " 123", "12 4", "-123"] { require(!AppLockLogic.isValid(pin: bad), "not a code: \(bad)") }
        let pauses = (0...9).map { AppLockLogic.lockoutSeconds(afterFailures: $0) }
        require(pauses == [0, 0, 0, 0, 0, 30, 60, 300, 900, 900], "no pause for the first four wrong codes, then a growing one")
        let left = Date(timeIntervalSince1970: 1_000_000)
        require(AppLockLogic.shouldLock(backgroundedAt: left, now: left, afterSeconds: 0), "at once locks immediately")
        require(!AppLockLogic.shouldLock(backgroundedAt: left, now: left.addingTimeInterval(59), afterSeconds: 60), "a minute is not over yet")
        require(AppLockLogic.shouldLock(backgroundedAt: left, now: left.addingTimeInterval(60), afterSeconds: 60), "a minute is over")
        require(AppLockLogic.shouldLock(backgroundedAt: left, now: left.addingTimeInterval(-5), afterSeconds: 900), "a clock set back locks")
        require(!AppLockLogic.shouldLock(backgroundedAt: left, now: left.addingTimeInterval(86_400), afterSeconds: -1), "only at launch: a day away does not lock")
        // 46.39: an error of the Keychain never opens the app without the code.
        let expected: [(PinStoreRead, Bool, LockStart, Bool)] = [
            (.found, false, LockStart(hasPIN: true, locked: true, needsRetry: false, needsReset: false), false),
            (.found, true, LockStart(hasPIN: true, locked: true, needsRetry: false, needsReset: false), false),
            (.notFound, false, LockStart(hasPIN: false, locked: false, needsRetry: false, needsReset: false), true),
            (.notFound, true, LockStart(hasPIN: true, locked: true, needsRetry: false, needsReset: true), false),
            (.unavailable, false, LockStart(hasPIN: true, locked: true, needsRetry: true, needsReset: false), false),
            (.unavailable, true, LockStart(hasPIN: true, locked: true, needsRetry: true, needsReset: false), false),
            (.damaged, false, LockStart(hasPIN: true, locked: true, needsRetry: false, needsReset: true), false),
            (.damaged, true, LockStart(hasPIN: true, locked: true, needsRetry: false, needsReset: true), false),
        ]
        for (store, wasSet, start, accepts) in expected {
            let actual = AppLockLogic.start(store: store, pinWasSet: wasSet)
            require(actual == start, "lock start \(store) pinWasSet=\(wasSet): expected \(start), got \(actual)")
            require(AppLockLogic.checkWithoutRecord(store: store, pinWasSet: wasSet) == accepts,
                    "code without a record \(store) pinWasSet=\(wasSet): accepted must be \(accepts)")
        }
        for store in [PinStoreRead.found, .notFound, .unavailable, .damaged] {
            for wasSet in [false, true] where AppLockLogic.start(store: store, pinWasSet: wasSet).locked == false {
                require(store == .notFound && !wasSet, "only «no record, no code ever» opens: \(store) \(wasSet)")
            }
        }
    }

    /// 46.40: which bank purchase a receipt is (contract of GPT stage 58; fictional sums).
    static func testReceiptBankMatch() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func at(_ text: String) -> Date { BankDateParser.parse(text)! }
        func bank(_ id: String, _ amount: Int64, _ date: String, status: String = "Выполнено", kind: String = "expense") -> ReceiptMatchCandidate {
            ReceiptMatchCandidate(identity: id, input: op(amount, kind: kind, status: status, category: "Супермаркеты", description: "Магазин учебный", date: date))
        }
        func match(_ total: Int64?, _ date: String?, time: Bool = true, _ candidates: [ReceiptMatchCandidate]) -> ReceiptMatchOutcome {
            ReceiptBankMatch.match(totalKopecks: total, date: date.map(at), hasTime: time, candidates: candidates, calendar: utc)
        }
        func expect(_ actual: ReceiptMatchOutcome, _ wanted: ReceiptMatchOutcome, _ name: String) {
            require(actual == wanted, "receipt match \(name): expected \(wanted), got \(actual)")
        }
        // One purchase, ten minutes apart (18:27 on the receipt, 18:37 in the bank): found, the bank time fixes the receipt's.
        expect(match(165_687, "2032-06-02T18:27:00Z", [bank("b1", -165_687, "2032-06-02T18:37:00Z"), bank("b2", -9_900, "2032-06-02T18:30:00Z")]),
               .confirmed(identity: "b1", timeFix: at("2032-06-02T18:37:00Z")), "ten minutes")
        // Over midnight: 23:58 on the receipt, 00:05 of the next day in the bank.
        expect(match(50_000, "2032-06-02T23:58:00Z", [bank("b1", -50_000, "2032-06-03T00:05:00Z")]),
               .confirmed(identity: "b1", timeFix: at("2032-06-03T00:05:00Z")), "over midnight")
        // Twenty minutes apart: still the purchase, but its time does not replace the receipt's.
        expect(match(50_000, "2032-06-02T12:00:00Z", [bank("b1", -50_000, "2032-06-02T12:20:00Z")]),
               .confirmed(identity: "b1", timeFix: nil), "twenty minutes: no time fix")
        // Two equal sums the same day and a receipt without time: the owner chooses.
        expect(match(30_000, "2032-06-02T00:00:00Z", time: false, [bank("b2", -30_000, "2032-06-02T18:00:00Z"), bank("b1", -30_000, "2032-06-02T10:00:00Z")]),
               .ambiguous(["b1", "b2"]), "two equal sums")
        // Five days later: not this purchase.
        expect(match(30_000, "2032-06-02T10:00:00Z", [bank("b1", -30_000, "2032-06-07T10:00:00Z")]), .none, "five days later")
        // One digit misread by a known pair (729,99 against 739,99): found.
        expect(match(72_999, "2032-06-02T10:00:00Z", [bank("b1", -73_999, "2032-06-02T10:05:00Z")]),
               .confirmed(identity: "b1", timeFix: at("2032-06-02T10:05:00Z")), "misread digit")
        // A digit pair that the reading does not mix up (2↔4), or two digits off: not this purchase.
        expect(match(72_999, "2032-06-02T10:00:00Z", [bank("b1", -74_999, "2032-06-02T10:00:00Z")]), .none, "unknown digit pair")
        expect(match(72_999, "2032-06-02T10:00:00Z", [bank("b1", -73_899, "2032-06-02T10:00:00Z")]), .none, "two digits off")
        // A receipt without time: the time does not count and fixes nothing.
        expect(match(12_345, "2032-06-02T00:00:00Z", time: false, [bank("b1", -12_345, "2032-06-02T23:00:00Z")]),
               .confirmed(identity: "b1", timeFix: nil), "no time")
        // A manual entry, a cancelled purchase and money coming in are never the purchase.
        expect(match(12_345, "2032-06-02T10:00:00Z", [bank("manual:1", -12_345, "2032-06-02T10:00:00Z")]), .none, "manual entry")
        expect(match(12_345, "2032-06-02T10:00:00Z", [bank("b1", -12_345, "2032-06-02T10:00:00Z", status: "Отменена")]), .none, "cancelled")
        expect(match(12_345, "2032-06-02T10:00:00Z", [bank("b1", 12_345, "2032-06-02T10:00:00Z", kind: "income")]), .none, "income")
        // GPT stage 64 (R64-1): a pending Split instalment or move between own accounts is not the purchase; a purchase paid
        // with the points or Split is.
        expect(match(10_000, "2032-06-02T10:00:00Z", [bank("b1", -10_000, "2032-06-02T10:00:00Z", status: "В обработке", kind: "installment_payment")]),
               .none, "pending instalment")
        expect(match(10_000, "2032-06-02T10:00:00Z", [bank("b1", -10_000, "2032-06-02T10:00:00Z", status: "В обработке", kind: "internal_transfer")]),
               .none, "pending own transfer")
        // A pending purchase whose kind is not «expense» (older rows of the history) is still the purchase (46.50).
        expect(match(165_687, "2032-06-02T00:00:00Z", time: false, [bank("b1", -165_687, "2032-06-02T18:39:00Z", status: "В обработке", kind: "purchase")]),
               .confirmed(identity: "b1", timeFix: nil), "pending purchase of another kind")
        // A purchase still «в обработке» is the purchase.
        expect(match(12_345, "2032-06-02T10:00:00Z", [bank("b1", -12_345, "2032-06-02T10:01:00Z", status: "В обработке")]),
               .confirmed(identity: "b1", timeFix: at("2032-06-02T10:01:00Z")), "pending purchase")
        // The exact sum wins over a misread one of the same day.
        expect(match(72_999, "2032-06-02T10:00:00Z", time: false, [bank("b2", -73_999, "2032-06-02T10:00:00Z"), bank("b1", -72_999, "2032-06-02T10:00:00Z")]),
               .confirmed(identity: "b1", timeFix: nil), "exact before misread")
        // No sum or no date read: nothing to look for.
        expect(match(nil, "2032-06-02T10:00:00Z", [bank("b1", -12_345, "2032-06-02T10:00:00Z")]), .none, "no sum")
        expect(match(12_345, nil, [bank("b1", -12_345, "2032-06-02T10:00:00Z")]), .none, "no date")
        // At most five candidates.
        let many = (1...7).map { bank("b\($0)", -10_000, "2032-06-02T10:00:00Z") }
        if case .ambiguous(let ids) = match(10_000, "2032-06-02T10:00:00Z", many) {
            require(ids == ["b1", "b2", "b3", "b4", "b5"], "at most five candidates, in a stable order: \(ids)")
        } else { require(false, "seven equal purchases are ambiguous") }
        require(ReceiptBankMatch.amountScore(receipt: 1_000, bank: 1_000) == 100 && ReceiptBankMatch.amountScore(receipt: 2_000, bank: 3_000) == 40
                && ReceiptBankMatch.amountScore(receipt: 2_000, bank: 30_000) == nil, "amount score")
    }

    static func testForecastFixes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: 2024, month: month, day: day, hour: hour))!
        }
        func iso(_ month: Int, _ day: Int) -> String { String(format: "2024-%02d-%02dT10:00:00Z", month, day) }
        var history: [FinancialOperationInput] = []
        for month in 1...6 {
            history.append(op(100_000, kind: "income", category: "Зарплата", description: "ООО Ромашка", date: iso(month, 5)))
            history.append(op(-20_000, kind: "expense", category: "ЖКХ", description: "УК Жилищник", date: iso(month, 15)))
            // amounts that differ a lot, so the shop is not mistaken for a recurring payment
            history.append(op(-9_000, kind: "expense", category: "Супермаркеты", description: "Пятёрочка", date: iso(month, 3)))
            history.append(op(-21_000, kind: "expense", category: "Супермаркеты", description: "Пятёрочка", date: iso(month, 18)))
        }

        // An operation dated after today does not change today's forecast
        let todayPurchase = op(-60_000, kind: "expense", category: "Электроника", description: "DNS", date: iso(7, 9))
        let alone = FinancialEngine.monthForecast(history + [todayPurchase], now: at(7, 10), calendar: calendar)
        let withFuture = FinancialEngine.monthForecast(history + [todayPurchase, op(-5_000, kind: "expense", category: "Электроника", description: "DNS", date: iso(7, 20))],
                                                       now: at(7, 10), calendar: calendar)
        require(alone.oneOffKopecks == 60_000 && withFuture.oneOffKopecks == 60_000, "a purchase today stays one-off whatever is dated later")
        require(alone.projectedExpenseKopecks == withFuture.projectedExpenseKopecks, "a future-dated operation does not move the forecast")

        // Nameless titles are not a recurring payment
        let numbers = (0..<4).map { week in
            op(-1_000, kind: "expense", category: "Прочее", description: "12345", date: iso(6, 3 + week * 7))
        }
        require(FinancialEngine.recurringPatterns(numbers, now: at(7, 1), calendar: calendar).isEmpty, "four weekly operations named by digits are not one payee")

        // A payment of the 31st keeps its day after February
        let rent = [op(-30_000, kind: "expense", category: "ЖКХ", description: "Аренда Тест", date: "2023-11-30T10:00:00Z"),
                    op(-30_000, kind: "expense", category: "ЖКХ", description: "Аренда Тест", date: "2023-12-31T10:00:00Z"),
                    op(-30_000, kind: "expense", category: "ЖКХ", description: "Аренда Тест", date: iso(1, 31))]
        let march = FinancialEngine.monthForecast(rent, now: at(3, 5), calendar: calendar)
        require(march.upcoming.filter { $0.date >= at(3, 1, 0) }.map(\.date) == [at(3, 31)], "the rent of the 31st is expected on the 31st of March, not the 29th")
        // February's rent did not come either: since 46.24 it is still waited for in the first week of March (decision 5)
        require(march.upcoming.filter { $0.date < at(3, 1, 0) }.map(\.status) == [.waiting], "last month's missing rent is waited for, not dropped")

        // The first day of a month without history: one purchase is not multiplied by thirty
        let first = FinancialEngine.monthForecast([op(-10_000, kind: "expense", category: "Супермаркеты", description: "Магазин Тест", date: iso(7, 1))],
                                                  now: at(7, 1), calendar: calendar)
        require(first.projectedExpenseKopecks == 10_000 + 10_000 * 30 / 7, "at least a week of pace without history (got \(first.projectedExpenseKopecks))")

        // A salary that is late is counted neither in the reserve nor in the projected income
        let late = FinancialEngine.monthForecast(history, now: at(7, 20), calendar: calendar)
        require(late.upcoming.contains { $0.isIncome && $0.overdue }, "the salary of the 5th has not come by the 20th")
        require(late.expectedIncomeLeftKopecks == 0 && late.projectedIncomeKopecks == late.incomeKopecks, "an overdue income is counted nowhere")

        // MCC: a cut code does not hide the one in the title; the gaps of the table
        func category(_ mcc: String?, _ title: String) -> FinanceCategoryPath {
            FinancialEngine.expenseCategory(for: op(-1_000, kind: "expense", category: "Тест", description: title, mcc: mcc, date: iso(7, 1)))
        }
        require(category("54", "YANDEX*5411*DK").subcategory == "Супермаркеты", "a cut code falls back to the code in the title")
        require(category("5411", "Магазин Тест").subcategory == "Супермаркеты", "a full code is used")
        require(category("8011", "Клиника Тест").subcategory == "Здоровье", "doctors are health")
        require(category("8062", "Больница Тест").subcategory == "Здоровье", "hospitals are health")
        require(category("5732", "Магазин Тест").subcategory == "Электроника", "electronics shops")
        require(category("5734", "Магазин Тест").subcategory == "Электроника", "software shops")
    }

    static func testConfirmedNature() {
        let plain = op(5_100, kind: "unclassified_income", description: "Поступление Тест", date: "2032-06-02T10:00:00Z")
        require(FinancialEngine.classify(plain).type == .unknown, "an unproven incoming operation stays unknown by itself")
        var asIncome = plain
        asIncome.confirmedNature = "income"
        let income = FinancialEngine.classify(asIncome)
        require(income.type == .income && income.incomeContributionKopecks == 5_100, "confirmed as income: it is income")
        var asOwn = plain
        asOwn.confirmedNature = "own"
        let own = FinancialEngine.classify(asOwn)
        require(own.type == .internalTransfer && own.incomeContributionKopecks == 0 && own.expenseContributionKopecks == 0, "confirmed as own: a move, not income")
        var asRefund = plain
        asRefund.confirmedNature = "refund"
        let refund = FinancialEngine.classify(asRefund)
        require(refund.type == .refund && refund.refundContributionKopecks == 5_100 && refund.incomeContributionKopecks == 0, "confirmed as a refund: it reduces the expenses")
        // a cancelled payment: the money was taken and came back
        let cancelled = op(22_700, kind: "unclassified_income", description: "Отмена оплаты услуг SHOP*4215*DOSTAVKA", date: "2032-06-02T12:00:00Z")
        let charge = op(-22_700, kind: "expense", category: "Тест", description: "Оплата услуг SHOP*4215*DOSTAVKA", date: "2032-06-02T11:00:00Z")
        require(FinancialEngine.classify(cancelled).type == .refund, "a cancellation of a payment is a refund without any confirmation")
        let net = FinancialEngine.report([charge, cancelled], in: DateInterval(start: BankDateParser.parse("2032-06-01T00:00:00Z")!, end: BankDateParser.parse("2032-07-01T00:00:00Z")!))
        require(net.netExpenseKopecks == 0 && net.incomeKopecks == 0, "the charge and its cancellation cancel out and are not income")
        require(FinancialEngine.classify(op(-3_000, kind: "expense", category: "Тест", description: "Отмена оплаты услуг SHOP", date: "2032-06-02T12:00:00Z")).type == .expense,
                "only an incoming cancellation is a refund")
        // it never changes what the engine already named
        var salary = op(5_200, kind: "unclassified_income", category: "Зарплата", description: "Зарплата за месяц", date: "2032-06-02T10:00:00Z")
        salary.confirmedNature = "own"
        require(FinancialEngine.classify(salary).type == .income, "a named income is not turned into a transfer")
        var purchase = op(-5_000, kind: "expense", category: "Супермаркеты", description: "Магазин Тест", date: "2032-06-02T10:00:00Z")
        purchase.confirmedNature = "income"
        require(FinancialEngine.classify(purchase).type == .expense, "an expense stays an expense")

        // a transfer from a person is income by itself; the owner's choice in the card wins over it
        let fromPerson = op(6_500_000, kind: "unclassified_income", category: "Не определено", description: "Перевод от Елизавета В.", date: "2032-06-02T10:00:00Z")
        let personTransfer = FinancialEngine.classify(fromPerson)
        require(personTransfer.type == .income && personTransfer.incomeContributionKopecks == 6_500_000, "a transfer from a person is income without any confirmation")
        var personOwn = fromPerson
        personOwn.confirmedNature = "own"
        let personOwnResult = FinancialEngine.classify(personOwn)
        require(personOwnResult.type == .internalTransfer && personOwnResult.incomeContributionKopecks == 0, "the owner can say a transfer from a person is his own move")
        var personRefund = fromPerson
        personRefund.confirmedNature = "refund"
        require(FinancialEngine.classify(personRefund).type == .refund, "the owner can say a transfer from a person is a refund")
        let personTagged = op(1_000, kind: "transfer", category: "Переводы", description: "Перевод от Анна К.", date: "2032-06-02T10:00:00Z")
        var personTaggedOwn = personTagged
        personTaggedOwn.confirmedNature = "own"
        require(FinancialEngine.classify(personTagged).type == .income && FinancialEngine.classify(personTaggedOwn).type == .internalTransfer, "a tagged transfer from a person also takes the owner's choice")
        require(FinancialEngine.classify(op(-7_004_626, kind: "expense", category: "Перевод", description: "Перевод Елизавета В", date: "2032-06-01T10:00:00Z")).type == .expense, "a transfer to a person stays an expense")
        require(FinancialEngine.classify(op(2_000, kind: "internal_transfer", description: "Перевод от Анна К.", date: "2032-06-02T10:00:00Z")).type == .internalTransfer, "a move the bank named as between own accounts stays one")
        require(FinancialEngine.classify(op(2_000, kind: "unclassified_income", description: "Поступление от Анна К.", date: "2032-06-02T10:00:00Z")).type == .unknown, "only the bank's «Перевод от» title makes it income")
        require(FinancialEngine.classify(op(-2_000, kind: "expense", category: "Тест", description: "Перевод от Анна К.", date: "2032-06-02T10:00:00Z")).type == .expense, "an outgoing amount is never a transfer from a person")

        // the history: only an unknown incoming bank operation takes the confirmation
        var history = SavedHistory()
        let unknown = bankOp("nat1", 5_100, description: "Поступление Тест", kind: "unclassified_income", date: "2032-06-02T10:00:00Z")
        let bought = bankOp("nat2", -5_000, description: "Магазин Тест", mcc: "5411", date: "2032-06-03T10:00:00Z")
        history.operations = [unknown, bought]
        require(!history.confirmNature(.income, for: bought), "an expense cannot be confirmed as income")
        require(history.operationNatures == nil, "a refused confirmation changes nothing")
        require(history.confirmNature(.income, for: unknown) && history.confirmedNature(for: unknown) == .income, "an unknown incoming operation takes it")
        let personFrom = bankOp("nat3", 6_500_000, description: "Перевод от Елизавета В.", kind: "unclassified_income", date: "2032-06-04T10:00:00Z")
        history.operations.append(personFrom)
        require(history.confirmNature(.own, for: personFrom) && history.confirmedNature(for: personFrom) == .own, "a transfer from a person takes the owner's choice")
        require(FinancialEngine.report(history.financialInputs, in: DateInterval(start: BankDateParser.parse("2032-06-04T00:00:00Z")!, end: BankDateParser.parse("2032-06-05T00:00:00Z")!), taxonomy: history.expenseTaxonomy).incomeKopecks == 0, "a transfer from a person taken as an own move is no income")
        require(history.confirmNature(nil, for: personFrom), "the choice can be taken back")
        history.operations.removeLast()
        let inputs = history.financialInputs
        let interval = DateInterval(start: BankDateParser.parse("2032-06-01T00:00:00Z")!, end: BankDateParser.parse("2032-07-01T00:00:00Z")!)
        require(FinancialEngine.report(inputs, in: interval, taxonomy: history.expenseTaxonomy).incomeKopecks == 5_100, "the confirmed income is in the report")
        require(history.setIncomeCategory("Прочие доходы", for: unknown, forSender: false), "a confirmed income can be given an income category")
        require(history.confirmNature(.refund, for: unknown), "it can be confirmed as a refund")
        let refundReport = FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy)
        require(refundReport.incomeKopecks == 0 && refundReport.refundsKopecks == 5_100, "a confirmed refund reduces the expenses, it is not income")
        require(history.confirmNature(.own, for: unknown), "the choice can be changed")
        let ownReport = FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy)
        require(ownReport.incomeKopecks == 0, "confirmed as own: nothing comes into the income")
        require(history.confirmNature(nil, for: unknown) && history.operationNatures == nil && history.incomeCategoryOverrides?[unknown.identity] == nil,
                "taking the confirmation back clears it and the income category chosen for it")
        require(FinancialEngine.report(history.financialInputs, in: interval, taxonomy: history.expenseTaxonomy).incomeKopecks == 0, "unknown again: not income")
        history.confirmNature(.income, for: unknown)
        let back = try! HistoryBackup.decode(HistoryBackup.encode(history))
        require(back.operationNatures == history.operationNatures, "the confirmation survives the backup")
        require((try! HistoryBackup.decode(HistoryBackup.encode(SavedHistory()))).operationNatures == nil, "an old backup opens")
    }

    static func testReceiptArchive() {
        require(ReceiptArchive.crc32(Data("123456789".utf8)) == 0xCBF43926, "the standard CRC-32 check value")
        let photo = Data([0xFF, 0xD8, 0x00, 0x01, 0x02, 0xFF, 0xD9])
        let big = Data((0..<70_000).map { UInt8($0 % 251) })
        let first = ReceiptLogic.fileName(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let second = ReceiptLogic.fileName(id: UUID(uuidString: "aaaaaaaa-2222-3333-4444-555555555555")!)
        let zip = ReceiptArchive.make([(first, photo), (second, big), ("empty.bin", Data())])
        let back = ReceiptArchive.read(zip)
        require(back?.map(\.name) == [first, second, "empty.bin"], "the names come back in order")
        require(back?[0].data == photo && back?[1].data == big && back?[2].data.isEmpty == true, "the contents come back exactly")
        require(ReceiptArchive.read(ReceiptArchive.make([]))?.isEmpty == true, "an archive without files is valid and empty")
        require(ReceiptArchive.read(Data("not a zip at all, just text".utf8)) == nil, "a text is not an archive")
        require(ReceiptArchive.read(Data()) == nil, "an empty file is not an archive")
        // 46.50: one copy of everything, and the older copies still restore.
        let historyJSON = Data("{\"formatVersion\":1}".utf8)
        let full = FullBackup.read(FullBackup.make(history: historyJSON, photos: [(first, photo), (second, big)]))
        require(full?.history == historyJSON && full?.photos.map(\.name) == [first, second] && full?.photos.map(\.data) == [photo, big],
                "the copy of everything holds the history and the photos")
        let oldJSON = FullBackup.read(Data("  \n{\"formatVersion\":1}".utf8))
        require(oldJSON?.history != nil && oldJSON?.photos.isEmpty == true, "an old JSON copy is a history without photos")
        let oldPhotos = FullBackup.read(ReceiptArchive.make([(first, photo)]))
        require(oldPhotos?.history == nil && oldPhotos?.photos.count == 1, "an old archive of photos is photos without a history")
        require(FullBackup.read(Data("not a copy".utf8)) == nil && FullBackup.read(Data()) == nil, "anything else is not a copy")
        var damaged = zip
        damaged[30 + first.count] ^= 0xFF
        require(ReceiptArchive.read(damaged) == nil, "a changed byte is found by the checksum")
        require(ReceiptArchive.read(zip.prefix(60)) == nil, "a cut file is refused")
        // the closing record points at the right places (an ordinary ZIP reader needs it)
        let tail = [UInt8](zip.suffix(22))
        require(tail[0] == 0x50 && tail[1] == 0x4B && tail[2] == 0x05 && tail[3] == 0x06 && tail[10] == 3, "the closing record with three files")
    }

    static func testReceiptParser() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let now = date(2032, 10, 8, 18, 0)

        // The QR code of a cash receipt
        let qr = ReceiptParser.parseQR("t=20321008T1425&s=175.50&fn=12345&i=12345&fp=1234567890&n=1", calendar: calendar)
        require(qr?.totalKopecks == 17_550 && qr?.date == date(2032, 10, 8, 14, 25), "the QR code gives the sum and the moment")
        let qrSeconds = ReceiptParser.parseQR("t=20321008T142507&s=1200&fn=1&i=2&fp=3&n=1", calendar: calendar)
        require(qrSeconds?.totalKopecks == 120_000 && qrSeconds?.date == date(2032, 10, 8, 14, 25).addingTimeInterval(7), "a sum without kopecks, a time with seconds (kept)")
        require(ReceiptParser.parseQR("https://example.com/page?a=1", calendar: calendar) == nil, "a link is not a receipt")
        require(ReceiptParser.parseQR("t=20321308T1425&s=10.00&fn=1", calendar: calendar)?.date == nil, "an impossible date is dropped")

        // Money in text
        require(ReceiptParser.amounts(in: "ИТОГО 1 234,56") == [123_456], "a space between thousands, a comma")
        require(ReceiptParser.amounts(in: "ИТОГО 1234.56") == [123_456], "a point")
        require(ReceiptParser.amounts(in: "Молоко 2 x 65.00 130.00") == [6_500, 13_000], "several sums in a line")
        require(ReceiptParser.amounts(in: "К оплате 1 500 руб") == [150_000], "whole roubles with a word")
        require(ReceiptParser.amounts(in: "ИНН 7700000000").isEmpty, "a long number is not a sum")

        // A whole receipt (an invented one)
        let receipt = ["ООО \"Ромашка Тест\"", "КАССОВЫЙ ЧЕК", "г. Тестоград, ул. Придуманная, 1", "Молоко 2 x 65.00 130.00",
                       "Хлеб 1 x 45.50 45.50", "ИТОГО 175.50", "НДС 10% 15.95", "Наличные 200.00", "Сдача 24.50", "08.10.2032 14:25"]
        let parsed = ReceiptParser.parseText(receipt, now: now, calendar: calendar)
        require(parsed.totalKopecks == 17_550, "the total is the ИТОГО line, not the VAT, the cash or the change")
        require(parsed.date == date(2032, 10, 8, 14, 25), "the date and the time")
        require(parsed.merchant == "Ромашка Тест", "the shop without the legal form and quotes")

        require(ReceiptParser.parseText(["Магазин Тест", "ИТОГО 1 200,00", "СКИДКА 100,00", "К ОПЛАТЕ 1 100,00"], now: now, calendar: calendar).totalKopecks == 110_000,
                "the sum to pay wins over the sum before the discount")
        require(ReceiptParser.parseText(["Магазин Тест", "ИТОГО", "2 345,00"], now: now, calendar: calendar).totalKopecks == 234_500, "the sum on the next line")
        require(ReceiptParser.parseText(["Магазин Тест", "08.10.32 09:05", "ИТОГО 10.00"], now: now, calendar: calendar).date == date(2032, 10, 8, 9, 5), "a two-digit year")
        require(ReceiptParser.parseText(["Магазин Тест", "08.10.2040 09:05", "ИТОГО 10.00"], now: now, calendar: calendar).date == nil, "a date from the future is not taken")
        require(ReceiptParser.parseText(["Магазин Тест", "07.10.2032", "ИТОГО 10.00"], now: now, calendar: calendar).date == date(2032, 10, 7, 12, 0), "no time: noon")
        require(ReceiptParser.parseText(["Магазин Тест", "08.10.2032", "ИТОГО 10.00"], now: now, calendar: calendar).date == now, "no time on a receipt of today: now")
        require(ReceiptParser.parseText(["случайный текст"], now: now, calendar: calendar).totalKopecks == nil, "no sum in a text without one")
        require(ReceiptParser.parseText(["АО Тандер", "ИТОГО 99.00"], now: now, calendar: calendar).merchant == "Магнит", "a chain by its legal name")
        require(ReceiptParser.parseText(["КАССОВЫЙ ЧЕК", "МАГАЗИН ПРОДУКТЫ", "ИТОГО 99.00"], now: now, calendar: calendar).merchant == "Магазин Продукты", "capital letters become a name")
        let merged = ReceiptParser.merge(qr: qr, text: ParsedReceipt(totalKopecks: 17_000, date: nil, merchant: "Тест"))
        require(merged.totalKopecks == 17_550 && merged.date == date(2032, 10, 8, 14, 25) && merged.merchant == "Тест", "the QR wins for the sum and the date")

        // The category and the account for the form
        require(ReceiptParser.keywordCategory(merchant: "Магазин Продукты")?.subcategory == "Супермаркеты", "a grocery shop")
        require(ReceiptParser.keywordCategory(merchant: "Кофейня Тест")?.subcategory == "Кафе и рестораны", "a coffee shop")
        require(ReceiptParser.keywordCategory(merchant: "Ромашка Тест") == nil, "an unknown shop has no guess")
        var history = SavedHistory()
        let tree = history.categoryTree
        let category = tree[1].categories[0]
        history.categoryRules = [CategoryRule(payeeKey: FinancialEngine.payeeRuleKey("Ромашка Тест"), title: "Ромашка Тест", categoryID: category.id)]
        let byRule = history.suggestedExpenseCategory(forMerchant: "Ромашка Тест")
        require(byRule?.group == tree[1].name && byRule?.subcategory == category.name, "the rule of the user wins")
        require(SavedHistory().suggestedExpenseCategory(forMerchant: "Кофейня Тест")?.group == "Еда", "the words work without rules")
        require(SavedHistory().suggestedExpenseCategory(forMerchant: "Ромашка Тест") == nil, "nothing is guessed for an unknown shop")
        let cash = Account(name: "Наличные", icon: "banknote", color: "green", startBalanceKopecks: 0, startDate: date(2032, 1, 1))
        let card = Account(name: "Карта", icon: "creditcard", color: "blue", startBalanceKopecks: 0, startDate: date(2032, 1, 1), tracksBankCard: true)
        var withAccounts = SavedHistory()
        withAccounts.accounts = [cash, card]
        require(withAccounts.lastManualAccountID == nil, "no manual operations, no account")
        withAccounts.manualOperations = [
            ManualOperation(kind: .expense, amountKopecks: 100, date: date(2032, 5, 1), accountID: card.id, group: "Еда", subcategory: "Супермаркеты"),
            ManualOperation(kind: .expense, amountKopecks: 200, date: date(2032, 5, 2), accountID: cash.id, group: "Еда", subcategory: "Супермаркеты"),
        ]
        require(withAccounts.lastManualAccountID == cash.id, "the account of the latest manual operation")
        withAccounts.manualOperations?.removeLast()
        require(withAccounts.lastManualAccountID == nil, "a card account is not kept by hand")
    }

    static func testReceipts() {
        let first = ReceiptLogic.fileName(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let second = ReceiptLogic.fileName()
        require(first == "receipt-11111111-2222-3333-4444-555555555555.jpg", "the file name is made of the id")
        require(ReceiptLogic.isValid(fileName: first) && ReceiptLogic.isValid(fileName: second), "names made by the app are valid")
        for bad in ["", "../receipt-11111111-2222-3333-4444-555555555555.jpg", "receipt-11111111-2222-3333-4444-555555555555.png",
                    "receipt-.jpg", "RECEIPT-11111111-2222-3333-4444-555555555555.jpg", "a/receipt-11111111-2222-3333-4444-555555555555.jpg",
                    "receipt-11111111-2222-3333-4444-555555555555.jpg/../x"] {
            require(!ReceiptLogic.isValid(fileName: bad), "a foreign file name is never used: \(bad)")
        }
        let wide = ReceiptLogic.scaledSize(width: 4000, height: 2000)
        require(wide.width == 1600 && wide.height == 800, "a wide photo is fitted by its longer side")
        let tall = ReceiptLogic.scaledSize(width: 1500, height: 3000)
        require(tall.width == 800 && tall.height == 1600, "a tall photo is fitted by its longer side")
        let small = ReceiptLogic.scaledSize(width: 800, height: 600)
        require(small.width == 800 && small.height == 600, "a small photo is not enlarged")
        require(ReceiptLogic.scaledSize(width: 0, height: 0) == (0, 0), "an empty photo stays empty")

        var history = SavedHistory()
        let operation = bankOp("receipt-op", -10_000, description: "Магазин", mcc: "5411", date: "2032-06-02T10:00:00Z")
        require(!history.hasReceipt(operation) && history.receiptFiles(forIdentity: operation.identity).isEmpty, "no photos at first")
        history.addReceipt(first, toIdentity: operation.identity)
        history.addReceipt(first, toIdentity: operation.identity)
        history.addReceipt(second, toIdentity: operation.identity)
        history.addReceipt("../evil.jpg", toIdentity: operation.identity)
        require(history.receiptFiles(forIdentity: operation.identity) == [first, second], "photos are added once, a foreign name is refused")
        require(history.hasReceipt(operation), "the operation has a photo")
        let decoded = try! HistoryBackup.decode(HistoryBackup.encode(history))
        require(decoded.receipts == history.receipts, "the references survive the backup")
        history.removeReceipt(first, fromIdentity: operation.identity)
        require(history.receiptFiles(forIdentity: operation.identity) == [second], "one photo is removed")
        history.removeReceipt(second, fromIdentity: operation.identity)
        require(history.receipts == nil, "without photos the field is empty again")
        history.addReceipt(first, toIdentity: operation.identity)
        require(history.removeReceipts(forIdentity: operation.identity) == [first] && history.receipts == nil, "a deleted operation gives back its files")
        require(history.removeReceipts(forIdentity: "unknown").isEmpty, "nothing to remove for an unknown operation")
        require((try! HistoryBackup.decode(HistoryBackup.encode(SavedHistory()))).receipts == nil, "an old backup without photos opens")
    }

    /// The account selection of the reports (block 2): which operations belong to which account.
    static func testReportAccountScope() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func day(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2032, month: month, day: day, hour: 10))! }
        let september = DateInterval(start: calendar.date(from: DateComponents(year: 2032, month: 9, day: 1))!,
                                     end: calendar.date(from: DateComponents(year: 2032, month: 10, day: 1))!)
        let taxonomy = ExpenseTaxonomy.builtin
        let group = AccountGroup(name: "Наличные и кошельки")
        let card = Account(name: "Яндекс банк", icon: "creditcard", color: "blue", startBalanceKopecks: 0, startDate: day(1, 1), tracksBankCard: true)
        let cash = Account(name: "Наличные", icon: "banknote", color: "green", groupID: group.id, startBalanceKopecks: 0, startDate: day(1, 1))
        let wallet = Account(name: "Кошелёк", icon: "wallet.pass", color: "orange", groupID: group.id, startBalanceKopecks: 0, startDate: day(1, 1))
        var history = SavedHistory()
        history.accountGroups = [group]
        history.accounts = [card, cash, wallet]
        history.operations = [
            BankOperation(identity: "bank-1", occurredAt: "2032-09-03T10:00:00Z", timePrecision: "second", description: "Пятёрочка",
                          amountKopecks: -30_000, currency: "RUB", status: "Выполнено", category: "Супермаркеты", mcc: nil, purpose: nil,
                          paymentMethod: nil, providers: [], kind: "expense"),
        ]
        history.manualOperations = [
            ManualOperation(kind: .expense, amountKopecks: 10_000, date: day(9, 4), accountID: cash.id, group: "Еда", subcategory: "Кафе и рестораны"),
            ManualOperation(kind: .expense, amountKopecks: 5_000, date: day(9, 5), accountID: wallet.id, group: "Транспорт", subcategory: "Такси"),
            ManualOperation(kind: .income, amountKopecks: 70_000, date: day(9, 6), accountID: cash.id, subcategory: "Другое"),
            ManualOperation(kind: .expense, amountKopecks: 2_000, date: day(9, 7), accountID: nil, group: "Еда", subcategory: "Супермаркеты"),
        ]
        let inputs = history.financialInputs
        require(inputs.count == 5, "every operation has an input")
        require(inputs[0].accountID == nil, "a bank row belongs to no manual account")
        require(inputs[1].accountID == cash.id && inputs[2].accountID == wallet.id, "a manual entry carries its account")
        require(inputs[4].accountID == ReportAccountScope.noAccount, "a manual entry without an account gets the placeholder")

        func total(_ scope: ReportAccountScope, _ mode: ReportMode = .expenses) -> Int64 {
            ReportEngine.slices(inputs, in: september, mode: mode, grouping: .categories, taxonomy: taxonomy,
                                filter: ReportFilter(scope: scope)).reduce(0) { $0 + $1.amountKopecks }
        }
        require(total(.all) == 47_000, "all accounts: everything, also the entry without an account")
        require(total(.accounts([card])) == 30_000, "the card: the bank rows only")
        require(total(.accounts([cash])) == 10_000, "one cash account: its manual entries only")
        require(total(.accounts([cash, wallet])) == 15_000, "a group: the manual entries of its accounts")
        require(total(.accounts([card, cash, wallet])) == 45_000, "every account chosen by hand leaves out the entry without an account")
        require(total(.accounts([cash]), .income) == 70_000 && total(.accounts([wallet]), .income) == 0, "income follows the account too")
        require(total(.accounts([])) == 0, "an empty group shows nothing")

        // The flow and the bars use the same selection.
        let buckets = [september]
        let flow = ReportEngine.flow(inputs, buckets: buckets, filter: ReportFilter(scope: .accounts([cash])))
        require(flow.first?.expenseKopecks == 10_000 && flow.first?.incomeKopecks == 70_000, "income and expenses of one account")
        let bars = ReportEngine.bars(inputs, buckets: buckets, mode: .expenses, grouping: .categories, filter: ReportFilter(scope: .accounts([wallet])))
        require(bars.map(\.amountKopecks) == [5_000], "the dynamics of one account")
        let scopedOnly = ReportFilter(scope: .accounts([cash]))
        require(!scopedOnly.isActive, "the choice of accounts is not an exclusion")
        require(ReportEngine.isAllowed(inputs[1], by: scopedOnly) && !ReportEngine.isAllowed(inputs[2], by: scopedOnly)
                && !ReportEngine.isAllowed(inputs[0], by: scopedOnly), "the list behind a row holds the chosen accounts only")
        require(ReportFilter(scope: .accounts([cash])).cacheKey != ReportFilter(scope: .accounts([wallet])).cacheKey
                && ReportFilter.none.cacheKey == ReportFilter(scope: .all).cacheKey, "the scope is part of the cache key")

        // The menu: what a choice means, and what a deleted choice falls back to.
        let accounts = history.accounts ?? []
        let groups = history.accountGroups ?? []
        let everything = ReportAccountChoice.all.resolve(accounts: accounts, groups: groups)
        require(everything.scope.isAll && everything.title == "Все счета" && everything.accounts.count == 3 && everything.isValid, "all accounts")
        let one = ReportAccountChoice.account(cash.id).resolve(accounts: accounts, groups: groups)
        require(one.title == "Наличные" && one.accounts == [cash] && !one.scope.isAll && !one.scope.includesBankCard, "one account")
        let bank = ReportAccountChoice.account(card.id).resolve(accounts: accounts, groups: groups)
        require(bank.scope.includesBankCard, "the scanned card brings the bank rows")
        let members = ReportAccountChoice.group(group.id).resolve(accounts: accounts, groups: groups)
        require(members.title == group.name && members.accounts == [cash, wallet] && !members.scope.includesBankCard, "a group is its accounts")
        let gone = ReportAccountChoice.account(UUID()).resolve(accounts: accounts, groups: groups)
        require(gone.scope.isAll && !gone.isValid && gone.title == "Все счета", "a deleted account means all accounts")
        let goneGroup = ReportAccountChoice.group(UUID()).resolve(accounts: accounts, groups: groups)
        require(goneGroup.scope.isAll && !goneGroup.isValid, "a deleted group means all accounts")

        // A manual entry of a deleted account still counts under «all accounts» and nowhere else.
        history.accounts = [card, wallet]
        let orphan = history.financialInputs
        require(orphan[1].accountID == cash.id, "the entry keeps the id of the deleted account")
        require(ReportEngine.slices(orphan, in: september, mode: .expenses, grouping: .categories, taxonomy: taxonomy,
                                    filter: ReportFilter(scope: .accounts([wallet]))).reduce(0) { $0 + $1.amountKopecks } == 5_000,
                "the orphan does not leak into another account")
    }

    /// Budgets (block 2): limits per group and for the month, what is spent against them, the 90 % and exceeded levels.
    static func testBudgets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func day(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2032, month: month, day: day, hour: 10))! }
        func iso(_ month: Int, _ day: Int) -> String { String(format: "2032-%02d-%02dT10:00:00Z", month, day) }
        let taxonomy = ExpenseTaxonomy.builtin
        let september = day(9, 15)

        // Levels: calm up to 90 %, a warning from 90 % up to the limit, exceeded above it.
        require(BudgetEngine.level(spent: 0, limit: 10_000) == .calm, "nothing spent")
        require(BudgetEngine.level(spent: 8_999, limit: 10_000) == .calm, "just under 90 %")
        require(BudgetEngine.level(spent: 9_000, limit: 10_000) == .warning, "90 % is a warning")
        require(BudgetEngine.level(spent: 10_000, limit: 10_000) == .warning, "exactly the limit is not yet exceeded")
        require(BudgetEngine.level(spent: 10_001, limit: 10_000) == .exceeded, "one kopeck over")
        require(BudgetEngine.level(spent: 500, limit: 0) == .calm, "no limit, nothing to exceed")
        require(BudgetEngine.level(spent: -300, limit: 10_000) == .calm, "refunds above spending do not warn")
        let percent = BudgetStatus(group: "Еда", limitKopecks: 10_000, spentKopecks: 9_999, isMonthOnly: false)
        require(percent.percent == 99 && percent.remainingKopecks == 1 && percent.level == .warning, "99.99 % is 99 %, one kopeck left")
        let over = BudgetStatus(group: nil, limitKopecks: 10_000, spentKopecks: 12_500, isMonthOnly: false)
        require(over.percent == 125 && over.remainingKopecks == -2_500 && over.level == .exceeded, "125 %, 25 ₽ over")
        require(BudgetStatus(group: nil, limitKopecks: 0, spentKopecks: 5, isMonthOnly: false).percent == 0, "a zero limit does not divide")

        // Setting and removing
        var history = SavedHistory()
        require(!history.setBudget(group: "Еда", limitKopecks: 0, month: nil) && !history.setBudget(group: "Еда", limitKopecks: -5, month: nil)
                && history.budgets == nil, "a limit that is not positive is refused and nothing changes")
        require(history.setBudget(group: "Еда", limitKopecks: 30_000, month: nil), "a limit of every month")
        require(history.setBudget(group: "Еда", limitKopecks: 40_000, month: nil) && history.budgets?.count == 1, "the same limit is replaced, not added")
        require(history.setBudget(group: "Еда", limitKopecks: 50_000, month: "2032-09") && history.budgets?.count == 2, "a limit of one month is a separate entry")
        require(history.setBudget(group: nil, limitKopecks: 100_000, month: nil), "a limit of the whole month")
        let held = history.budgets ?? []
        require(BudgetEngine.limit(held, group: "Еда", monthKey: "2032-09")?.limitKopecks == 50_000
                && BudgetEngine.limit(held, group: "Еда", monthKey: "2032-09")?.isMonthOnly == true, "the limit of the month wins")
        require(BudgetEngine.limit(held, group: "Еда", monthKey: "2032-10")?.limitKopecks == 40_000
                && BudgetEngine.limit(held, group: "Еда", monthKey: "2032-10")?.isMonthOnly == false, "other months keep the limit of every month")
        require(BudgetEngine.limit(held, group: "Транспорт", monthKey: "2032-09") == nil, "no limit for a group without one")
        history.removeBudget(group: "Еда", month: "2032-09")
        require(BudgetEngine.limit(history.budgets ?? [], group: "Еда", monthKey: "2032-09")?.limitKopecks == 40_000, "removing the month's limit brings back the general one")
        history.removeBudget(group: "Еда", month: nil)
        history.removeBudget(group: nil, month: nil)
        require(history.budgets == nil, "no limits left: the field is empty again")
        require(BudgetEngine.monthKey(september, calendar: calendar) == "2032-09" && BudgetEngine.monthKey(day(1, 31), calendar: calendar) == "2032-01", "month keys")

        // Statuses over operations
        func expense(_ amount: Int64, _ description: String, _ category: String, _ date: String) -> FinancialOperationInput {
            op(-amount, kind: "expense", category: category, description: description, date: date)
        }
        let inputs: [FinancialOperationInput] = [
            expense(30_000, "Пятёрочка", "Супермаркеты", iso(9, 3)),
            expense(20_000, "Кофейня", "Кафе", iso(9, 4)),
            expense(15_000, "Такси", "Такси", iso(9, 10)),
            expense(99_000, "Прошлый месяц", "Супермаркеты", iso(8, 30)),
            op(5_000, kind: "refund", category: "Возврат", description: "Возврат Пятёрочка", date: iso(9, 5)),
            op(-70_000, kind: "internal_transfer", description: "Перевод между счетами одного клиента", date: iso(9, 6)),
        ]
        let budgets = [
            Budget(group: nil, limitKopecks: 100_000, month: nil),
            Budget(group: "Еда", limitKopecks: 55_000, month: nil),
            Budget(group: "Транспорт", limitKopecks: 20_000, month: nil),
            Budget(group: "Транспорт", limitKopecks: 16_000, month: "2032-09"),
            Budget(group: "Другое", limitKopecks: 10_000, month: "2032-10"),
            Budget(group: "Старая группа", limitKopecks: 7_000, month: nil),
        ]
        let statuses = BudgetEngine.statuses(inputs: inputs, budgets: budgets, month: september, taxonomy: taxonomy, calendar: calendar)
        require(statuses.map(\.group) == [nil, "Еда", "Транспорт", "Старая группа"], "the month first, groups in the tree's order, unknown groups last; other months' limits are out")
        require(statuses[0].spentKopecks == 60_000 && statuses[0].limitKopecks == 100_000 && statuses[0].level == .calm,
                "the month: expenses net of the refund, transfers and other months out")
        require(statuses[1].spentKopecks == 50_000 && statuses[1].percent == 90 && statuses[1].level == .warning, "a group: its purchases of the month only, 90 % warns")
        require(statuses[2].limitKopecks == 16_000 && statuses[2].isMonthOnly && statuses[2].spentKopecks == 15_000 && statuses[2].level == .warning,
                "the month's own limit is used")
        require(statuses[3].spentKopecks == 0 && statuses[3].level == .calm, "a group that is not in the tree has nothing spent")
        require(BudgetEngine.statuses(inputs: inputs, budgets: [], month: september, taxonomy: taxonomy, calendar: calendar).isEmpty, "no budgets, no statuses")
        let october = BudgetEngine.statuses(inputs: inputs, budgets: budgets, month: day(10, 5), taxonomy: taxonomy, calendar: calendar)
        require(Set(october.map(\.group)) == [nil, "Другое", "Еда", "Транспорт", "Старая группа"] && october.first { $0.group == "Транспорт" }?.limitKopecks == 20_000,
                "October shows its own limit and the general ones")
        require(october.first { $0.group == nil }?.spentKopecks == 0, "no expenses yet in October")
        // The lines of the main screen
        let calmGroup = BudgetStatus(group: "Еда", limitKopecks: 10_000, spentKopecks: 1_000, isMonthOnly: false)
        let nearGroup = BudgetStatus(group: "Транспорт", limitKopecks: 10_000, spentKopecks: 9_500, isMonthOnly: false)
        let overGroup = BudgetStatus(group: "Жильё", limitKopecks: 10_000, spentKopecks: 12_000, isMonthOnly: false)
        let overMonth = BudgetStatus(group: nil, limitKopecks: 10_000, spentKopecks: 20_000, isMonthOnly: false)
        require(BudgetEngine.notices([calmGroup, overMonth]).isEmpty, "a calm group and the month's own bar make no line")
        let lines = BudgetEngine.notices([overMonth, calmGroup, nearGroup, overGroup])
        require(lines.map(\.level) == [.exceeded, .warning], "over the limit first, then the warning")
        require(lines[0].text == "Превышен бюджет: Жильё" && lines[1].text == "Почти исчерпан бюджет: Транспорт", "groups named in the lines")
    }

    /// The period of the main screen is remembered between launches.
    static func testHistoryPeriodStorage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2032, month: month, day: day, hour: hour))!
        }
        for period in [HistoryPeriod.lastDays(1), .lastDays(30), .lastDays(365), .allTime, .monthToDate, .custom(from: date(9, 1), through: date(9, 8, 15))] {
            require(HistoryPeriod(storageText: period.storageText) == period, "remembered and restored: \(period.storageText)")
        }
        require(HistoryPeriod(storageText: "") == nil && HistoryPeriod(storageText: "days:0") == nil && HistoryPeriod(storageText: "days:-5") == nil
                && HistoryPeriod(storageText: "days:99999") == nil && HistoryPeriod(storageText: "custom:1") == nil
                && HistoryPeriod(storageText: "custom:a:b") == nil && HistoryPeriod(storageText: "all:1") == nil
                && HistoryPeriod(storageText: "month:1") == nil && HistoryPeriod(storageText: "months") == nil, "text that is not a period restores nothing")
        let month = HistoryPeriod.currentMonth(now: date(9, 17, 13), calendar: calendar)
        require(month == .monthToDate && HistoryPeriod(storageText: "month") == .monthToDate, "the current month is remembered as the running month")
        require(historyInterval(month, now: date(9, 17, 13), calendar: calendar) == DateInterval(start: date(9, 1), end: date(9, 18)),
                "the 1st and today are both inside")
        require(historyInterval(month, now: date(10, 2, 8), calendar: calendar) == DateInterval(start: date(10, 1), end: date(10, 3)),
                "the next day and the next month it moves on with the calendar")
        require(historyInterval(.monthToDate, now: date(9, 1), calendar: calendar) == DateInterval(start: date(9, 1), end: date(9, 2)), "on the 1st it is one day")
        // after a save: the period in use stays when it covers the day, else the month of the day (never a lone day)
        let today = date(9, 17, 13)
        require(HistoryPeriod.showing(date(9, 17, 9), current: .monthToDate, now: today, calendar: calendar) == .monthToDate, "the running month already covers today")
        require(HistoryPeriod.showing(date(9, 5), current: .lastDays(7), now: today, calendar: calendar) == .monthToDate, "a day of the running month outside the period shows the running month")
        require(HistoryPeriod.showing(date(8, 20), current: .monthToDate, now: today, calendar: calendar) == .custom(from: date(8, 1), through: date(8, 31)), "a past month is shown whole")
        require(HistoryPeriod.showing(date(9, 25), current: .monthToDate, now: today, calendar: calendar) == .custom(from: date(9, 1), through: date(9, 30)), "a day after today shows the whole month")
        require(HistoryPeriod.showing(date(9, 3), current: .allTime, now: today, calendar: calendar) == .allTime, "all time covers it")
    }

    /// The first real receipt (stage 46.10): «ИТОГ БЕЗ СКИДОК» was taken for the total.
    static func testReceiptTotals() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 20, minute: 0))!
        let discounted = ["МАГАЗИН ТЕСТ", "ЦЕНА ЦЕНА СО СКИДКОЙ КОЛ-ВО ИТОГ", "Товар один 120.00 100.00 1шт. 100.00",
                          "Товар два 800.00 700.00 2шт. 1400.00", "Карта № ****-0000", "Скидка по карте Тест 100.00",
                          "ИТОГ БЕЗ СКИДОК 1500.00", "СКИДКА 100.00", "ИТОГ 1400.00", "БЕЗНАЛИЧНЫМИ 1400.00", "08.10.32 18:37"]
        let parsed = ReceiptParser.parseText(discounted, now: now, calendar: calendar)
        require(parsed.totalKopecks == 140_000, "the total after the discounts, not «итог без скидок»")
        require(parsed.date == calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 18, minute: 37)), "the date of the receipt")
        require(ReceiptParser.parseText(discounted.filter { !$0.hasPrefix("БЕЗНАЛИЧ") }, now: now, calendar: calendar).totalKopecks == 140_000,
                "without the card line the last «ИТОГ» is the total")
        require(ReceiptParser.parseText(["ИТОГ БЕЗ СКИДОК 1500.00", "СКИДКА 100.00", "ИТОГ 1400.00", "БЕЗНАЛИЧНЫМИ 900.00", "БОНУСАМИ 500.00"],
                                        now: now, calendar: calendar).totalKopecks == 90_000, "what was paid by card is what the bank charged")
        require(ReceiptParser.parseText(["ИТОГ БЕЗ СКИДОК 1500.00", "НАЛИЧНЫМИ 1500.00", "ИТОГ 1400.00"], now: now, calendar: calendar).totalKopecks == 140_000,
                "cash is not a total")
        require(ReceiptParser.parseText(["Магазин Тест", "08. 10. 32  18 : 37", "ИТОГО 10.00"], now: now, calendar: calendar).date
                == calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 18, minute: 37)), "spaces around the separators of a date and a time")
    }

    /// The Save account from the bank, and the rows that must not move the card (stage 46.11).
    static func testSaveAccountAndOtherSides() {
        let start = BankDateParser.parse("2032-06-01T00:00:00Z")!
        func row(_ amount: Int64, _ kind: String, _ method: String?, _ description: String, _ date: String = "2032-06-05T10:00:00Z") -> FinancialOperationInput {
            var input = op(amount, kind: kind, description: description, date: date)
            input.paymentMethod = method
            return input
        }
        let rows = [
            row(-50_000, "expense", "Карта Пэй", "Магазин А"),
            row(1_918, "interest_income", "Счёт в Сейвах", "Выплата процентов"),
            row(-7_000_000, "internal_transfer", "Карта Пэй", "Карта Пэй → Счёт в Сейвах", "2032-06-06T10:00:00Z"),
            row(7_000_000, "internal_transfer", "Счёт в Сейвах", "Карта Пэй → Счёт в Сейвах", "2032-06-06T10:00:00Z"),
            row(-1_000_000, "internal_transfer", "Счёт в Сейвах", "Счёт в Сейвах → Карта Пэй", "2032-06-07T10:00:00Z"),
            row(1_000_000, "internal_transfer", "Карта Пэй", "Счёт в Сейвах → Карта Пэй", "2032-06-07T10:00:00Z"),
            row(-300_000, "expense", "Сплит", "Магазин Б"),
            row(-10_000, "expense", "Баллы Плюса", "Магазин В"),
            row(-20_000, "installment_payment", "Карта *2733", "Платёж Сплита"),
        ]
        require(FinancialEngine.isNotCardSide(rows[1]) && FinancialEngine.isNotCardSide(rows[6]) && FinancialEngine.isNotCardSide(rows[7])
                && !FinancialEngine.isNotCardSide(rows[0]) && !FinancialEngine.isNotCardSide(rows[8]), "Save, Split and the points are not the card")
        // The card: its purchases, its part of the transfers and the instalment; not the interest, not Split, not the points.
        let cardBalance = FinancialEngine.accountBalance(startKopecks: 100_000, since: start, tracksBankCard: true, operations: rows)
        require(cardBalance == 100_000 - 50_000 - 7_000_000 + 1_000_000 - 20_000, "the card keeps only its own rows")
        // Save: the interest, both transfers, and nothing of the card.
        let saveBalance = FinancialEngine.saveAccountBalance(startKopecks: 500_000, since: start, operations: rows)
        require(saveBalance == 500_000 + 1_918 + 7_000_000 - 1_000_000, "Save takes the interest and the transfers both ways")
        require(FinancialEngine.saveAccountBalance(startKopecks: 500_000, since: start.addingTimeInterval(86_400 * 30), operations: rows) == 500_000,
                "rows before the start of the account are not counted")

        // The same through the accounts and the history.
        let card = Account(name: "Яндекс банк", icon: "creditcard", color: "blue", startBalanceKopecks: 100_000, startDate: start, tracksBankCard: true)
        let save = Account(name: "Сейв", icon: "banknote", color: "green", startBalanceKopecks: 500_000, startDate: start, tracksSave: true)
        require(save.followsBank && card.followsBank && !Account(name: "Наличные", icon: "banknote", color: "green", startBalanceKopecks: 0, startDate: start).followsBank,
                "the bank accounts are not kept by hand")
        require(card.balance(bankOperations: rows, manual: []) == cardBalance && save.balance(bankOperations: rows, manual: []) == saveBalance, "the account balances")
        let manual = ManualOperation(kind: .income, amountKopecks: 99_999, date: start.addingTimeInterval(86_400), accountID: save.id, group: nil, subcategory: "Прочие доходы")
        require(save.balance(bankOperations: rows, manual: [manual]) == saveBalance, "an entry made by hand never moves the Save kept from the bank")

        var history = SavedHistory()
        history.accounts = [card, save]
        history.operations = [
            BankOperation(identity: "s-1", occurredAt: "2032-06-05T10:00:00Z", timePrecision: "exact", description: "Выплата процентов", amountKopecks: 1_918,
                          currency: "RUB", status: "Выполнено", category: "Проценты", mcc: nil, purpose: nil, paymentMethod: "Счёт в Сейвах", providers: [],
                          kind: "interest_income"),
            BankOperation(identity: "c-1", occurredAt: "2032-06-05T11:00:00Z", timePrecision: "exact", description: "Магазин А", amountKopecks: -50_000,
                          currency: "RUB", status: "Выполнено", category: "Супермаркеты", mcc: nil, purpose: nil, paymentMethod: "Карта Пэй", providers: [],
                          kind: "expense"),
        ]
        let inputs = history.financialInputs
        require(inputs[0].accountID == save.id && inputs[1].accountID == nil, "the Save row belongs to the Save account in the reports")
        let june = DateInterval(start: start, end: start.addingTimeInterval(86_400 * 30))
        func income(_ scope: ReportAccountScope) -> Int64 {
            ReportEngine.slices(inputs, in: june, mode: .income, grouping: .categories, taxonomy: .builtin, filter: ReportFilter(scope: scope)).reduce(0) { $0 + $1.amountKopecks }
        }
        require(income(.accounts([save])) == 1_918 && income(.accounts([card])) == 0 && income(.all) == 1_918, "the interest is the income of Save, not of the card")
        let movements = history.accountMovements(save)
        require(movements.count == 1 && movements[0].delta == 1_918, "the movements of the Save account")
        require(history.accountMovements(card).count == 1, "the card has its purchase only")
        var held = history
        held.manualOperations = [manual]
        require(held.lastManualAccountID == nil, "no manual account to suggest: Save follows the bank")
    }

    /// The goods of a receipt and the shop found anywhere on it (stage 46.12).
    static func testReceiptItems() {
        let table = ["МАГАЗИН ТЕСТ", "ЦЕНА ЦЕНА СО СКИДКОЙ КОЛ-ВО ИТОГ", "СКРЕПЫШ Сахарная вата шарик 16г(Россия):10", "36.99 29.99 1ШТ. 29.99",
                     "4895 BLANCHE BIERE Пиво нап тёмн 174.99", "174.99 174.99 1ШТ. 174.99", "Карта № ****-0000", "Скидка по карте Магнит 107.00",
                     "ИТОГ БЕЗ СКИДОК 1763.87", "ИТОГ 1656.87"]
        require(ReceiptParser.items(in: table) == ["СКРЕПЫШ Сахарная вата шарик 16г(Россия)", "BLANCHE BIERE Пиво нап тёмн"],
                "the goods of a table with a head: no prices, quantities, codes or the numbers after the name")
        require(ReceiptParser.items(in: ["МАГАЗИН ТЕСТ", "Молоко 2 x 65.00 130.00", "Хлеб 1 x 45.50 45.50", "ИТОГО 175.50", "Наличные 200.00"]) == ["Молоко", "Хлеб"],
                "the goods of a list without a head: from the first line with a price to the totals")
        require(ReceiptParser.items(in: ["случайный текст"]).isEmpty && ReceiptParser.items(in: []).isEmpty, "no goods in a text without prices")
        require(ReceiptParser.items(in: ["Товар один 10.00", "Товар один 10.00", "Товар два 20.00", "ИТОГО 40.00"]) == ["Товар один", "Товар два"],
                "a line read twice in a row is one good")
        require(ReceiptParser.merchant(in: table) == "Магнит", "the shop is found by its name on a line below the head")
        require(ReceiptParser.merchant(in: ["ЦЕНА СО СКИДКОЙ КОЛ-ВО", "Товар 1.00", "ИТОГ 1.00"]) == nil, "the head of a table is not the name of a shop")
        require(ReceiptParser.merchant(in: ["КАССОВЫЙ ЧЕК", "МАГАЗИН ПРОДУКТЫ", "ИТОГО 99.00"]) == "Магазин Продукты", "an unknown shop keeps its printed name")
        let history = SavedHistory()
        require(history.suggestedExpenseCategory(forMerchant: "", text: "Молоко Хлеб")?.group == "Еда", "the goods tell the category when the shop does not")
        require(history.suggestedExpenseCategory(forMerchant: "Магнит")?.group == "Еда", "the category of a known chain")
    }

    /// The goods stop where the goods end, names are clean, a date read with letters for digits is still a date (46.14).
    static func testReceiptNoise() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 20, minute: 0))!
        let noisy = ["ЦЕНА СО СКИДКОЙ КОЛ-ВО ИТОГ", "ТОВАР ОДИН <РОССИЯ>", "36.99 1ШТ.", "ТОВАР «ДВА» 16г", "10.00 1ШТ.", "Карта нº ****-7443",
                     "по техническим причинам начисление бонусов", "приносим извинения за доставленные неудобства"]
        require(ReceiptParser.items(in: noisy) == ["ТОВАР ОДИН РОССИЯ", "ТОВАР ДВА 16г"], "the goods end at the card line; the quotes and brackets are gone")
        require(ReceiptParser.items(in: ["ЦЕНА СО СКИДКОЙ КОЛ-ВО ИТОГ", String(repeating: "Очень длинное название ", count: 6), "10.00 1ШТ."]).first?.count ?? 0 <= 48,
                "a name is short")
        require(ReceiptParser.digitsFixed("D8.10.32 l8:37") == "08.10.32 18:37", "letters for digits inside a date and a time")
        require(ReceiptParser.digitsFixed("BLANCHE BIERE 174.99 ЦЕНА") == "BLANCHE BIERE 174.99 ЦЕНА", "words and prices are left as they are")
        let parsed = ReceiptParser.parseText(["Магазин Тест", "D8.10.32 l8:37", "ИТОГ 10.00"], now: now, calendar: calendar)
        require(parsed.date == calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 18, minute: 37)), "the date read with letters")
        require(ReceiptParser.parseText(["Магазин Тест", "ИТОГ 10.00"], now: now, calendar: calendar).date == nil, "no date, none invented")
    }

    /// Goods with prices, goods lines of the editor, the time of a receipt, the data kept with an operation (46.15).
    static func testReceiptGoods() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 20, minute: 0))!
        let table = ["ЦЕНА ЦЕНА СО СКИДКОЙ КОЛ-ВО ИТОГ", "ТОВАР ОДИН шарик:10", "36.99 29.99 1ШТ. 29.99", "ТОВАР ДВА большой", "279.99 279.99 2ШТ. 559.98",
                     "Хлеб белый 45.50", "Карта № ****-0000", "ИТОГ 635.47"]
        let goods = ReceiptParser.itemEntries(in: table)
        require(goods == [ReceiptGood(name: "ТОВАР ОДИН шарик", kopecks: 2_999), ReceiptGood(name: "ТОВАР ДВА большой", kopecks: 55_998),
                          ReceiptGood(name: "Хлеб белый", kopecks: 4_550)],
                "the final price of a line is the last sum: on the line of the good or on the line of figures after it")
        require(ReceiptParser.itemEntries(in: ["Молоко 2 x 65.00 130.00", "ИТОГО 130.00"]) == [ReceiptGood(name: "Молоко", kopecks: 13_000)], "the sum of the line, not the unit price")
        require(ReceiptParser.itemEntries(in: ["ЦЕНА СО СКИДКОЙ КОЛ-ВО ИТОГ", "ТОВАР без цены", "ИТОГ 1.00"]) == [ReceiptGood(name: "ТОВАР без цены", kopecks: nil)],
                "a good whose price was not read has none")
        // misread capitals inside words
        require(ReceiptParser.tidied("СаХЕРИЗЯ КОлбасКА хВа RITTER SPORT 16г(Россия) Сахарная") == "Сахеризя Колбаска Хва RITTER SPORT 16г(Россия) Сахарная",
                "capitals among small letters become one capital; words in capitals and numbers are kept")
        // the editor lines
        require(ReceiptGood(name: "Молоко", kopecks: 6_500).line == "Молоко — 65,00 ₽" && ReceiptGood(name: "Хлеб", kopecks: 5).line == "Хлеб — 0,05 ₽"
                && ReceiptGood(name: "Соль").line == "Соль", "the line of a good")
        require(ReceiptGood(line: "Молоко — 65,00 ₽") == ReceiptGood(name: "Молоко", kopecks: 6_500), "the line is read back")
        require(ReceiptGood(line: "Молоко - особое — 1 299.5") == ReceiptGood(name: "Молоко - особое", kopecks: 129_950), "the last « — » separates the price")
        require(ReceiptGood(line: "Просто название") == ReceiptGood(name: "Просто название"), "a line without a price is a name")
        require(ReceiptGood(line: "Товар — много") == ReceiptGood(name: "Товар — много"), "a tail that is not a price stays in the name")
        require(ReceiptGood.kopecks("65") == 6_500 && ReceiptGood.kopecks("65,5") == 6_550 && ReceiptGood.kopecks("65,555") == nil && ReceiptGood.kopecks("") == nil
                && ReceiptGood.kopecks("-5") == nil && ReceiptGood.kopecks("1 2 3") == 12_300, "prices of the editor")
        // the time of a receipt
        let day = ["Магазин Тест", "08.10.32", "ИТОГ 10.00"]
        let noTime = ReceiptParser.parseText(day, now: now, calendar: calendar)
        require(noTime.date != nil && noTime.dateHasTime == false, "a date without a time says so")
        require(ReceiptParser.parseText(["Магазин Тест", "08.10.32 09:05", "ИТОГ 10.00"], now: now, calendar: calendar).dateHasTime, "a date with a time")
        require(ReceiptParser.parseText(["Магазин Тест", "ИТОГ 10.00"], now: now, calendar: calendar).dateHasTime, "no date at all is not a missing time")
        let qr = ParsedReceipt(totalKopecks: 100, date: calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 9, minute: 5)), merchant: nil)
        require(ReceiptParser.merge(qr: qr, text: noTime).dateHasTime, "the time of the QR code is exact")
        // what is kept with an operation
        var history = SavedHistory()
        history.setReceiptGoods([ReceiptGood(name: "Хлеб", kopecks: 4_500)], forIdentity: "manual:1")
        history.setReceiptScan(ReceiptScan(scannedAt: now, readLines: ["ИТОГ 45.00"], totalKopecks: 4_500, date: nil, merchant: nil,
                                           goods: [], dateHasTime: true), forIdentity: "manual:1")
        history.addReceipt("receipt-00000000-0000-0000-0000-000000000001.jpg", toIdentity: "manual:1")
        require(history.receiptGoods(forIdentity: "manual:1").count == 1 && history.receiptScans?.count == 1, "goods and the reading are kept")
        history.setReceiptGoods([], forIdentity: "manual:1")
        require(history.receiptGoods == nil, "no goods, no field")
        history.setReceiptGoods([ReceiptGood(name: "Хлеб")], forIdentity: "manual:1")
        _ = history.removeReceipts(forIdentity: "manual:1")
        require(history.receiptGoods == nil && history.receiptScans == nil && history.receipts == nil, "everything of a receipt goes with it")
        let decoded = try? JSONDecoder().decode(SavedHistory.self, from: try! JSONEncoder().encode(SavedHistory()))
        require(decoded?.receiptGoods == nil && decoded?.receiptScans == nil && decoded?.collectedReceiptIdentities == nil, "old data opens")
    }

    /// The report of a receipt for the check of the reading (46.15).
    static func testReceiptCheckReport() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let saved = calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 18, minute: 37))!
        let goods = [ReceiptGood(name: "Хлеб", kopecks: 4_500)]
        var read = ParsedReceipt(totalKopecks: 4_500, date: saved, merchant: "Тест", goods: goods, readLines: ["ИТОГ 45.00"])
        var verdict = ReceiptCheckReport.verdict(read: read, amountKopecks: -4_500, date: saved, goods: goods, calendar: calendar)
        require(verdict.totalMatches && verdict.dateMatches && verdict.goods.hasPrefix("не менялись"), "everything read right")
        read.totalKopecks = 5_000
        read.date = saved.addingTimeInterval(600)
        read.goods = [ReceiptGood(name: "Хлеб", kopecks: 4_400)]
        verdict = ReceiptCheckReport.verdict(read: read, amountKopecks: 4_500, date: saved, goods: goods, calendar: calendar)
        require(!verdict.totalMatches && verdict.total.contains("НЕ совпала") && !verdict.dateMatches && verdict.goods.hasPrefix("исправлены"), "a wrong reading is told")
        read.dateHasTime = false
        read.date = saved.addingTimeInterval(3600)
        require(ReceiptCheckReport.verdict(read: read, amountKopecks: 4_500, date: saved, goods: goods, calendar: calendar).date.hasPrefix("день совпал"), "a date without a time is judged by the day")
        let nothing = ParsedReceipt()
        verdict = ReceiptCheckReport.verdict(read: nothing, amountKopecks: 4_500, date: saved, goods: [], calendar: calendar)
        require(verdict.total == "не прочитана" && verdict.date == "не прочитана" && verdict.goods == "товаров нет", "nothing read")
        require(ReceiptCheckReport.verdict(read: nothing, amountKopecks: 4_500, date: saved, goods: goods, calendar: calendar).goods.hasPrefix("не найдены телефоном"),
                "goods typed by the owner")
        let text = ReceiptCheckReport.text(number: 3, read: ParsedReceipt(totalKopecks: 4_500, date: saved, merchant: "Тест", goods: goods, readLines: ["ИТОГ 45.00", "Хлеб 45.00"]),
                                           source: "прочитано при добавлении", title: "Магазин Тест", category: "Еда/Супермаркеты", amountKopecks: -4_500,
                                           date: saved, goods: goods, calendar: calendar)
        require(text.contains("Чек № 3") && text.contains("Сумма: 45,00 ₽") && text.contains("08.10.2032 18:37") && text.contains("  Хлеб — 45,00 ₽")
                && text.contains("ИТОГ 45.00") && text.contains("Еда/Супермаркеты"), "the text holds the saved values, the extracted ones and the raw text")
    }

    /// Prices from the figures around a good, and the check of the sum (46.16).
    static func testReceiptPriceBands() {
        let layout = ["ЦЕНА ЦЕНА СО СКИДКОЙ КОЛ-ВО ИТОГ",
                      "ТОВАР А шарик <РОССИя>: 10 29.99", "36.99 29.99",
                      "ТОВАР Б пиво тЕн 174.99", "174.99 174.99ł",
                      "ТОВАР В колбаса П/СУХ",
                      "ТОВАР Г креветки в/м хВО: 490 179.99 79.99", "279.99 279.99 559.98",
                      "ТОВАР Д шоколад какаС-РЕм", "59.99 211 . 119.98",
                      "ТОВАР Е арахис: 19,99", "73.99 73.99 1ШT -",
                      "Карта Nº ****-****-0000"]
        let goods = ReceiptParser.itemEntries(in: layout)
        require(goods.count == 6 && goods.map(\.kopecks) == [2_999, 17_499, nil, 55_998, 11_998, 7_399],
                "the total of a line from the figures around it: sums on the name line, a row stuck to the next name, a multiple, a misread sum")
        require(goods[0].name == "ТОВАР А шарик Россия", "the name without the number after it and the brackets")
        require(ReceiptParser.lineTotal([]) == nil && ReceiptParser.lineTotal([4_550]) == 4_550 && ReceiptParser.lineTotal([6_500, 13_000]) == 13_000
                && ReceiptParser.lineTotal([3_699, 2_999, 2_999]) == 2_999 && ReceiptParser.lineTotal([27_999, 27_999, 55_998]) == 55_998,
                "single sum, a unit and its multiple, a repeated price, a repeated price and its multiple")
        require(ReceiptParser.lineTotal([100, 250, 777]) == 777, "nothing to go by: the last sum")
        // the check of the sum
        let right = [ReceiptGood(name: "А", kopecks: 6_000), ReceiptGood(name: "Б", kopecks: 4_000)]
        require(ReceiptParser.goodsSumNote(right, expectedKopecks: 10_000)?.adds == true, "the prices add up")
        let off = ReceiptParser.goodsSumNote(right, expectedKopecks: 12_000)
        require(off?.adds == false && off?.text.contains("проверьте цены") == true, "the prices do not add up")
        require(ReceiptParser.goodsSumNote(right + [ReceiptGood(name: "В")], expectedKopecks: 10_000)?.adds == false, "a good without a price is not a match")
        require(ReceiptParser.goodsSumNote([ReceiptGood(name: "А")], expectedKopecks: 10_000) == nil && ReceiptParser.goodsSumNote(right, expectedKopecks: nil) == nil,
                "nothing to compare")
    }

    /// The four errors of the reading found by stage 52, and photos without an operation (46.17).
    static func testReceiptLayoutsRepaired() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 20, minute: 0))!
        func read(_ lines: [String]) -> ParsedReceipt { ReceiptParser.parseText(lines, now: now, calendar: calendar) }
        // a name written in two lines
        let wrapped = read(["ЦЕНА КОЛ-ВО СУММА", "Йогурт натуральный", "с ягодами 2 x 89.00 178.00", "ИТОГО 178.00"])
        require(wrapped.goods == [ReceiptGood(name: "Йогурт натуральный с ягодами", kopecks: 17_800)], "a name in two lines is one good")
        require(read(["ЦЕНА КОЛ-ВО СУММА", "Йогурт натуральный", "Хлеб белый 1 x 45.50 45.50", "ИТОГО 45.50"]).goods.map(\.name) == ["Йогурт натуральный", "Хлеб белый"],
                "the next line with a capital letter is another good")
        // the unit of the quantity is not part of the name
        let fuel = read(["Колонка: 3", "ЦЕНА КОЛ-ВО СУММА", "Бензин тестовый 95 20.00 л 55.50 1110.00", "ИТОГО 1110.00"])
        require(fuel.goods == [ReceiptGood(name: "Бензин тестовый 95", kopecks: 111_000)], "the litres are not in the name")
        require(read(["Молоко 0.9 л 65.00", "ИТОГО 65.00"]).goods.map(\.name) == ["Молоко 0.9 л"], "a unit that belongs to the name stays")
        // two payments by cards
        let cards = read(["Карандаши учебные 2 x 150.00 300.00", "Блокнот учебный 1 x 300.00 300.00", "ИТОГО 600.00",
                          "БЕЗНАЛИЧНЫМИ КАРТА А 350.00", "БЕЗНАЛИЧНЫМИ КАРТА Б 250.00"])
        require(cards.totalKopecks == 60_000, "two payments by cards: the total is the explicit total")
        require(cards.goods == [ReceiptGood(name: "Карандаши учебные", kopecks: 30_000), ReceiptGood(name: "Блокнот учебный", kopecks: 30_000)], "goods of a receipt with two cards")
        // the same name with other prices
        let notebooks = read(["Блокнот учебный 1 x 60.00 60.00", "Блокнот учебный 1 x 100.00 100.00", "ИТОГО 160.00"])
        require(notebooks.goods == [ReceiptGood(name: "Блокнот учебный", kopecks: 6_000), ReceiptGood(name: "Блокнот учебный", kopecks: 10_000)],
                "two notebooks with different prices are two goods")
        require(read(["Товар один 10.00", "Товар один 10.00", "ИТОГО 10.00"]).goods.count == 1, "a line read twice is one good")
        // photos without an operation
        let all = ["receipt-3.jpg", "receipt-1.jpg", "receipt-2.jpg"]
        require(ReceiptLogic.orphanFiles(all: all, referenced: ["manual:1": ["receipt-1.jpg"], "manual:2": ["receipt-2.jpg"]]) == ["receipt-3.jpg"], "the photo that no operation has")
        require(ReceiptLogic.orphanFiles(all: all, referenced: nil) == ["receipt-1.jpg", "receipt-2.jpg", "receipt-3.jpg"], "no operations, all photos are free")
        require(ReceiptLogic.orphanFiles(all: [], referenced: ["manual:1": ["receipt-1.jpg"]]).isEmpty, "no files, nothing to delete")
    }

    /// Repairs of prices, pairing of the two passes, foreign photo names, Split and points in the reports (46.18).
    static func testReceiptRepairs() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 20, minute: 0))!
        // a good without a price: its figures stuck to the next name; the gap to the total is among the sums near that name
        let layout = ["ЦЕНА ЦЕНА СО СКИДКОЙ КОЛ-ВО ИТОГ",
                      "ТОВАР А шарик <РОССИя>: 10 29.99", "36.99 29.99",
                      "ТОВАР Б пиво тЕн 174.99", "174.99 174.99ł",
                      "ТОВАР В колбаса П/СУХ",
                      "ТОВАР Г креветки в/м хВО: 490 179.99 79.99", "279.99 279.99 559.98",
                      "ТОВАР Д шоколад какаС-РЕм", "59.99 211 . 119.98",
                      "ТОВАР Е арахис: 19,99", "73.99 73.99 1ШT -",
                      "Карта Nº ****-****-0000", "ИТОГО 1038.92"]
        let read = ReceiptParser.parseText(layout, now: now, calendar: calendar)
        require(read.totalKopecks == 103_892, "the total of the receipt")
        require(read.goods.map(\.kopecks) == [2_999, 17_499, 7_999, 55_998, 11_998, 7_399], "the missing price is found among the sums of the next name")
        // one good, a misread sum repeated twice, the right price among the sums and the total of the receipt
        let single = ReceiptParser.parseText(["Сахар учебный 19.99", "89.99 73.99 1ШТ. 19.99", "ИТОГО 73.99"], now: now, calendar: calendar)
        require(single.goods == [ReceiptGood(name: "Сахар учебный", kopecks: 7_399)], "a repeated misread sum is not taken for the price")
        // nothing is guessed when the receipt has a discount on the whole of it
        let discounted = ReceiptParser.parseText(["Товар один 1 x 500.00 500.00", "Товар два 1 x 600.00 600.00", "ИТОГ БЕЗ СКИДОК 1100.00", "СКИДКА 100.00", "ИТОГ 1000.00"],
                                                 now: now, calendar: calendar)
        require(discounted.goods.map(\.kopecks) == [50_000, 60_000], "prices above the total are left as they are")
        require(ReceiptParser.reconcilePrices([ReceiptGood(name: "А", kopecks: 100), ReceiptGood(name: "Б")], bands: [[100], []], expected: 500)
                .map(\.kopecks) == [100, nil], "a gap that is not among the sums repairs nothing")
        // pairing of the two passes
        let named = [ReceiptGood(name: "Молоко учебное"), ReceiptGood(name: "Хлеб учебный")]
        let priced = [ReceiptGood(name: "Молоко учебнсе", kopecks: 11_800), ReceiptGood(name: "Хлеб учеьный", kopecks: 4_650)]
        require(ReceiptParser.pairGoods(named: named, priced: priced)?.map(\.kopecks) == [11_800, 4_650], "the same lines are paired")
        require(ReceiptParser.pairGoods(named: [ReceiptGood(name: "Хлеб учебный"), ReceiptGood(name: "Сыр твёрдый")],
                                        priced: [ReceiptGood(name: "Молоко учебное", kopecks: 11_800), ReceiptGood(name: "Хлеб учебный", kopecks: 4_650)]) == nil,
                "a shifted list is not paired")
        require(ReceiptParser.pairGoods(named: [], priced: []) == nil && ReceiptParser.pairGoods(named: named, priced: [priced[0]]) == nil, "different counts")
        require(ReceiptParser.similarity("Хлеб", "Хлеб") == 1 && ReceiptParser.similarity("Хлеб", "Сыр") < 0.3, "similarity of texts")
        // 46.43 (Gemini): the row of the date read again gives only what the first reading lacks.
        let day = calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 12))!
        let timed = calendar.date(from: DateComponents(year: 2032, month: 10, day: 8, hour: 18, minute: 37))!
        let otherDay = calendar.date(from: DateComponents(year: 2032, month: 10, day: 6, hour: 18, minute: 37))!
        let withTime = ReceiptParser.refinedDate(first: (day, false), reread: (timed, true), calendar: calendar)
        require(withTime?.date == timed && withTime?.hasTime == true, "the time of the same day is taken from the re-read row")
        require(ReceiptParser.refinedDate(first: (day, false), reread: (otherDay, true), calendar: calendar) == nil, "another day changes nothing")
        require(ReceiptParser.refinedDate(first: (timed, true), reread: (otherDay, true), calendar: calendar) == nil, "a read time is kept")
        require(ReceiptParser.refinedDate(first: (day, false), reread: (day, false), calendar: calendar) == nil, "a re-read without time adds nothing")
        require(ReceiptParser.refinedDate(first: nil, reread: (timed, true), calendar: calendar)?.date == timed, "a date when none was read")
        require(ReceiptParser.refinedDate(first: (day, false), reread: nil, calendar: calendar) == nil, "nothing re-read")
        // 46.41, GPT stage 55: a price its own columns confirm is not repaired up to the total (service charge, tips, missing goods).
        let header = "ЦЕНА КОЛ-ВО СУММА"
        for tail in [["ИТОГО 120.00", "СЕРВИСНЫЙ СБОР 20.00"], ["ИТОГО 120.00", "ЧАЕВЫЕ 20.00"], ["ИТОГО 150.00"]] {
            let name = tail.count == 1 ? "Молоко учебное 150.00 100.00 100.00" : "Пирог учебный 120.00 100.00 100.00"
            let read = ReceiptParser.parseText([header, name] + tail, now: now, calendar: calendar)
            require(read.goods.map(\.kopecks) == [10_000], "a confirmed price stays: \(tail) → \(read.goods)")
        }
        // A good without a price takes the gap only from the row of the very next good, not from a far one.
        let far = ReceiptParser.parseText([header, "Позиция учебная без цены", "", "Товар учебный посредине 70.00", "Товар учебный последний 50.00", "ИТОГО 170.00"],
                                          now: now, calendar: calendar)
        require(far.goods.map(\.kopecks) == [nil, 7_000, 5_000], "no price from a far good: \(far.goods)")
        // Two equal lines: two goods when the total adds up with both, one read twice when it adds up with one.
        let twice = ReceiptParser.parseText([header, "Товар учебный 100.00", "Товар учебный 100.00", "ИТОГО 200.00"], now: now, calendar: calendar)
        require(twice.goods.map(\.kopecks) == [10_000, 10_000], "two equal goods: \(twice.goods)")
        let once = ReceiptParser.parseText([header, "Товар учебный 100.00", "Товар учебный 100.00", "ИТОГО 100.00"], now: now, calendar: calendar)
        require(once.goods.map(\.kopecks) == [10_000], "one good read twice: \(once.goods)")
        require(ReceiptParser.itemEntries(in: [header, "Товар учебный 100.00", "Товар учебный 100.00"]).count == 1, "without a total a repeated line is one good")
        // GPT stage 64 (R64-3): a total that adds up with neither one nor two equal lines keeps both (the owner checks the sum).
        let neither = ReceiptParser.parseText([header, "Товар учебный 100.00", "Товар учебный 100.00", "ИТОГО 250.00"], now: now, calendar: calendar)
        require(neither.goods.map(\.kopecks) == [10_000, 10_000], "no proof of a repeat: both lines stay: \(neither.goods)")
        // GPT stage 64 (R64-4): an exact name keeps its own line, the general one gets the rest.
        let general = [ReceiptGood(name: "Йогурт учебный"), ReceiptGood(name: "Йогурт учебный вишня")]
        let lines = [ReceiptGood(name: "Йогурт учебный вишня", kopecks: 12_000), ReceiptGood(name: "Йогурт учебный клубника", kopecks: 8_000)]
        require(ReceiptParser.pairGoods(named: general, priced: lines)?.map(\.kopecks) == [8_000, 12_000], "the exact name keeps its line")
        require(ReceiptParser.pairGoods(named: Array(general.reversed()), priced: lines)?.map(\.kopecks) == [12_000, 8_000], "in either order")
        // Similar names listed in another order by the second pass: each name keeps its own price.
        let first = [ReceiptGood(name: "Йогурт учебный клубника"), ReceiptGood(name: "Йогурт учебный вишня")]
        let second = [ReceiptGood(name: "Йогурт учебный вишня", kopecks: 12_000), ReceiptGood(name: "Йогурт учебный клубника", kopecks: 8_000)]
        require(ReceiptParser.pairGoods(named: first, priced: second)?.map(\.kopecks) == [8_000, 12_000], "pairing by the names, not by the order")
        require(ReceiptParser.pairGoods(named: [ReceiptGood(name: "Товар учебный"), ReceiptGood(name: "Товар учебный")],
                                        priced: [ReceiptGood(name: "Товар учебный", kopecks: 100), ReceiptGood(name: "Товар учебный", kopecks: 200)])?.map(\.kopecks) == [100, 200],
                "two goods of the same name pair in their order")
        // photo names from outside
        var history = SavedHistory()
        history.receipts = ["manual:1": ["receipt-00000000-0000-0000-0000-000000000001.jpg", "../outside.txt", "sub/a.jpg", "/etc/hosts"],
                            "manual:2": ["../x.jpg"]]
        let copy = try? HistoryBackup.decode(HistoryBackup.encode(history))
        require(copy?.receipts == ["manual:1": ["receipt-00000000-0000-0000-0000-000000000001.jpg"]], "a copy keeps only the photo names the app makes")
        // Split and points belong to no money account
        var split = SavedHistory()
        split.operations = [BankOperation(identity: "s1", occurredAt: "2032-06-05T10:00:00Z", timePrecision: "exact", description: "Магазин", amountKopecks: -5_000,
                                          currency: "RUB", status: "Выполнено", category: "Супермаркеты", mcc: nil, purpose: nil, paymentMethod: "Баллы Плюса",
                                          providers: [], kind: "expense")]
        require(split.financialInputs[0].accountID == ManualOperation.noAccountID, "a purchase with points has no money account")
    }

    static func testRegularPayments() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        func pattern(_ days: Int, _ last: Date, _ amount: Int64 = 210_000) -> FinancialEngine.RecurringPattern {
            FinancialEngine.RecurringPattern(title: "Тестовая подписка", isIncome: false,
                                             intervalDays: days, typicalAmountKopecks: amount, lastDate: last)
        }
        let weekly = pattern(7, date(2032, 1, 1))
        require(RegularPayments.nextDate(of: weekly, now: date(2032, 1, 8, 18), calendar: calendar) == date(2032, 1, 8),
                "weekly next date includes today even after payment time")
        require(RegularPayments.nextDate(of: weekly, now: date(2032, 1, 9), calendar: calendar) == date(2032, 1, 15),
                "weekly next date skips past occurrences")
        require(RegularPayments.nextDate(of: pattern(14, date(2032, 1, 1)), now: date(2032, 1, 16), calendar: calendar) == date(2032, 1, 29),
                "fortnightly date advances in 14-day steps")
        require(RegularPayments.nextDate(of: pattern(30, date(2031, 1, 31)), now: date(2031, 2, 1), calendar: calendar) == date(2031, 2, 28),
                "monthly payment on the 31st clamps to the end of February")
        require(RegularPayments.nextDate(of: pattern(30, date(2032, 1, 31)), now: date(2032, 2, 1), calendar: calendar) == date(2032, 2, 29),
                "monthly payment respects leap February")
        require(RegularPayments.nextDate(of: pattern(30, date(2031, 1, 31)), now: date(2031, 3, 1), calendar: calendar) == date(2031, 3, 31),
                "a payment of the 31st is on the 31st again in March, as in the forecast")
        require(RegularPayments.nextDate(of: pattern(365, date(2031, 3, 1)), now: date(2031, 3, 2), calendar: calendar) == date(2032, 3, 1),
                "annual date advances a calendar year across leap February")
        require(RegularPayments.nextDate(of: pattern(365, date(2032, 2, 29)), now: date(2034, 1, 1), calendar: calendar) == date(2034, 2, 28),
                "annual date advances until it is not before today")
        require(RegularPayments.nextDate(of: weekly, now: date(2032, 1, 1), calendar: calendar) == date(2032, 1, 8),
                "the last recorded payment is not repeated as the next payment")

        require(RegularPayments.monthlyKopecks(of: pattern(7, weekly.lastDate, 100)) == 429,
                "weekly monthly estimate rounds to kopecks")
        require(RegularPayments.monthlyKopecks(of: pattern(14, weekly.lastDate, 100)) == 214,
                "fortnightly monthly estimate uses 30 over 14")
        require(RegularPayments.monthlyKopecks(of: pattern(30, weekly.lastDate)) == 210_000,
                "monthly amount stays exact")
        require(RegularPayments.monthlyKopecks(of: pattern(365, weekly.lastDate, 102)) == 9,
                "annual monthly estimate divides by 12 and rounds half up")
        require(RegularPayments.monthlyKopecks(of: pattern(7, weekly.lastDate, 0)) == 0,
                "zero monthly estimate remains zero")
        require(RegularPayments.monthlyKopecks(of: pattern(7, weekly.lastDate, 700_000_000_007)) == 3_000_000_000_030,
                "monthly estimate retains whole-kopeck precision for large amounts")
        for (days, title) in [(7, "Каждую неделю"), (14, "Раз в две недели"), (30, "Каждый месяц"), (365, "Раз в год"), (5, "Раз в 5 дн.")] {
            require(RegularPayments.periodTitle(intervalDays: days) == title, "regular payment title for \(days) days")
        }

        var daylightCalendar = calendar
        daylightCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeDST = daylightCalendar.date(from: DateComponents(year: 2032, month: 3, day: 7, hour: 10))!
        let expected = daylightCalendar.date(from: DateComponents(year: 2032, month: 3, day: 14, hour: 10))!
        require(RegularPayments.nextDate(of: pattern(7, beforeDST), now: beforeDST, calendar: daylightCalendar) == expected,
                "weekly payment keeps local time across daylight saving")
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

    /// A large synthetic history (12 000 rows over 13 months): the forecast must come out the same however it is computed, and
    /// its time is printed (the speed is a goal of the forecast block, not a hard limit of this test). In 46.22 the numbers rose a
    /// little (the pace from purchases, not net of refunds); since 46.23 they are those of 46.20 again: every refund of this history
    /// returns a purchase of the same shop and month, and such a pair leaves the pace altogether.
    static func testForecastSpeed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2032, month: 6, day: 20, hour: 12))!
        let days: [String] = (0..<400).map { back in
            calendar.date(byAdding: .day, value: -back, to: calendar.date(from: DateComponents(year: 2032, month: 6, day: 20, hour: 9))!)!
                .formatted(.iso8601)
        }
        var history: [FinancialOperationInput] = []
        for i in 0..<12_000 {
            let day = days[i % 400]
            switch i % 40 {
            case 0:
                history.append(op(100_000_00, kind: "income", category: "Зарплата", description: "ООО Ромашка", date: day))
            case 1:
                history.append(op(-20_000_00, kind: "expense", category: "ЖКХ", description: "УК Жилищник", date: day))
            case 2:
                history.append(op(-5_000_00, kind: "transfer", category: "Переводы", description: "Перевод между счетами одного клиента", date: day))
            case 3:
                history.append(op(5_000_00, kind: "transfer", category: "Переводы", description: "Перевод между счетами одного клиента", date: day))
            case 4:
                history.append(op(700_00, kind: "refund", category: "Супермаркеты", description: "Магазин \(i % 60)", date: day))
            default:
                history.append(op(-Int64(100 + (i * 37) % 5_000) * 100, kind: "expense", category: ["Супермаркеты", "Кафе", "Транспорт", "Одежда"][i % 4],
                                  description: "Магазин \(i % 60)", date: day))
            }
        }
        var forecast = FinancialEngine.monthForecast(history, now: now, calendar: calendar)
        var best = Double.infinity
        for _ in 0..<3 {
            let started = Date()
            forecast = FinancialEngine.monthForecast(history, now: now, calendar: calendar)
            best = min(best, Date().timeIntervalSince(started))
        }
        let signature = [forecast.spentKopecks, forecast.incomeKopecks, forecast.projectedExpenseKopecks, forecast.projectedExpenseLowKopecks,
                         forecast.projectedExpenseHighKopecks, forecast.projectedIncomeKopecks, forecast.previousMonthIncomeKopecks,
                         forecast.typicalIrregularIncomeKopecks, forecast.irregularIncomeSoFarKopecks, forecast.oneOffKopecks,
                         Int64(forecast.upcoming.count), Int64(forecast.historyMonths), Int64(forecast.baselineMonths.count)]
        print("FORECAST-SPEED: \(history.count) rows, best of 3 = \(Int(best * 1000)) ms, signature \(signature)")
        require(signature == [173380000, 300000000, 259228000, 256469050, 260875300, 300000000, 300000000, 300000000, 300000000, 0, 0, 6, 6], "the forecast of a large history is unchanged by speed-ups: \(signature)")
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

    /// Refunds are shown apart: they lower what was spent, never the spending still expected, and the forecast is never negative.
    static func testForecastRefunds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2032, month: month, day: day, hour: 12))! }
        func iso(_ month: Int, _ day: Int) -> String { String(format: "2032-%02d-%02dT12:00:00Z", month, day) }
        let history = (1...3).flatMap { month in
            [1, 15, 25].map { op(-1_000, kind: "expense", category: "Супермаркеты", description: "Продукты учебные", date: iso(month, $0)) }
        }
        let current = history + [op(-1_000, kind: "expense", category: "Супермаркеты", description: "Продукты учебные", date: iso(4, 1))]
        let refund = op(10_000, kind: "refund", category: "Возврат", description: "Возврат учебный", date: iso(4, 2))
        let plain = FinancialEngine.monthForecast(current, now: at(4, 10), calendar: calendar)
        let returned = FinancialEngine.monthForecast(current + [refund], now: at(4, 10), calendar: calendar)
        require(returned.projectedExpenseKopecks >= 0 && returned.projectedExpenseLowKopecks >= 0, "a refund larger than the purchases does not make the forecast negative")
        require(returned.futureExpenseKopecks == plain.futureExpenseKopecks && returned.futureExpenseLowKopecks == plain.futureExpenseLowKopecks
                && returned.futureExpenseHighKopecks == plain.futureExpenseHighKopecks, "a refund does not reduce the spending still expected")
        require(returned.spentKopecks == plain.spentKopecks - 10_000 && returned.refundsKopecks == 10_000 && plain.refundsKopecks == 0,
                "the refund lowers what was spent and is shown apart")
        require(plain.projectedExpenseKopecks == plain.spentKopecks + plain.futureExpenseKopecks, "without refunds the forecast is spent plus what is still expected")
        let reserveBefore = FinancialEngine.monthReserve(balanceKopecks: 50_000, forecast: plain)
        require(FinancialEngine.monthReserve(balanceKopecks: 50_000, forecast: returned) == reserveBefore,
                "the reserve counts only the spending still expected, whatever came back")
        // a small refund inside the month: the total is spent + future as before
        let small = FinancialEngine.monthForecast(current + [op(300, kind: "refund", category: "Возврат", description: "Возврат учебный", date: iso(4, 2))],
                                                  now: at(4, 10), calendar: calendar)
        require(small.projectedExpenseKopecks == small.spentKopecks + small.futureExpenseKopecks, "a refund smaller than the purchases leaves the total as spent plus future")
    }

    /// A purchase returned in the same month leaves the pace (decision A); a month saved only from its second half is not
    /// history, and with fewer than two full months there is «мало данных» (decision 3); the line of a baseline month adds up.
    static func testForecastCompletenessAndReturns() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2032, month: month, day: day, hour: 12))! }
        func iso(_ month: Int, _ day: Int) -> String { String(format: "2032-%02d-%02dT12:00:00Z", month, day) }
        func buy(_ month: Int, _ day: Int, _ amount: Int64, _ shop: String = "Продукты учебные") -> FinancialOperationInput {
            op(-amount, kind: "expense", category: "Супермаркеты", description: shop, date: iso(month, day))
        }
        // decision 3: a lone old row and two sparse months before a complete one (the case of GPT, stage 54)
        var sparse = [buy(1, 1, 1_000, "Начало учебного архива")]
        for month in [2, 3] { sparse += [20, 21, 22].map { buy(month, $0, 1_000) } }
        sparse += stride(from: 1, through: 29, by: 2).map { buy(4, $0, 1_000) }
        let early = FinancialEngine.monthForecast(sparse, now: at(5, 1), calendar: calendar)
        require(early.historyMonths == 1 && !early.hasEnoughHistory, "months saved only from their second half are not history: \(early.historyMonths)")
        let steady = (1...4).flatMap { month in stride(from: 1, through: 28, by: 3).map { buy(month, $0, 1_000) } }
        let full = FinancialEngine.monthForecast(steady, now: at(5, 10), calendar: calendar)
        require(full.historyMonths == 4 && full.hasEnoughHistory, "a continuous history counts every full month")
        // decision A: a purchase returned in the same month does not raise the pace
        let base = steady + [buy(5, 2, 1_000)]
        let returned = base + [buy(5, 3, 30_000, "Магазин техники учебный"),
                               op(30_000, kind: "refund", category: "Возврат", description: "Магазин техники учебный", date: iso(5, 6))]
        let plain = FinancialEngine.monthForecast(base, now: at(5, 10), calendar: calendar)
        let back = FinancialEngine.monthForecast(returned, now: at(5, 10), calendar: calendar)
        require(back.futureExpenseKopecks == plain.futureExpenseKopecks, "a purchase returned the same month leaves the pace: \(back.futureExpenseKopecks) vs \(plain.futureExpenseKopecks)")
        require(back.spentKopecks == plain.spentKopecks && back.refundsKopecks == 30_000, "it is spent and returned, the refund is shown")
        // a refund of a purchase made in another month leaves the pace as it is
        let older = base + [op(5_000, kind: "refund", category: "Возврат", description: "Продукты учебные", date: iso(5, 6))]
        let olderForecast = FinancialEngine.monthForecast(older, now: at(5, 10), calendar: calendar)
        require(olderForecast.futureExpenseKopecks <= plain.futureExpenseKopecks, "a refund never raises the spending still expected")
        // the line of every baseline month adds up to its net expense
        let withRefunds = steady + [op(500, kind: "refund", category: "Возврат", description: "Другой магазин учебный", date: iso(3, 10)),
                                    buy(2, 14, 2_000, "Обувь учебная"),
                                    op(2_000, kind: "refund", category: "Возврат", description: "Обувь учебная", date: iso(2, 16))]
        let explained = FinancialEngine.monthForecast(withRefunds, now: at(5, 10), calendar: calendar)
        for month in explained.baselineMonths {
            require(month.variableKopecks + month.recurringKopecks + month.oneOffKopecks - month.otherRefundsKopecks == month.netExpenseKopecks,
                    "the line of \(month.month) adds up to the net expense")
        }
        require(explained.baselineMonths.contains { $0.otherRefundsKopecks == 500 }, "a refund of an older purchase is shown apart")
    }

    /// «Куда уходят деньги»: the biggest groups of the month against the same days of the month before, the shops inside.
    static func testSpendingLeaders() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2032, month: month, day: day, hour: 12))! }
        func iso(_ month: Int, _ day: Int) -> String { String(format: "2032-%02d-%02dT12:00:00Z", month, day) }
        func food(_ amount: Int64, _ shop: String, _ month: Int, _ day: Int) -> FinancialOperationInput {
            op(-amount, kind: "expense", category: "Супермаркеты", description: shop, mcc: "5411", date: iso(month, day))
        }
        func tech(_ amount: Int64, _ month: Int, _ day: Int) -> FinancialOperationInput {
            op(-amount, kind: "expense", category: "Электроника", description: "Техника учебная", mcc: "5732", date: iso(month, day))
        }
        let foodGroup = FinancialEngine.expenseCategory(for: food(1, "Магазин Альфа", 6, 1)).group
        let techGroup = FinancialEngine.expenseCategory(for: tech(1, 6, 1)).group
        require(foodGroup != techGroup, "the test needs two groups")
        let inputs = [
            food(500_000, "Магазин Альфа", 6, 3), food(300_000, "Магазин Альфа", 6, 10), food(200_000, "Магазин Бета", 6, 15),
            tech(400_000, 6, 5),
            food(600_000, "Магазин Альфа", 5, 5), tech(700_000, 5, 25),
            // not expenses of the report: income, a refund
            op(5_000_000, kind: "income", category: "Зарплата", description: "Зарплата учебная", date: iso(6, 2)),
        ]
        // the running month (June 1-20) against May 1-20: the 25th of May is not among the same days
        let june = ReportEngine.spendingLeaders(inputs, month: at(6, 20), now: at(6, 20), taxonomy: .builtin, calendar: calendar)
        require(june.periods.isPartial, "the month is running")
        require(june.totalKopecks == 1_400_000, "the total of the days so far")
        let juneGroups: [String] = june.leaders.map { $0.group }
        require(juneGroups == [foodGroup, techGroup], "the biggest group first")
        let first = june.leaders[0], second = june.leaders[1]
        require(first.amountKopecks == 1_000_000, "the first group so far")
        require(first.previousKopecks == 600_000, "the same days of May")
        require(first.changeKopecks == 400_000, "the change against them")
        require(first.sharePercent == 71, "the share of the period, rounded down")
        require(second.sharePercent == 28, "the share of the second")
        require(second.amountKopecks == 400_000, "the second group so far")
        require(second.previousKopecks == 0, "May 25 is outside the same days: nothing before")
        let shopTitles: [String] = first.shops.map { $0.title }
        let shopAmounts: [Int64] = first.shops.map { $0.amountKopecks }
        require(shopTitles == ["Магазин Альфа", "Магазин Бета"], "the shops inside, the largest first")
        require(shopAmounts == [800_000, 200_000], "their amounts")
        // a finished month against the whole month before
        let may = ReportEngine.spendingLeaders(inputs, month: at(5, 1), now: at(6, 20), taxonomy: .builtin, calendar: calendar)
        require(!may.periods.isPartial, "a finished month is whole")
        require(may.totalKopecks == 1_300_000, "the whole of May")
        require(may.leaders.first?.group == techGroup, "the biggest group of May")
        require(may.leaders.first?.amountKopecks == 700_000, "its amount")
        require(may.leaders.allSatisfy { $0.previousKopecks == 0 }, "no April spending")
        // the number of groups, a month without spending
        require(ReportEngine.spendingLeaders(inputs, month: at(6, 20), now: at(6, 20), taxonomy: .builtin, count: 1, calendar: calendar).leaders.count == 1, "the count of groups")
        let empty = ReportEngine.spendingLeaders([], month: at(6, 20), now: at(6, 20), taxonomy: .builtin, calendar: calendar)
        require(empty.leaders.isEmpty && empty.totalKopecks == 0, "no spending, no leaders")
        // the keys of the payments the owner said are no subscriptions survive saving
        var history = SavedHistory()
        history.notSubscriptionKeys = ["магазин альфа"]
        let data = try? JSONEncoder().encode(history)
        require(data.flatMap { try? JSONDecoder().decode(SavedHistory.self, from: $0) }?.notSubscriptionKeys == ["магазин альфа"], "the hidden payees survive saving")
    }

    /// The owner's changes and deletions of the operations of the bank hold over every new read.
    static func testBankOperationEdits() {
        var history = SavedHistory()
        let shop = bankOp("e1", -150_000, description: "Магазин учебный", date: "2032-06-02T10:00:00Z")
        let other = bankOp("e2", -20_000, description: "Кафе учебное", date: "2032-06-03T10:00:00Z")
        history.operations = [other, shop]
        require(!history.editBankOperation(identity: "nope", amountKopecks: -100, occurredAt: "2032-06-02T10:00:00Z", description: "Х"), "an operation that is not here")
        require(!history.editBankOperation(identity: "e1", amountKopecks: 0, occurredAt: "2032-06-02T10:00:00Z", description: "Х"), "no zero amount")
        require(!history.editBankOperation(identity: "e1", amountKopecks: -100, occurredAt: "not a date", description: "Х"), "a date that is not one")
        require(!history.editBankOperation(identity: "e1", amountKopecks: -100, occurredAt: "2032-06-02T10:00:00Z", description: "  "), "no empty title")
        require(history.operationEdits == nil && history.operations == [other, shop], "a refused change changes nothing")
        // the same values as the bank's are no change
        require(history.editBankOperation(identity: "e1", amountKopecks: -150_000, occurredAt: "2032-06-02T10:00:00Z", description: "Магазин учебный"), "same values")
        require(history.operationEdits == nil, "the bank's own values leave no edit")
        // a change: title, amount, day; the list stays in the order of the days
        require(history.editBankOperation(identity: "e1", amountKopecks: -175_000, occurredAt: "2032-06-04T09:00:00Z", description: "Магазин (поправлено)"), "an edit")
        let edited = history.operations.first { $0.identity == "e1" }!
        require(edited.amountKopecks == -175_000 && edited.description == "Магазин (поправлено)" && edited.kind == "expense", "the edit is on the operation")
        require(history.operations.map(\.identity) == ["e1", "e2"], "the new day is in its place in the list")
        require(history.operationEdits?["e1"]?.original == shop, "the bank's operation is kept")
        // a new read gives the operation again (maybe changed by the bank): the edit goes on the fresh one
        var fresh = shop
        fresh.verifiedAt = "2032-06-05T00:00:00Z"
        history.operations = history.operations.filter { $0.identity != "e1" } + [fresh]
        history.applyOperationEdits()
        let again = history.operations.first { $0.identity == "e1" }!
        require(again.amountKopecks == -175_000 && again.description == "Магазин (поправлено)" && history.operationEdits?["e1"]?.original == fresh,
                "the edit holds over a new read")
        // the sign flips: an income; the components of a group are dropped with the amount
        let group = BankOperation(identity: "e3", occurredAt: "2032-06-05T10:00:00Z", timePrecision: "exact", description: "Группа учебная",
                                  amountKopecks: -300_000, currency: "RUB", status: "Выполнено", category: "Тест", mcc: nil, purpose: nil,
                                  paymentMethod: nil, providers: [], kind: "grouped_operation",
                                  components: [OperationComponent(displayDate: "5 июня", amountKopecks: -100_000), OperationComponent(displayDate: "5 июня", amountKopecks: -200_000)])
        history.operations.append(group)
        require(history.editBankOperation(identity: "e3", amountKopecks: 300_000, occurredAt: "2032-06-05T10:00:00Z", description: "Группа учебная"), "a sign flip")
        let flipped = history.operations.first { $0.identity == "e3" }!
        require(flipped.amountKopecks == 300_000 && flipped.kind == "income" && flipped.components == nil, "an income without the components")
        // taking it back
        require(history.revertBankOperationEdit(identity: "e1") && history.operations.first { $0.identity == "e1" } == fresh && history.operationEdits?["e1"] == nil,
                "taken back: as the bank gave it")
        require(!history.revertBankOperationEdit(identity: "e1"), "nothing to take back")
        // deleting: gone, and a new read does not bring it back
        require(history.deleteBankOperation(identity: "e2"), "a deletion")
        require(!history.operations.contains { $0.identity == "e2" } && history.deletedOperationIdentities == ["e2"], "the operation is gone")
        history.operations.append(other)
        history.applyOperationEdits()
        require(!history.operations.contains { $0.identity == "e2" }, "a new read does not bring it back")
        // the owner's own operations are not touched
        let manual = ManualOperation(kind: .expense, amountKopecks: 1_000, date: Date()).bankOperation
        history.operations.append(manual)
        require(!history.editBankOperation(identity: manual.identity, amountKopecks: -2_000, occurredAt: "2032-06-05T10:00:00Z", description: "Х")
                    && !history.deleteBankOperation(identity: manual.identity), "a manual operation has its own form")
        // saved and opened again, and an old history without the fields
        let data = try? JSONEncoder().encode(history)
        let restored = data.flatMap { try? JSONDecoder().decode(SavedHistory.self, from: $0) }
        require(restored?.deletedOperationIdentities == ["e2"] && restored?.operationEdits?["e3"] != nil, "the edits survive saving")
        require((try? JSONDecoder().decode(SavedHistory.self, from: Data(#"{"operations":[]}"#.utf8)))?.operationEdits == nil, "an old history opens without them")
    }

    /// Credit cards: the balance is the money still available; the debt, the limit exceeded, the overpayment, saving with another limit.
    static func testCreditCards() {
        require(CreditCards.debt(limit: 10_000_000, balance: 8_000_000) == 2_000_000, "limit 100 000, 80 000 available: the debt is 20 000")
        require(CreditCards.debt(limit: 10_000_000, balance: 12_000_000) == 0 && CreditCards.overpaid(limit: 10_000_000, balance: 12_000_000) == 2_000_000,
                "more than the limit is an overpayment, not a negative debt")
        require(CreditCards.overLimit(balance: -300_000) == 300_000 && CreditCards.overLimit(balance: 5) == 0, "a balance below zero exceeds the limit")
        var card = Account(name: "Карта учебная", icon: "creditcard", color: "blue", groupID: nil, startBalanceKopecks: 8_000_000, startDate: Date())
        require(!card.isCreditCard, "no limit, not a credit card")
        card.creditLimitKopecks = 0
        require(!card.isCreditCard, "a zero limit is no limit")
        card.creditLimitKopecks = 10_000_000
        require(card.isCreditCard, "a limit makes a credit card")
        // the same debt at creation with a larger limit: the start balance moves by the difference, the account goes on
        let raised = CreditCards.resave(oldLimit: 10_000_000, oldStartBalance: 8_000_000, newLimit: 15_000_000, debt: 2_000_000)
        require(raised.startBalanceKopecks == 13_000_000 && !raised.restarts, "another limit, the same debt: the account goes on")
        let other = CreditCards.resave(oldLimit: 10_000_000, oldStartBalance: 8_000_000, newLimit: 10_000_000, debt: 1_000_000)
        require(other.startBalanceKopecks == 9_000_000 && other.restarts, "another debt starts the account again")
        let converted = CreditCards.resave(oldLimit: nil, oldStartBalance: 500_000, newLimit: 10_000_000, debt: 0)
        require(converted.startBalanceKopecks == 10_000_000 && converted.restarts, "an account that was not a card starts again")
        // the limit is kept in the saved history and old data without it open as before
        let encoded = try? JSONEncoder().encode(card)
        require(encoded.flatMap { try? JSONDecoder().decode(Account.self, from: $0) }?.creditLimitKopecks == 10_000_000, "the limit survives saving")
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Старый","icon":"banknote","color":"gray","startBalanceKopecks":100,"startDate":0,"showsBalance":true,"tracksBankCard":false}"#
        require((try? JSONDecoder().decode(Account.self, from: Data(old.utf8)))?.creditLimitKopecks == nil, "an old account opens without a limit")
    }

    /// Subscriptions and loans entered by the owner: their days, the balance of a loan, and their place in the forecast.
    static func testCommitments() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ month: Int, _ day: Int, _ year: Int = 2032) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))! }
        func iso(_ month: Int, _ day: Int) -> String { String(format: "2032-%02d-%02dT12:00:00Z", month, day) }
        func days(_ dues: [FinancialEngine.CommitmentDue]) -> [Int] { dues.map { calendar.component(.day, from: $0.date) } }

        // the days: the 31st of a short month is its last day (2032 is a leap year); a yearly one comes once; «since» skips older ones
        let monthly = Subscription(name: "Подписка учебная", amountKopecks: 79_900, day: 31)
        require(days(FinancialEngine.commitmentDues(subscriptions: [monthly], loans: [], from: at(1, 1), to: at(4, 1), calendar: calendar)) == [31, 29, 31],
                "the 31st is the last day of a short month")
        let yearly = Subscription(name: "Годовая учебная", amountKopecks: 120_000, day: 15, month: 3)
        let yearlyDues = FinancialEngine.commitmentDues(subscriptions: [yearly], loans: [], from: at(1, 1), to: at(1, 1, 2033), calendar: calendar)
        require(yearlyDues.count == 1 && calendar.component(.month, from: yearlyDues[0].date) == 3, "a yearly subscription comes once a year")
        var later = monthly
        later.since = at(2, 20)
        require(days(FinancialEngine.commitmentDues(subscriptions: [later], loans: [], from: at(1, 1), to: at(4, 1), calendar: calendar)) == [29, 31],
                "a payment dated before the subscription was entered is not waited for")
        require(FinancialEngine.commitmentDues(subscriptions: [Subscription(name: "Нулевая", amountKopecks: 0, day: 5)], loans: [], from: at(1, 1), to: at(4, 1), calendar: calendar).isEmpty,
                "no amount, no payment")

        // a loan: the balance goes down by each payment, the last one is what is left, then nothing
        var loan = Loan(name: "Кредит учебный", paymentKopecks: 10_000, day: 15, balanceKopecks: 25_000, balanceDate: at(1, 10), reducesBalance: true)
        func amounts(_ loan: Loan, to: Date) -> [Int64] {
            FinancialEngine.commitmentDues(subscriptions: [], loans: [loan], from: at(1, 1), to: to, calendar: calendar).map(\.amountKopecks)
        }
        require(amounts(loan, to: at(7, 1)) == [10_000, 10_000, 5_000], "the balance goes down; the last payment is what is left")
        loan.balanceDate = at(1, 15)
        require(amounts(loan, to: at(7, 1)) == [10_000, 10_000, 5_000] && FinancialEngine.commitmentDues(subscriptions: [], loans: [loan], from: at(1, 1), to: at(2, 1), calendar: calendar).isEmpty,
                "a balance entered on the day of a payment already counts it")
        loan.balanceDate = at(1, 10)
        loan.reducesBalance = false
        require(amounts(loan, to: at(4, 1)) == [10_000, 10_000, 10_000], "a balance that is not reduced leaves the payments as they are")
        loan.reducesBalance = true
        require(loan.balance(now: at(1, 12), calendar: calendar) == 25_000 && loan.balance(now: at(2, 20), calendar: calendar) == 5_000
                    && loan.balance(now: at(8, 1), calendar: calendar) == 0, "the balance now")
        loan.reducesBalance = false
        require(loan.balance(now: at(8, 1), calendar: calendar) == 25_000, "a kept balance stays as entered")
        loan.balanceKopecks = nil
        require(loan.balance(now: at(8, 1), calendar: calendar) == nil, "no balance entered")

        // saving a loan: the balance untouched in the same mode stays as it was; an edited one, or another mode, starts from now
        let kept = Loan(name: "Кредит учебный", paymentKopecks: 10_000, day: 15, balanceKopecks: 25_000, balanceDate: at(1, 10), reducesBalance: true)
        let today = at(2, 20)
        let untouched = Loan.keptBalance(old: kept, entered: 5_000, reduces: true, now: today, calendar: calendar)
        require(untouched.kopecks == 5_000 && untouched.date == today, "the balance as shown is anchored from now (a changed payment cannot rewrite the past)")
        let edited = Loan.keptBalance(old: kept, entered: 4_000, reduces: true, now: today, calendar: calendar)
        require(edited.kopecks == 4_000 && edited.date == today, "an edited balance starts from now")
        let switched = Loan.keptBalance(old: kept, entered: 5_000, reduces: false, now: today, calendar: calendar)
        require(switched.kopecks == 5_000 && switched.date == today, "another mode fixes the balance as seen now")
        let cleared = Loan.keptBalance(old: kept, entered: nil, reduces: true, now: today, calendar: calendar)
        require(cleared.kopecks == nil && cleared.date == nil, "nothing entered, no balance")
        let fresh = Loan.keptBalance(old: nil, entered: 30_000, reduces: true, now: today, calendar: calendar)
        require(fresh.kopecks == 30_000 && fresh.date == today, "a new loan's balance starts from now")

        // the forecast: a payment of the month is expected; one already among the operations, or already a found regular one, is not counted twice
        let due = Subscription(name: "Подписка учебная", amountKopecks: 700_000, day: 20, since: at(4, 1))
        let expectedDue = FinancialEngine.monthForecast([], now: at(4, 10), calendar: calendar, subscriptions: [due])
        require(expectedDue.upcoming.count == 1 && expectedDue.upcoming[0].amountKopecks == 700_000 && expectedDue.upcoming[0].status == .expected
                    && expectedDue.futureExpenseKopecks == 700_000, "a subscription payment is expected spending")
        let paidAlready = [op(-710_000, kind: "expense", category: "Тест", description: "Подписка учебная", date: iso(4, 19))]
        require(FinancialEngine.monthForecast(paidAlready, now: at(4, 21), calendar: calendar, subscriptions: [due]).upcoming.isEmpty,
                "an expense of about the same amount within three days is the payment")
        let farOff = [op(-710_000, kind: "expense", category: "Тест", description: "Подписка учебная", date: iso(4, 9))]
        require(FinancialEngine.monthForecast(farOff, now: at(4, 21), calendar: calendar, subscriptions: [due]).upcoming.count == 1,
                "the same expense a week before is another one")
        let service = (1...3).map { op(-50_000, kind: "expense", category: "Связь", description: "Услуга учебная регулярная", date: iso($0, 5)) }
        let same = Subscription(name: "Услуга", amountKopecks: 50_000, day: 5, since: at(4, 1))
        let counted = FinancialEngine.monthForecast(service, now: at(4, 2), calendar: calendar, subscriptions: [same])
        require(counted.upcoming.count == 1 && counted.upcoming[0].key.hasPrefix("out|"), "a payment already among the regular ones is not counted twice")

        // late: waited for a week, then asked about; the answer closes or moves it; one entered after its day is not asked about
        let early = Subscription(name: "Подписка учебная", amountKopecks: 700_000, day: 5, since: at(4, 1))
        let waiting = FinancialEngine.monthForecast([], now: at(4, 12), calendar: calendar, subscriptions: [early])
        require(waiting.upcoming.count == 1 && waiting.upcoming[0].status == .waiting && waiting.futureExpenseKopecks == 700_000, "a week late it is still waited for")
        let asked = FinancialEngine.monthForecast([], now: at(4, 13), calendar: calendar, subscriptions: [early])
        require(asked.questions.count == 1 && asked.futureExpenseKopecks == 0, "more than a week late it is asked about, not counted")
        let key = asked.questions[0].key
        require(key == FinancialEngine.commitmentKey(id: early.id, due: at(4, 5), calendar: calendar) && key.hasPrefix("commit|"), "the key of the answer")
        for kind in [FinancialEngine.PaymentAnswer.Kind.arrived, .skipped] {
            require(FinancialEngine.monthForecast([], now: at(4, 13), calendar: calendar, answers: [key: .init(kind: kind)], subscriptions: [early]).upcoming.isEmpty,
                    "the answer «\(kind.rawValue)» closes it")
        }
        let moved = FinancialEngine.monthForecast([], now: at(4, 13), calendar: calendar,
                                                  answers: [key: .init(kind: .moved, movedTo: calendar.startOfDay(for: at(4, 20)))], subscriptions: [early])
        require(moved.questions.isEmpty && moved.upcoming.count == 1 && moved.upcoming[0].status == .expected, "a moved payment is expected on its new day")
        var added = early
        added.since = at(4, 10)
        require(FinancialEngine.monthForecast([], now: at(4, 13), calendar: calendar, subscriptions: [added]).upcoming.isEmpty,
                "a payment of a subscription entered after its day is not asked about")
        let loanForecast = FinancialEngine.monthForecast([], now: at(4, 10), calendar: calendar,
                                                         loans: [Loan(name: "Кредит учебный", paymentKopecks: 1_500_000, day: 25, since: at(4, 1))])
        require(loanForecast.upcoming.count == 1 && loanForecast.futureExpenseKopecks == 1_500_000, "a loan payment is expected spending")
    }

    /// A late regular payment is waited for a week, then asked about and not counted (decision 2); the owner's answer closes
    /// or moves it; one of last month is not dropped on the 1st (decision 5); the cautious irregular income (decision C).
    static func testForecastLatePaymentsAndIrregularIncome() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2032, month: month, day: day, hour: 12))! }
        func iso(_ month: Int, _ day: Int) -> String { String(format: "2032-%02d-%02dT12:00:00Z", month, day) }
        let service = (1...3).map { op(-50_000, kind: "expense", category: "Связь", description: "Услуга учебная регулярная", date: iso($0, 5)) }
        func expected(_ forecast: FinancialEngine.MonthForecast) -> Int64 {
            forecast.upcoming.filter { !$0.isIncome && $0.status != .question }.reduce(0) { $0 + $1.amountKopecks }
        }
        // decision 2: the 5th + 7 days is still waited for, on the 8th day it is a question
        let seventh = FinancialEngine.monthForecast(service, now: at(4, 12), calendar: calendar)
        let eighth = FinancialEngine.monthForecast(service, now: at(4, 13), calendar: calendar)
        require(expected(seventh) == 50_000 && seventh.upcoming.first?.status == .waiting && seventh.questions.isEmpty, "a week late it is still waited for")
        require(expected(eighth) == 0 && eighth.questions.count == 1, "more than a week late it is asked about, not counted")
        let key = eighth.questions[0].key
        require(key == FinancialEngine.paymentKey(title: "Услуга учебная регулярная", isIncome: false, due: at(4, 5), calendar: calendar), "the key of the answer")
        for kind in [FinancialEngine.PaymentAnswer.Kind.arrived, .skipped] {
            let answered = FinancialEngine.monthForecast(service, now: at(4, 13), calendar: calendar, answers: [key: .init(kind: kind)])
            require(answered.questions.isEmpty && expected(answered) == 0, "the answer «\(kind.rawValue)» closes the question")
        }
        let moved = FinancialEngine.monthForecast(service, now: at(4, 13), calendar: calendar,
                                                  answers: [key: .init(kind: .moved, movedTo: calendar.startOfDay(for: at(4, 20)))])
        require(moved.questions.isEmpty && expected(moved) == 50_000 && moved.upcoming.first?.status == .expected, "a moved payment is expected on its new day")
        // decision 5: the payment of the 30th that did not come is still waited for on the 1st of the next month
        let rent = [iso(1, 30), iso(2, 29), iso(3, 30)].map { op(-50_000, kind: "expense", category: "ЖКХ", description: "Аренда учебная", date: $0) }
        let first = FinancialEngine.monthForecast(rent, now: at(5, 1), calendar: calendar)
        let late = first.upcoming.filter { $0.date < at(5, 1) }
        require(late.count == 1 && late[0].status == .waiting && calendar.component(.month, from: late[0].date) == 4,
                "last month's rent that has not come is shown as waited for, not dropped")
        // decision C: the smallest irregular income of the full months, minus what came this month; nothing with too little history
        var incomes: [FinancialOperationInput] = []
        for (month, amount) in [(1, 40_000), (2, 25_000), (3, 60_000)] as [(Int, Int64)] {
            incomes += stride(from: 1, through: 28, by: 3).map { op(-1_000, kind: "expense", category: "Супермаркеты", description: "Продукты учебные", date: iso(month, $0)) }
            incomes.append(op(amount, kind: "income", category: "Переводы", description: "Перевод учебный \(month)", date: iso(month, 10 + month)))
        }
        incomes.append(op(10_000, kind: "income", category: "Переводы", description: "Перевод учебный апрель", date: iso(4, 2)))
        let april = FinancialEngine.monthForecast(incomes, now: at(4, 5), calendar: calendar)
        require(april.cautiousIrregularIncomeKopecks == 25_000 && calendar.component(.month, from: april.cautiousIrregularMonth ?? .distantPast) == 2,
                "the smallest irregular income of the full months: \(april.cautiousIrregularIncomeKopecks)")
        require(april.cautiousIrregularLeftKopecks == 15_000, "what already came this month is taken off")
        // The reserve the screens show never counts irregular income: it is never above the balance plus the regular income still expected.
        for balance in [0, 50_000, 100_000] as [Int64] {
            require(FinancialEngine.monthReserve(balanceKopecks: balance, forecast: april) <= balance + april.expectedIncomeLeftKopecks,
                    "the reserve is never above the balance and the regular income still expected")
        }
        require(FinancialEngine.monthReserve(balanceKopecks: 100_000, forecast: april, includeIrregular: true)
                == FinancialEngine.monthReserve(balanceKopecks: 100_000, forecast: april) + 15_000, "the reserve adds it only when asked")
        let range = FinancialEngine.monthReserveRange(balanceKopecks: 100_000, forecast: april, includeIrregular: true)
        let plainRange = FinancialEngine.monthReserveRange(balanceKopecks: 100_000, forecast: april)
        require(range.low == plainRange.low + 15_000 && range.high == plainRange.high + 15_000, "the range moves by the same amount")
        let short = FinancialEngine.monthForecast(Array(incomes.prefix(11)) + [incomes[22]], now: at(2, 20), calendar: calendar)
        require(short.cautiousIrregularIncomeKopecks == 0, "with fewer than two full months nothing irregular is counted")
    }

    /// The reconciliation with the bank's balance: what explains a difference, and the reading of a balance (46.29).
    static func testBalanceReconciliation() {
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        func row(_ id: String, _ delta: Int64, _ minutes: Double = 0, pending: Bool = false, payee: String = "магазин учебный") -> FinancialEngine.ReconciliationRow {
            FinancialEngine.ReconciliationRow(identity: id, deltaKopecks: delta, date: day.addingTimeInterval(minutes * 60), pending: pending, payee: payee)
        }
        require(FinancialEngine.explainBalanceDifference(0, rows: [row("a", -500)]).isEmpty, "no difference, nothing to explain")
        // one operation «в обработке» of exactly the difference comes first
        let rows = [row("p", -165_687, pending: true, payee: "магнит учебный"), row("s", 100_000, payee: "перевод учебный"), row("x", -1_234)]
        let pending = FinancialEngine.explainBalanceDifference(-165_687, rows: rows)
        require(pending.first?.kind == .pending && pending.first?.identities == ["p"] && FinancialEngine.balanceExplanationIsClear(pending),
                "a pending operation of the difference is the clear reason")
        // two alike operations two minutes apart: one of them is extra
        let doubled = [row("d1", -30_000, 0, payee: "кофейня учебная"), row("d2", -30_000, 1, payee: "кофейня учебная"), row("y", -7_700)]
        let duplicate = FinancialEngine.explainBalanceDifference(-30_000, rows: doubled)
        require(duplicate.first?.kind == .duplicate && Set(duplicate.first?.identities ?? []) == ["d1", "d2"], "a duplicate is one extra operation")
        // the same two operations an hour apart are two real purchases: each alone explains it, nothing stands out
        let apart = FinancialEngine.explainBalanceDifference(-30_000, rows: [row("d1", -30_000, 0), row("d2", -30_000, 60)])
        require(apart.allSatisfy { $0.kind == .single } && apart.count == 2 && !FinancialEngine.balanceExplanationIsClear(apart),
                "two equal purchases an hour apart are not a duplicate, and the choice is the owner's")
        // a pair only when nothing else fits, marked as a pair
        let pair = FinancialEngine.explainBalanceDifference(-80_000, rows: [row("a", -50_000), row("b", -30_000), row("c", -99)])
        require(pair.count == 1 && pair[0].kind == .pair && Set(pair[0].identities) == ["a", "b"], "two operations adding up, as a possible coincidence")
        require(FinancialEngine.explainBalanceDifference(-9_999_999, rows: [row("a", -1_234)]).isEmpty, "nothing fits: no guess")
        // the sign matters: a pending expense explains only the difference it makes (GPT stage 59, B59-4)
        let opposite = FinancialEngine.explainBalanceDifference(165_687, rows: rows)
        require(opposite.allSatisfy { $0.kind != .pending }, "with the opposite sign it is only a matching sum")
        require(!FinancialEngine.explainBalanceDifference(30_000, rows: doubled).contains { $0.kind == .duplicate }, "a duplicate of expenses does not explain a plus")
        require(!FinancialEngine.balanceExplanationIsClear(pair), "a single pair is never «the reason» (B59-5)")
        require(FinancialEngine.rublesKopecks("1234,56 ₽") == 123_456, "a sum without a space")
        require(FinancialEngine.rublesKopecks("92233720368547758,08 ₽") == nil && FinancialEngine.rublesKopecks("1₽2 ₽") == nil, "no overflow, one ruble sign at the end")
        // the reading of a balance from the bank page
        require(FinancialEngine.rublesKopecks("80 829,95 ₽") == 8_082_995 && FinancialEngine.rublesKopecks("1\u{00A0}000 ₽") == 100_000
                && FinancialEngine.rublesKopecks("70\u{202F}000,5 ₽") == 7_000_050, "balances with spaces of any kind")
        require(FinancialEngine.rublesKopecks("−200,00 ₽") == nil && FinancialEngine.rublesKopecks("Карта Пэй") == nil, "a signed sum or a word is not a balance")
        // the account that follows the bank gets the bank's balance
        var history = SavedHistory()
        history.bankBalances = BankBalanceReading(cardKopecks: 8_082_995, saveKopecks: 7_000_000, readAt: day)
        let card = Account(name: "Карта", icon: "creditcard", color: "yellow", startBalanceKopecks: 0, startDate: day)
        var cardAccount = card
        cardAccount.tracksBankCard = true
        var save = card
        save.tracksSave = true
        require(history.bankBalance(for: cardAccount) == 8_082_995 && history.bankBalance(for: save) == 7_000_000 && history.bankBalance(for: card) == nil,
                "the card and Save accounts get the bank's balances, others none")
        // the dates of the readings (GPT stage 61): an old copy keeps the date of Save when only the card is read now
        let hourAgo = day.addingTimeInterval(-3_600)
        let legacy = BankBalanceReading(cardKopecks: 100_000, saveKopecks: 7_000_010, readAt: hourAgo)
        let cardOnly = legacy.updated(card: 123_456, save: nil, at: day)
        require(cardOnly.cardReadAt == day && cardOnly.saveReadAt == hourAgo && cardOnly.saveKopecks == 7_000_010 && cardOnly.readAt == day,
                "a reading of the card alone does not make Save fresh")
        var dated = SavedHistory()
        dated.bankBalances = cardOnly
        dated.lastSync = day.addingTimeInterval(-30)
        require(dated.bankBalanceIsFresh(for: cardAccount) && !dated.bankBalanceIsFresh(for: save), "the card is fresh, Save is not")
        dated.lastSync = day.addingTimeInterval(1)
        require(!dated.bankBalanceIsFresh(for: cardAccount), "an operation saved after the reading makes it old, even a second later")
    }

    /// The range of the forecast from the errors of the past forecasts of the same day (decision 4).
    static func testForecastRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func iso(_ year: Int, _ month: Int, _ day: Int) -> String { String(format: "%04d-%02d-%02dT12:00:00Z", year, month, day) }
        // fourteen months of steady shopping with a month of 2–3 times more now and then
        var history: [FinancialOperationInput] = []
        for index in 0..<14 {
            let year = 2031 + (index / 12), month = index % 12 + 1
            let scale: Int64 = index % 5 == 3 ? 3 : 1
            for day in stride(from: 1, through: 28, by: 3) {
                history.append(op(-1_000 * scale - Int64(day * 10), kind: "expense", category: "Супермаркеты", description: "Продукты учебные", date: iso(year, month, day)))
            }
        }
        let now = calendar.date(from: DateComponents(year: 2032, month: 3, day: 10, hour: 15))!
        let range = FinancialEngine.forecastRange(history, now: now, calendar: calendar)
        require(range.months >= 4 && range.isShown, "the past months give their errors: \(range.months)")
        require(range.lowErrorKopecks <= 0 && range.highErrorKopecks >= 0, "the range is around the forecast")
        require(range.highErrorKopecks > 0, "a month far above the usual makes the upper side wider")
        // what happens after today does not change the range (no peeking into the future of the past months either)
        let future = history + [op(-9_999_999, kind: "expense", category: "Супермаркеты", description: "Будущее учебное", date: iso(2032, 3, 20))]
        require(FinancialEngine.forecastRange(future, now: now, calendar: calendar).months == range.months, "an operation after today does not count")
        // too little history: no range
        let short = Array(history.prefix(30))
        let shortRange = FinancialEngine.forecastRange(short, now: calendar.date(from: DateComponents(year: 2031, month: 4, day: 10))!, calendar: calendar)
        require(!shortRange.isShown && shortRange.lowErrorKopecks == 0 && shortRange.highErrorKopecks == 0, "fewer than four months of errors: no range")
        // the 31st: months without that day give no error
        let late = FinancialEngine.forecastRange(history, now: calendar.date(from: DateComponents(year: 2032, month: 1, day: 31, hour: 12))!, calendar: calendar)
        require(late.months <= 7, "only the months with a 31st give an error: \(late.months)")
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
                                                     elapsedDays: 6, daysInMonth: 31,
                                                     futureExpenseKopecks: 129_940 - 24_913, futureExpenseLowKopecks: 117_098 - 24_913,
                                                     futureExpenseHighKopecks: 144_877 - 24_913)
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

    static func testCategorySuggestions() {
        var history = SavedHistory()
        func category(_ group: String, _ name: String) -> UUID {
            history.categoryTree.first { $0.name == group }!.categories.first { $0.name == name }!.id
        }
        let food = category("Еда", "Супермаркеты")
        let cafe = category("Еда", "Кафе и рестораны")
        let clothes = category("Покупки", "Одежда")
        let target = bankOp("suggest-target", -100, description: "СозвездиеТест кафе север")
        let group = ReviewGroup(id: "suggest-group", key: FinancialEngine.payeeRuleKey(target.description),
                                kind: .expense, operations: [target])
        let old = bankOp("suggest-old", -200, description: target.description, date: "2032-05-02T10:00:00Z")
        let newer = bankOp("suggest-new", -300, description: target.description, date: "2032-06-01T10:00:00Z")
        let similar1 = bankOp("suggest-similar-1", -400, description: "ООО СозвездиеТест юг")
        let similar2 = bankOp("suggest-similar-2", -500, description: "СозвездиеТест восток")
        history.operations = [target, old, newer, similar1, similar2]
        history.categoryOverrides = [target.identity: UncategorizedReview.otherExpenseID, old.identity: food,
                                     newer.identity: clothes, similar1.identity: food, similar2.identity: food]
        let suggestions = CategorySuggestions.suggest(for: group, history: history)
        require(suggestions.map(\.reason) == [.history, .words, .similarPayees], "suggestions rank history, words, then similar payees")
        require(suggestions.map(\.categoryID) == [clothes, cafe, food], "history frequency tie chooses the freshest category")
        require(suggestions.map(\.count) == [1, 0, 2] && suggestions.count <= 3,
                "suggestion counts reflect evidence and there are at most three")
        let repeated = bankOp("suggest-repeat", -600, description: target.description, date: "2032-04-01T10:00:00Z")
        history.operations.append(repeated)
        history.categoryOverrides?[repeated.identity] = food
        let frequent = CategorySuggestions.suggest(for: group, history: history)
        require(frequent.first?.categoryID == food && frequent.first?.count == 2, "history frequency outranks freshness")
        require(frequent.count == 2 && Set(frequent.map(\.categoryID)).count == frequent.count, "repeated category keeps its strongest reason only")

        let conflict = bankOp("suggest-conflict", -100, description: "СозвездиеТест запад")
        history.operations = [target, similar1, similar2, conflict]
        history.categoryOverrides?[conflict.identity] = clothes
        require(CategorySuggestions.suggest(for: group, history: history).map(\.reason) == [.words], "two of three similar purchases is below 80 percent")
        let similar3 = bankOp("suggest-similar-3", -100, description: "СозвездиеТест центр")
        let similar4 = bankOp("suggest-similar-4", -100, description: "СозвездиеТест берег")
        history.operations += [similar3, similar4]
        history.categoryOverrides?[similar3.identity] = food
        history.categoryOverrides?[similar4.identity] = food
        require(CategorySuggestions.suggest(for: group, history: history).last?.count == 4, "exactly 80 percent qualifies as a similar-payee suggestion")
        history.operations = [target, similar1]
        require(CategorySuggestions.suggest(for: group, history: history).map(\.reason) == [.words], "one similar operation is not sufficient")

        let unnamed = ReviewGroup(id: "suggest-empty", key: "", kind: .expense, operations: [target])
        history.operations = [target, old, newer, similar1, similar2]
        require(CategorySuggestions.suggest(for: unnamed, history: history).map(\.reason) == [.words], "empty payee key permits words only")
        let income = ReviewGroup(id: "suggest-income", key: group.key, kind: .income, operations: [target])
        require(CategorySuggestions.suggest(for: income, history: history).isEmpty, "income groups get no expense suggestions")
        let unknown = bankOp("suggest-unknown", -100, description: "АбстракцияТест север")
        let other = bankOp("suggest-other", -200, description: unknown.description)
        let unknownGroup = ReviewGroup(id: "suggest-unknown-group", key: FinancialEngine.payeeRuleKey(unknown.description),
                                       kind: .expense, operations: [unknown])
        history.operations = [unknown, other]
        history.categoryOverrides = [other.identity: UncategorizedReview.otherExpenseID]
        require(CategorySuggestions.suggest(for: unknownGroup, history: history).isEmpty, "Misc is never evidence or a suggestion")
        require(history.renameExpenseCategory(UncategorizedReview.otherExpenseID, to: "РазобратьТест"), "suggestion fixture renames Misc")
        require(CategorySuggestions.suggest(for: unknownGroup, history: history).isEmpty, "Misc stays excluded after renaming")
        history.expenseCategories = history.categoryTree.map { value in
            var changed = value
            changed.categories.removeAll { $0.id == cafe }
            return changed
        }
        require(CategorySuggestions.suggest(for: unnamed, history: history).isEmpty, "word suggestion must exist in the user's tree")
    }

    static func testSuggestionsInBatch() {
        var history = SavedHistory()
        let food = history.categoryTree.first { $0.name == "Еда" }!.categories.first { $0.name == "Супермаркеты" }!.id
        let first = bankOp("batch-a1", -100, description: "ПолучательТест север")
        let second = bankOp("batch-a2", -200, description: "ПолучательТест север")
        let third = bankOp("batch-b1", -300, description: "АбстракцияТест юг")
        history.operations = [first, second, third]
        history.categoryOverrides = [first.identity: food, second.identity: UncategorizedReview.otherExpenseID,
                                     third.identity: UncategorizedReview.otherExpenseID]
        let groups = UncategorizedReview.groups(history)
        require(groups.count == 2, "two payees are left to sort")
        let batch = CategorySuggestions.suggestions(for: groups, history: history)
        for group in groups {
            require(batch[group.id] == CategorySuggestions.suggest(for: group, history: history), "the batch gives what one group gives")
        }
        let known = groups.first { $0.key == FinancialEngine.payeeRuleKey(second.description) }!
        require(batch[known.id]?.first?.categoryID == food && batch[known.id]?.first?.reason == .history, "the earlier choice for the same payee is suggested")
        require(CategorySuggestions.suggestions(for: [], history: history).isEmpty, "no groups, no suggestions")
    }

    static func testRuleCandidates() {
        var history = SavedHistory()
        let food = history.categoryTree[0].categories[0].id
        let otherCategory = history.categoryTree[0].categories[1].id
        let operations = (1...4).map { bankOp("candidate-\($0)", -100, description: "ПолучательТест север") }
        history.operations = operations
        history.categoryOverrides = Dictionary(uniqueKeysWithValues: operations.prefix(3).map { ($0.identity, food) })
        let candidates = CategorySuggestions.ruleCandidates(history)
        require(candidates.count == 1 && candidates[0].categoryID == food && candidates[0].operationCount == 4,
                "exactly three identical manual category choices offer a rule covering all bank expenses")
        history.categoryOverrides?[operations[3].identity] = otherCategory
        require(CategorySuggestions.ruleCandidates(history).isEmpty, "a conflicting manual category blocks a rule")
        history.categoryOverrides?[operations[3].identity] = nil
        require(history.setExpenseCategory(food, for: operations[3], forPayee: true), "candidate fixture adds a rule")
        require(CategorySuggestions.ruleCandidates(history).isEmpty, "an existing payee rule is not offered again")
        history.categoryRules = nil
        history.categoryOverrides?[operations[2].identity] = nil
        require(CategorySuggestions.ruleCandidates(history).isEmpty, "two manual choices are not enough")
        history.operations = (1...3).map { bankOp("candidate-empty-\($0)", -100, description: "12345") }
        history.categoryOverrides = Dictionary(uniqueKeysWithValues: history.operations.map { ($0.identity, food) })
        require(CategorySuggestions.ruleCandidates(history).isEmpty, "empty keys never produce rule candidates")
        history.operations = (1...3).map { bankOp("manual:candidate-\($0)", -100, description: "ПолучательТест север") }
        history.categoryOverrides = Dictionary(uniqueKeysWithValues: history.operations.map { ($0.identity, food) })
        require(CategorySuggestions.ruleCandidates(history).isEmpty, "manual operations cannot count towards bank payee rules")
        history.operations = operations
        history.categoryOverrides = Dictionary(uniqueKeysWithValues: operations.map { ($0.identity, UUID()) })
        require(CategorySuggestions.ruleCandidates(history).isEmpty, "deleted or conflicting category ids are not offered")
        history.operations = (1...3).map { bankOp("candidate-income-\($0)", 100, description: "ПолучательТест север", kind: "income") }
        history.categoryOverrides = Dictionary(uniqueKeysWithValues: history.operations.map { ($0.identity, food) })
        require(CategorySuggestions.ruleCandidates(history).isEmpty, "income cannot become an expense rule candidate")
    }

    static func testExpenseReviewEdits() {
        let a = bankOp("quick-review-a", -10_000, description: "ОрбитаТест север")
        let b = bankOp("quick-review-b", -20_000, description: a.description)
        var history = SavedHistory()
        history.operations = [a, b]
        history.categoryOverrides = [a.identity: UncategorizedReview.otherExpenseID, b.identity: UncategorizedReview.otherExpenseID]
        let group = UncategorizedReview.groups(history)[0]
        let selected = history.categoryTree[0].categories[0].id
        let previous = ExpenseReviewUndo(history)
        let interval = DateInterval(start: BankDateParser.parse("2032-06-01T00:00:00Z")!, duration: 30 * 86400)
        let before = FinancialEngine.report(history.financialInputs, in: interval)
        require(ExpenseReviewEdits.apply(selected, to: group, history: &history), "quick review applies a category using the existing setters")
        require(history.expenseCategoryID(for: a) == selected && history.expenseCategoryID(for: b) == selected,
                "quick review resolves all group rows, even those with individual Misc overrides")
        require(UncategorizedReview.groups(history).isEmpty && previous.changed(in: history), "quick-reviewed payee leaves the list and can be undone")
        let after = FinancialEngine.report(history.financialInputs, in: interval)
        require(before.grossExpenseKopecks == after.grossExpenseKopecks && before.incomeKopecks == after.incomeKopecks,
                "quick category review preserves financial totals")
        let synced = bankOp("quick-review-synced", -500, description: "ДругойПолучательТест")
        history.operations.append(synced)
        history.incomeCategoryOverrides = ["new-income": "Зарплата и выплаты"]
        previous.restore(in: &history)
        require(history.categoryRules == previous.rules && history.categoryOverrides == previous.overrides,
                "undo restores exactly the previous expense category fields, including nil rules")
        require(history.operations == [a, b, synced] && history.incomeCategoryOverrides?["new-income"] == "Зарплата и выплаты",
                "undo leaves newly synced operations and other history fields intact")
        require(history.expenseCategoryID(for: a) == UncategorizedReview.otherExpenseID && UncategorizedReview.groups(history).count == 2,
                "undo returns reviewed expenses to Misc")
        let unnamed = bankOp("quick-review-empty", -100, description: "12345")
        let unnamed2 = bankOp("quick-review-empty-2", -100, description: "12345")
        history = SavedHistory()
        history.operations = [unnamed, unnamed2]
        require(ExpenseReviewEdits.apply(selected, to: UncategorizedReview.groups(history)[0], history: &history), "empty-key quick review is individual")
        require(history.categoryOverrides?.count == 1 && (history.categoryRules ?? []).isEmpty && UncategorizedReview.groups(history).count == 1,
                "empty-key review does not create a payee rule or affect its unnamed neighbour")
        let savedOverrides = history.categoryOverrides
        let badGroup = ReviewGroup(id: "quick-invalid", key: "", kind: .expense,
                                   operations: [unnamed2, bankOp("quick-income", 100, description: "ПоступлениеТест", kind: "income")])
        require(!ExpenseReviewEdits.apply(selected, to: badGroup, history: &history) && history.categoryOverrides == savedOverrides,
                "a rejected batch makes no partial category edits")
    }

    static func testManualExpenseReviewUndo() {
        let day = BankDateParser.parse("2032-06-02T10:00:00Z")!
        let manual = ManualOperation(kind: .expense, amountKopecks: 10_000, date: day, accountID: UUID(),
                                     group: "Другое", subcategory: "Прочее", note: "КафеТест ручная покупка")
        let neighbour = ManualOperation(kind: .expense, amountKopecks: 5_000, date: day, accountID: nil,
                                        group: "Другое", subcategory: "Прочее", note: manual.note)
        var history = SavedHistory()
        history.manualOperations = [manual, neighbour]
        let bank = bankOp("manual-review-bank", -700, description: "МагазинТест банковский", mcc: "5411")
        history.operations = [bank]
        let cafe = history.categoryTree.first { $0.name == "Еда" }!.categories.first { $0.name == "Кафе и рестораны" }!.id
        history.categoryRules = [CategoryRule(payeeKey: FinancialEngine.payeeRuleKey(bank.description),
                                               title: bank.description, categoryID: cafe)]
        history.categoryOverrides = [bank.identity: cafe]
        let group = UncategorizedReview.groups(history).first { $0.operations[0].manualID == manual.id }!
        let options = CategorySuggestions.suggest(for: group, history: history)
        require(!group.appliesToAll && options.first?.categoryID == cafe, "manual expense receives a word suggestion and stays individual")
        let previous = ExpenseReviewUndo(history, operation: manual.bankOperation)
        require(previous.manualCategory?.operationID == manual.id && previous.manualCategory?.categoryID == UncategorizedReview.otherExpenseID,
                "manual undo captures only the record id and former category")
        let interval = DateInterval(start: BankDateParser.parse("2032-06-01T00:00:00Z")!, duration: 30 * 86400)
        let before = FinancialEngine.report(history.financialInputs, in: interval)
        require(ExpenseReviewEdits.apply(cafe, to: group, history: &history) && previous.changed(in: history),
                "manual quick review applies its suggestion and offers undo")
        require(history.manualOperations?[0].subcategory == "Кафе и рестораны" && history.manualOperations?[1] == neighbour,
                "manual quick review changes only the selected expense, even for the same payee")
        require(history.categoryRules == previous.rules && history.categoryOverrides == previous.overrides,
                "manual quick review does not create a bank rule or an override")
        let after = FinancialEngine.report(history.financialInputs, in: interval)
        require(before.grossExpenseKopecks == after.grossExpenseKopecks && before.incomeKopecks == after.incomeKopecks,
                "manual quick review preserves income and expense totals")

        // Other edits and bank sync may arrive during the undo window.
        history.manualOperations?[0].amountKopecks = 31_400
        history.manualOperations?[0].date = day.addingTimeInterval(3600)
        history.manualOperations?[0].accountID = UUID()
        history.manualOperations?[0].note = "КафеТест новый комментарий"
        require(history.setExpenseCategory(cafe, for: neighbour.bankOperation, forPayee: false), "manual undo fixture edits a neighbouring expense")
        let addedIncome = ManualOperation(kind: .income, amountKopecks: 8_000, date: day, accountID: nil,
                                         group: nil, subcategory: "Зарплата и выплаты", note: "ПоступлениеТест")
        history.manualOperations?.append(addedIncome)
        let synced = bankOp("manual-review-synced", -900, description: "ПолучательТест новый")
        history.operations.append(synced)
        history.incomeCategoryOverrides = ["manual-review-income": "Зарплата и выплаты"]
        var expected = history.manualOperations!
        expected[0].group = "Другое"
        expected[0].subcategory = "Прочее"
        let beforeUndo = FinancialEngine.report(history.financialInputs, in: interval)
        require(previous.restore(in: &history), "manual undo restores the former category through the existing setter")
        require(history.manualOperations == expected,
                "manual undo preserves the current amount, date, account, comment, neighbouring category and added entry")
        require(history.operations == [bank, synced] && history.incomeCategoryOverrides?["manual-review-income"] == "Зарплата и выплаты",
                "manual undo preserves newly synced bank data and income choices")
        let undone = FinancialEngine.report(history.financialInputs, in: interval)
        require(beforeUndo.grossExpenseKopecks == undone.grossExpenseKopecks && beforeUndo.incomeKopecks == undone.incomeKopecks,
                "manual undo changes no financial totals")

        var removed = history
        removed.manualOperations?.removeAll { $0.id == manual.id }
        removed.categoryOverrides?["later-choice"] = cafe
        let remaining = removed.manualOperations
        let laterOverrides = removed.categoryOverrides
        require(!previous.restore(in: &removed) && removed.manualOperations == remaining && removed.categoryOverrides == laterOverrides,
                "manual undo never recreates a deleted record or partially restores category settings")
        var changedKind = history
        changedKind.manualOperations?[0].kind = .income
        let currentEntries = changedKind.manualOperations
        require(!previous.restore(in: &changedKind) && changedKind.manualOperations == currentEntries,
                "manual undo cannot change an operation's newly edited financial type")
        require(history.renameExpenseCategory(UncategorizedReview.otherExpenseID, to: "РазобратьТест"), "manual undo fixture renames the old category")
        require(history.setExpenseCategory(cafe, for: history.manualOperations![0].bankOperation, forPayee: false), "manual undo fixture selects another category")
        require(previous.restore(in: &history) && history.manualOperations?[0].subcategory == "РазобратьТест",
                "manual undo uses the stable category id and respects a category rename")
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

        // Filter: whole categories and payees stay out of the structure, the dynamics and the flow
        let withoutFood = ReportFilter(excludedGroups: ["Еда"])
        require(withoutFood.isActive && !ReportFilter.none.isActive, "an empty filter is not active")
        require(ReportEngine.slices(inputs, in: september, mode: .expenses, grouping: .categories, taxonomy: taxonomy, filter: withoutFood).map(\.title) == ["Транспорт"],
                "an excluded category is out of the structure")
        require(ReportEngine.slices(inputs, in: september, mode: .expenses, grouping: .categories, taxonomy: taxonomy, filter: .none) == slices, "no filter, same result")
        let noShop = ReportFilter(excludedPayees: [FinancialEngine.payeeRuleKey("Пятёрочка")])
        require(ReportEngine.slices(inputs, in: september, mode: .expenses, grouping: .payees, taxonomy: taxonomy, filter: noShop).map(\.title).contains("Пятёрочка") == false,
                "an excluded payee is out of the structure")
        let filteredBars = ReportEngine.bars(inputs, buckets: days, mode: .expenses, grouping: .categories, filter: withoutFood)
        require(filteredBars.map(\.label) == ["Транспорт"], "an excluded category is out of the bars")
        let filteredFlow = ReportEngine.flow(inputs, buckets: weeks, filter: withoutFood)
        require(filteredFlow.reduce(0) { $0 + $1.expenseKopecks } == 15_000 && filteredFlow.reduce(0) { $0 + $1.incomeKopecks } == 200_000,
                "with a filter the flow is the plain sum of allowed expenses and income")
        require(ReportEngine.flow(inputs, buckets: weeks, filter: ReportFilter(excludedGroups: [income[0].title])).reduce(0) { $0 + $1.incomeKopecks } == 0,
                "an excluded income category is out of the flow")
        // The list behind a row follows the same filter as its sum
        let slicesSum = ReportEngine.slices(inputs, in: september, mode: .expenses, grouping: .categories, taxonomy: taxonomy, filter: withoutFood)
            .reduce(Int64(0)) { $0 + $1.amountKopecks }
        let allowedInMonth = inputs.filter { input in
            guard let when = BankDateParser.parse(input.occurredAt), when >= september.start, when < september.end else { return false }
            return ReportEngine.isAllowed(input, by: withoutFood)
        }.reduce(Int64(0)) { $0 + FinancialEngine.classify($1).expenseContributionKopecks }
        require(allowedInMonth == slicesSum, "the operations behind «Все расходы» add up to the filtered structure")
        let shopOnly = inputs.filter { ReportEngine.isAllowed($0, by: noShop) && FinancialEngine.classify($0).type == .expense && $0.description == "Пятёрочка" }
        require(shopOnly.isEmpty, "an excluded payee is not in the list either")
        require(inputs.allSatisfy { ReportEngine.isAllowed($0, by: .none) }, "without a filter every operation is allowed")
        require(ReportEngine.isAllowed(op(5_000, kind: "refund", category: "Возврат", description: "Возврат Пятёрочка", date: iso(9, 5)), by: withoutFood),
                "refunds are not filtered by category")
        require(withoutFood.cacheKey != ReportFilter.none.cacheKey && ReportFilter(excludedGroups: ["Еда"]).cacheKey == withoutFood.cacheKey, "the cache key follows the filter")

        // Balances
        let start = day(8, 1)
        let cash = Account(name: "Наличные", icon: "banknote", color: "green", startBalanceKopecks: 100_000, startDate: start)
        var history = SavedHistory()
        history.accounts = [cash]
        history.manualOperations = [
            ManualOperation(kind: .expense, amountKopecks: 10_000, date: day(9, 3), accountID: cash.id, group: "Еда", subcategory: "Кафе и рестораны"),
            ManualOperation(kind: .income, amountKopecks: 5_000, date: day(9, 12), accountID: cash.id, subcategory: "Прочие доходы"),
        ]
        let later = day(12, 1)
        let points = ReportEngine.balances(history, accounts: [cash], buckets: weeks, now: later, calendar: calendar)
        require(points.map(\.totalKopecks) == [90_000, 95_000, 95_000, 95_000, 95_000], "the balance at the end of every week")
        require(points.allSatisfy { $0.hasData && !$0.isForecast }, "past weeks are facts")
        require(points.last?.totalKopecks == cash.balance(bankOperations: [], manual: history.manualOperations ?? []), "the last point is the current balance")
        require(ReportEngine.balances(history, accounts: [], buckets: weeks, now: later, calendar: calendar).allSatisfy { $0.totalKopecks == 0 && !$0.hasData },
                "no accounts, no balance")

        // The past is worked back through the card; days to come are a forecast
        let cardStart = day(9, 10)
        let card = Account(name: "Карта", icon: "creditcard", color: "yellow", startBalanceKopecks: 100_000, startDate: cardStart, tracksBankCard: true)
        var cardHistory = SavedHistory()
        cardHistory.accounts = [card]
        cardHistory.operations = [
            bankOp("b1", -10_000, description: "Магазин", mcc: "5411", date: iso(9, 2)),
            bankOp("b2", -5_000, description: "Магазин", mcc: "5411", date: iso(9, 5)),
            bankOp("b3", 20_000, description: "Магазин", mcc: "5411", date: iso(9, 12)),
        ]
        let pastMoments = [day(9, 1), day(9, 2), day(9, 3), day(9, 5), day(9, 10), day(9, 13)]
        require(cardHistory.accountBalancesReconstructed(card, at: pastMoments) == [nil, nil, 105_000, 105_000, 100_000, 120_000],
                "before the first operation nothing is known; before the start date the balance is worked back")
        let byHand = Account(name: "Наличные", icon: "banknote", color: "green", startBalanceKopecks: 7_000, startDate: day(9, 15))
        require(SavedHistory().accountBalancesReconstructed(byHand, at: [day(9, 14), day(9, 16)]) == [nil, 7_000], "an account kept by hand has no past before its start")
        let nowForecast = day(9, 20)
        let forecastBuckets = [day(9, 20), day(9, 25), day(9, 30)].map { DateInterval(start: $0, end: calendar.date(byAdding: .day, value: 1, to: $0)!) }
        var cashHistory = SavedHistory()
        cashHistory.accounts = [cash]
        cashHistory.manualOperations = history.manualOperations
        let withForecast = ReportEngine.balances(cashHistory, accounts: [cash], buckets: forecastBuckets, now: nowForecast,
                                                 forecastChangeKopecks: -40_000, calendar: calendar)
        require(withForecast.map(\.totalKopecks) == [95_000, 75_000, 55_000], "today is a fact, then a straight line to the expected end of the month")
        require(withForecast.map(\.isForecast) == [false, true, true], "days after today are marked as a forecast")
        let noForecast = ReportEngine.balances(cashHistory, accounts: [cash], buckets: forecastBuckets, now: nowForecast, calendar: calendar)
        require(noForecast.map(\.hasData) == [true, false, false], "without a forecast the days to come have no data")
        let young = Account(name: "Новый", icon: "banknote", color: "blue", startBalanceKopecks: 3_000, startDate: day(9, 15))
        cashHistory.accounts = [cash, young]
        let mixed = ReportEngine.balances(cashHistory, accounts: [cash, young], buckets: [DateInterval(start: day(9, 10), end: day(9, 11))],
                                          now: nowForecast, calendar: calendar)
        require(mixed[0].hasData == false && mixed[0].byAccount[cash.id] == 90_000 && mixed[0].byAccount[young.id] == nil,
                "the total is known only where every account is known; each account keeps its own known balance")
        let tail = (19...23).map { DateInterval(start: day(9, $0), end: day(9, $0 + 1)) }
        require(ReportEngine.untilToday(tail, now: nowForecast, calendar: calendar).count == 2, "days to come are not shown in income and expenses")
    }

    // MARK: Stage 49 audit (synthetic fixtures only)

    static func testAuditReportBoundaries() {
        let start = BankDateParser.parse("2032-02-29T00:00:00Z")!
        let interval = DateInterval(start: start, end: start.addingTimeInterval(86400))
        let inputs = [
            op(-1_000_000_000_000, kind: "expense", date: "2032-02-29T03:00:00+03:00"),
            op(400, kind: "refund", date: "2032-02-29T23:59:59.999Z"),
            op(-700, kind: "expense", date: "2032-03-01T00:00:00Z"),
            op(900, kind: "income", date: "2032-02-28T23:59:59Z"),
            op(-800, kind: "expense", date: "damaged-date"),
            op(0, kind: "income", date: "2032-02-29T12:00:00Z")
        ]
        let report = FinancialEngine.report(inputs, in: interval)
        let summary = FinancialEngine.summarize(inputs, in: interval)
        require(report.operationCount == 3 && report.invalidDateCount == 1, "audit: leap-day report uses half-open absolute date boundaries")
        require(report.grossExpenseKopecks == 1_000_000_000_000 && report.refundsKopecks == 400 && report.incomeKopecks == 0,
                "audit: a large exact amount, refund and zero do not acquire rounding or boundary income")
        require(summary.netExpenseKopecks == 999_999_999_600 && summary.operationCount == 3 && summary.invalidDateCount == 1,
                "audit: summary agrees with report at large amounts and invalid dates")
        let reversed = FinancialEngine.report(Array(inputs.reversed()), in: interval)
        require(reversed.netExpenseKopecks == report.netExpenseKopecks && reversed.bankDebitKopecks == report.bankDebitKopecks,
                "audit: financial totals do not depend on input order")
        let empty = FinancialEngine.report([], in: interval)
        require(empty.operationCount == 0 && empty.netExpenseKopecks == 0 && empty.incomeLines.isEmpty && empty.expenseLines.isEmpty,
                "audit: empty history has no invented totals or lines")
        let refund = FinancialEngine.report([inputs[1]], in: interval)
        require(refund.netExpenseKopecks == -400 && refund.incomeKopecks == 0, "audit: a refund-only period has negative net expense, no income")
    }

    static func testAuditCalendarTransitions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for (iso, expectedHours) in [("2024-03-10T16:00:00Z", 23.0), ("2024-11-03T17:00:00Z", 25.0)] {
            let now = BankDateParser.parse(iso)!
            let interval = ReportPeriod.lastDays(1).interval(now: now, calendar: calendar)
            require(interval.duration == expectedHours * 3600, "audit: a local report day follows DST rather than fixed 86400 seconds")
            let buckets = ReportEngine.buckets(interval, step: .day, calendar: calendar)
            require(buckets == [interval], "audit: DST day is covered exactly once")
            require(ReportPeriod.lastDays(0).interval(now: now, calendar: calendar) == interval,
                    "audit: an invalid zero-day request safely becomes one day")
        }
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let leap = BankDateParser.parse("2032-02-29T12:00:00Z")!
        let month = ReportPeriod.month(leap).interval(now: leap, calendar: calendar)
        let buckets = ReportEngine.buckets(month, step: .day, calendar: calendar)
        require(buckets.count == 29 && buckets.first?.start == month.start && buckets.last?.end == month.end,
                "audit: all leap-February days are present")
        require(zip(buckets, buckets.dropFirst()).allSatisfy { $0.end == $1.start }, "audit: leap-day buckets have no gaps or overlap")
        let same = ReportPeriod.custom(from: leap, through: leap).interval(now: leap, calendar: calendar)
        require(same.duration == 86400 && same.start == calendar.startOfDay(for: leap), "audit: identical custom dates mean one complete day")
        let zero = DateInterval(start: leap, end: leap)
        require(ReportEngine.buckets(zero, step: .day, calendar: calendar).isEmpty, "audit: a zero-length interval creates no buckets")
    }

    static func testAuditReportFilterAndEmptyFlow() {
        let first = BankDateParser.parse("2032-06-01T00:00:00Z")!
        let interval = DateInterval(start: first, end: first.addingTimeInterval(86400))
        let refund = op(800, kind: "refund", date: "2032-06-01T10:00:00Z")
        require(ReportEngine.flow([refund], buckets: [interval]).first?.expenseKopecks == -800,
                "audit: the unfiltered flow retains refund-only net expense")
        require(ReportEngine.flow([], buckets: [interval]).first?.expenseKopecks == 0,
                "audit: empty flow retains the selected bucket")
        require(ReportEngine.slices([], in: interval, mode: .income, grouping: .payees, taxonomy: .builtin).isEmpty,
                "audit: empty income structure has no placeholder payee")
        require(ReportEngine.totals([], buckets: [interval]) == [0], "audit: an empty dynamics bucket has zero total")
        let filter = ReportFilter(excludedGroups: ["Еда"], excludedPayees: ["—"])
        require(!filter.allows(group: "Еда", payee: "audit shop") && !filter.allows(group: "Транспорт", payee: ""),
                "audit: category and unnamed-payee exclusions are both respected")
        require(filter.allows(group: "Транспорт", payee: "audit shop"), "audit: a filter leaves unrelated operations visible")
        require(ReportFilter(excludedGroups: ["A", "B"]).cacheKey == ReportFilter(excludedGroups: ["B", "A"]).cacheKey,
                "audit: set order does not change a normal filter key")
    }

    static func testAuditAccountMoments() {
        let start = BankDateParser.parse("2032-06-01T00:00:00Z")!
        let at = start.addingTimeInterval(86400)
        let account = Account(name: "Audit cash", icon: "banknote", color: "green", startBalanceKopecks: 500, startDate: start)
        var history = SavedHistory()
        history.accounts = [account]
        history.manualOperations = [
            ManualOperation(kind: .expense, amountKopecks: 200, date: at, accountID: account.id),
            ManualOperation(kind: .transfer, amountKopecks: 900, date: at, accountID: account.id, toAccountID: account.id),
            ManualOperation(kind: .income, amountKopecks: 100, date: start.addingTimeInterval(-1), accountID: account.id)
        ]
        let moments = [at.addingTimeInterval(1), start, at, at.addingTimeInterval(1)]
        require(history.accountBalances(account, at: moments) == [300, 500, 500, 300],
                "audit: arbitrary repeated moments preserve order and exclude the exact endpoint")
        require(history.accountBalancesReconstructed(account, at: [start.addingTimeInterval(-1), start, at.addingTimeInterval(1)]) == [nil, 500, 300],
                "audit: manual accounts do not invent a balance before their anchor")
        require(history.accountBalances(account, at: []).isEmpty, "audit: no requested balance moments, no results")
        require(account.balance(bankOperations: [], manual: history.manualOperations!) == 300,
                "audit: a transfer to the same account is neutral; pre-anchor entries do not change its starting balance")
        let transfer = history.manualOperations![1].bankOperation.financialAssessment
        require(transfer.expenseContributionKopecks == 0 && transfer.incomeContributionKopecks == 0,
                "audit: same-account transfer cannot create report income or expense")
    }

    static func testAuditBackupAndReceiptReferences() throws {
        var history = SavedHistory()
        let entry = bankOp("audit-backup", -100, description: "AuditShop")
        history.operations = [entry]
        let file = ReceiptLogic.fileName(id: UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!)
        history.addReceipt(file, toIdentity: entry.identity)
        history.addReceipt(file, toIdentity: entry.identity)
        history.addReceipt("../outside.jpg", toIdentity: entry.identity)
        require(history.receiptFiles(forIdentity: entry.identity) == [file], "audit: duplicate or unsafe receipt references are ignored")
        history.operationNatures = [entry.identity: "future-unknown-nature"]
        history.categoryOverrides = [entry.identity: UncategorizedReview.otherExpenseID]
        let exported = BankDateParser.parse("2032-06-03T00:00:00Z")!
        let first = try HistoryBackup.encode(history, exportedAt: exported)
        let restored = try HistoryBackup.decode(first)
        let second = try HistoryBackup.encode(restored, exportedAt: exported)
        require(first == second, "audit: repeated backup round trips retain optional metadata exactly")
        require(restored.financialInputs[0].amountKopecks == -100, "audit: unrecognized future nature cannot alter an expense")
        var withoutPhotos = restored
        require(withoutPhotos.removeReceipts(forIdentity: entry.identity) == [file], "audit: removing receipt metadata returns only linked names")
        require(withoutPhotos.removeReceipts(forIdentity: entry.identity).isEmpty && withoutPhotos.receipts == nil,
                "audit: repeated receipt removal is harmless")
        for invalid in [Data(), Data("[]".utf8), Data(first.prefix(first.count / 2))] {
            do { _ = try HistoryBackup.decode(invalid); require(false, "audit: a damaged backup must be rejected") }
            catch { require(history.operations.count == 1 && history.hasReceipt(entry), "audit: decode errors leave the original history unchanged") }
        }
        let empty = try HistoryBackup.decode(HistoryBackup.encode(SavedHistory()))
        require(empty.operations.isEmpty && empty.accounts == nil && empty.manualOperations == nil,
                "audit: an empty backup retains absent optional collections")
    }

    static func testAuditReceiptParsingEdges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        require(ReceiptParser.kopecks(fromDecimal: "999999999.99") == 99_999_999_999, "audit: receipt amount at the supported upper bound is exact")
        for invalid in ["", "-1.00", "1.001", "1000000000.00", "1.2.3", "NaN", "١٢.٣٤"] {
            require(ReceiptParser.kopecks(fromDecimal: invalid) == nil, "audit: invalid or oversized decimal is not guessed")
        }
        require(ReceiptParser.amounts(in: "ИТОГО 1\u{00a0}234,56") == [123456], "audit: a nonbreaking thousands separator is recognized")
        require(ReceiptParser.total(in: ["НДС 20,00", "СДАЧА 100,00"]) == nil, "audit: tax and change alone never become a receipt total")
        require(ReceiptParser.parseText([]).isEmpty, "audit: no OCR lines produce no receipt fields")
        for date in ["20310229T1200", "20321301T1200", "20320229T2460"] {
            let parsed = ReceiptParser.parseQR("fn=123&t=\(date)&s=1.00", calendar: calendar)
            require(parsed?.date == nil && parsed?.totalKopecks == 100, "audit: an impossible QR date leaves the valid amount available")
        }
        require(ReceiptParser.parseQR("fn=123&t=20320229T1200&s=bad", calendar: calendar)?.totalKopecks == nil,
                "audit: invalid QR money does not become zero")
        require(ReceiptParser.parseQR("t=20320229T1200&s=1.00", calendar: calendar) == nil, "audit: a QR without a fiscal marker is not a receipt")
        let text = ParsedReceipt(totalKopecks: 500, date: nil, merchant: "AuditShop")
        let qr = ParsedReceipt(totalKopecks: nil, date: BankDateParser.parse("2032-02-29T12:00:00Z"), merchant: nil)
        let merged = ReceiptParser.merge(qr: qr, text: text)
        require(merged.totalKopecks == 500 && merged.date == qr.date && merged.merchant == "AuditShop", "audit: partial QR data complements OCR without losing fields")
    }

    static func testAuditReceiptArchiveCorruption() {
        require(ReceiptArchive.crc32(Data()) == 0, "audit: empty payload has the standard zero CRC")
        let name = "audit.bin", payload = Data([1, 2, 3, 4])
        let zip = ReceiptArchive.make([(name, payload)])
        var damaged = zip
        damaged[30 + name.utf8.count] ^= 0xff
        require(ReceiptArchive.read(damaged) == nil, "audit: modified photo bytes fail CRC validation")
        var compressed = zip
        compressed[8] = 8
        require(ReceiptArchive.read(compressed) == nil, "audit: an unsupported compressed archive is rejected")
        var descriptor = zip
        descriptor[6] |= 8
        require(ReceiptArchive.read(descriptor) == nil, "audit: an unsupported data descriptor is rejected")
        var unsafeName = zip
        unsafeName[30] = 0xff
        require(ReceiptArchive.read(unsafeName) == nil, "audit: malformed UTF-8 filename is rejected")
        for size in [0, 1, 4, 21, 29, 30 + name.utf8.count + payload.count - 1] {
            require(ReceiptArchive.read(Data(zip.prefix(size))) == nil, "audit: an incomplete local ZIP record is rejected")
        }
    }

    static func testAuditRegularPaymentsEdges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let last = BankDateParser.parse("2024-02-29T10:00:00Z")!
        let pattern = FinancialEngine.RecurringPattern(title: "AuditAnnual", isIncome: false, intervalDays: 365,
                                                      typicalAmountKopecks: 1_000_000_000_008, lastDate: last)
        let now = BankDateParser.parse("2028-02-01T12:00:00Z")!
        require(RegularPayments.nextDate(of: pattern, now: now, calendar: calendar) == BankDateParser.parse("2028-02-29T10:00:00Z"),
                "audit: an annual leap-day payment returns to February 29 in a leap year")
        require(RegularPayments.monthlyKopecks(of: pattern) == 83_333_333_334, "audit: a large annual estimate is rounded once in decimal arithmetic")
        let zero = FinancialEngine.RecurringPattern(title: "AuditZero", isIncome: true, intervalDays: 0, typicalAmountKopecks: 0, lastDate: last)
        require(RegularPayments.monthlyKopecks(of: zero) == 0 && RegularPayments.nextDate(of: zero, now: last, calendar: calendar) > last,
                "audit: a malformed zero interval cannot divide by zero or loop without advancing")
        require(FinancialEngine.recurringPatterns([], now: now, calendar: calendar).isEmpty, "audit: empty history creates no regular payments")
        let emptyForecast = FinancialEngine.monthForecast([], now: now, calendar: calendar)
        require(emptyForecast.spentKopecks == 0 && emptyForecast.incomeKopecks == 0 && emptyForecast.projectedExpenseKopecks == 0 &&
                emptyForecast.historyMonths == 0 && emptyForecast.upcoming.isEmpty && emptyForecast.daysInMonth == 29,
                "audit: empty history creates no spending, baseline or payments, and keeps the leap-month length")
    }

    static func testAuditSuggestionsAndLockEdges() {
        var history = SavedHistory()
        require(CategorySuggestions.suggestions(for: [], history: history).isEmpty && CategorySuggestions.ruleCandidates(history).isEmpty,
                "audit: an empty history creates no category suggestions or rules")
        let target = bankOp("audit-suggestion", -100, description: "AuditShop")
        history.operations = [target]
        history.categoryOverrides = [target.identity: UUID()]
        let group = ReviewGroup(id: "audit-group", key: FinancialEngine.payeeRuleKey(target.description), kind: .expense, operations: [target])
        require(CategorySuggestions.suggest(for: group, history: history).isEmpty, "audit: a deleted category cannot become suggestion evidence")
        require(history.operations[0].amountKopecks == -100 && history.categoryOverrides?.count == 1,
                "audit: computing suggestions cannot mutate history or erase stale metadata")
        require(AppLockLogic.lockoutSeconds(afterFailures: Int.min) == 0 && AppLockLogic.lockoutSeconds(afterFailures: Int.max) == 900,
                "audit: extreme failure counts have bounded lockout")
        let at = Date(timeIntervalSince1970: 1000)
        require(!AppLockLogic.shouldLock(backgroundedAt: at, now: at.addingTimeInterval(59.999), afterSeconds: 60), "audit: lock timeout does not round up")
        require(AppLockLogic.shouldLock(backgroundedAt: at, now: at.addingTimeInterval(60), afterSeconds: 60), "audit: lock activates at the exact timeout")
        require(AppLockLogic.shouldLock(backgroundedAt: at, now: at.addingTimeInterval(-0.001), afterSeconds: 60), "audit: even a small clock rollback locks the app")
        for bad in ["0000\n", "\u{200b}0000", "00\u{00a0}0", "００００"] {
            require(!AppLockLogic.isValid(pin: bad), "audit: invisible characters and full-width digits are not a PIN")
        }
    }

    /// Reproductions intentionally excluded from main: stage 49 must not change application logic.
    static func testKnownIssues() {
        testKnownIssueArchiveTruncation()
        testKnownIssueFilterKeyCollision()
        testKnownIssuePayeeSeries()
        testKnownIssueReceiptQRSeconds()
        testKnownIssueMinimumAmount()
        testKnownIssueBackupAnchorPrecision()
    }

    static func testKnownIssueArchiveTruncation() {
        let name = "audit-first.bin", payload = Data([1, 2, 3])
        let zip = ReceiptArchive.make([(name, payload), ("audit-second.bin", Data([4, 5]))])
        let cut = Data(zip.prefix(30 + name.utf8.count + payload.count))
        require(ReceiptArchive.read(cut) == nil, "known issue: a truncated archive must not silently restore only its first photo")
    }

    static func testKnownIssueFilterKeyCollision() {
        let one = ReportFilter(excludedGroups: ["AuditA|AuditB"])
        let two = ReportFilter(excludedGroups: ["AuditA", "AuditB"])
        require(one != two && one.cacheKey != two.cacheKey, "known issue: distinct valid category filters need distinct cache keys")
    }

    static func testKnownIssuePayeeSeries() {
        let start = BankDateParser.parse("2032-06-01T00:00:00Z")!
        let interval = DateInterval(start: start, end: start.addingTimeInterval(86400))
        let inputs = [op(-100, kind: "expense", description: "AuditShop 001", date: "2032-06-01T10:00:00Z"),
                      op(-200, kind: "expense", description: "AuditShop 002", date: "2032-06-01T11:00:00Z")]
        let slices = ReportEngine.slices(inputs, in: interval, mode: .expenses, grouping: .payees, taxonomy: .builtin)
        let bars = ReportEngine.bars(inputs, buckets: [interval], mode: .expenses, grouping: .payees, focus: slices.first?.id)
        require(slices.count == 1 && bars.count == 1 && bars.first?.amountKopecks == 300,
                "known issue: a focused normalized payee must remain one dynamics series")
    }

    static func testKnownIssueReceiptQRSeconds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parsed = ReceiptParser.parseQR("fn=123&t=20320229T120159&s=1.00", calendar: calendar)
        require(parsed?.date == BankDateParser.parse("2032-02-29T12:01:59Z"), "known issue: an exact QR date must retain its seconds")
    }

    static func testKnownIssueMinimumAmount() {
        require(FinancialEngine.classify(op(Int64.min, kind: "expense")).type == .unknown,
                "known issue: an unrepresentable positive expense magnitude must be rejected safely instead of trapping")
    }

    static func testKnownIssueBackupAnchorPrecision() {
        let anchor = BankDateParser.parse("2032-06-01T10:00:00.900Z")!
        let account = Account(name: "Audit card", icon: "creditcard", color: "blue", startBalanceKopecks: 1_000,
                              startDate: anchor, tracksBankCard: true)
        var original = SavedHistory()
        original.accounts = [account]
        original.operations = [bankOp("audit-before-anchor", -100, description: "AuditShop", date: "2032-06-01T10:00:00.500Z")]
        do {
            let restored = try HistoryBackup.decode(HistoryBackup.encode(original))
            guard let restoredAccount = restored.accounts?.first else { require(false, "known issue: backup lost its account"); return }
            let before = original.accountBalances(account, at: [.distantFuture])
            let after = restored.accountBalances(restoredAccount, at: [.distantFuture])
            require(before == after && restoredAccount.startDate == anchor,
                    "known issue: a backup must preserve the precise balance anchor and not count a pre-anchor expense again")
        } catch { require(false, "known issue: the synthetic backup unexpectedly failed to decode") }
    }

    static func testAudit50ReceiptResults() {
        typealias Result = ReceiptLogic.ReceiptRestoreResult
        require(Result().message == "В архиве нет фото чеков", "audit50: empty archive is not an added-photo success")
        require(Result(added: 3).message == "Добавлено 3 фото", "audit50: all new photos")
        require(Result(alreadyExisted: 5).message == "Все 5 фото уже были", "audit50: all duplicates")
        require(Result(added: 2, alreadyExisted: 1, damaged: 1).message == "Добавлено 2, уже было 1, не удалось прочитать 1",
                "audit50: partial restore names every nonzero outcome")
        require(Result(damaged: 2).message == "Не удалось прочитать 2", "audit50: damaged-only is an error")
        require(Result(notWritten: 1).message == "Не удалось записать 1", "audit50: failed-only is an error")
        require(Result(damaged: 1, notWritten: 2).message == "Не удалось прочитать 1, не удалось записать 2", "audit50: no success when nothing restored")
        require(Result(added: 1, alreadyExisted: 2, damaged: 3, notWritten: 4).message ==
                "Добавлено 1, уже было 2, не удалось прочитать 3, не удалось записать 4", "audit50: all result fields")
        require(Result(added: 2, notWritten: 1).message == "Добавлено 2, не удалось записать 1", "audit50: zero fields omitted")
        require(Result(alreadyExisted: 2, damaged: 1).message == "Уже было 2, не удалось прочитать 1", "audit50: duplicate plus error is not all-existing success")
        require(ReceiptLogic.exportMessage(saved: 3, skipped: 0) == "Архив сохранён: 3 фото.", "audit50: complete export")
        require(ReceiptLogic.exportMessage(saved: 3, skipped: 2) == "Архив сохранён: 3 фото. Пропущено: 2 (не удалось прочитать).",
                "audit50: export reports skipped files")
        require(ReceiptLogic.exportMessage(saved: 0, skipped: 2) == "Не удалось прочитать 2 фото. Архив не сохранён.", "audit50: failed export is not no-photos success")
        require(ReceiptLogic.exportMessage(saved: 0, skipped: 0) == "Фото чеков на этом телефоне пока нет.", "audit50: no export photos")
    }

    static func testAudit50BudgetMonthBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 6 * 3600)!
        for (year, month, days) in [(2031, 2, 28), (2032, 2, 29), (2032, 4, 30), (2032, 12, 31)] {
            let start = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
            let interval = BudgetEngine.monthInterval(containing: start, calendar: calendar)
            require(calendar.dateComponents([.day], from: interval.start, to: interval.end).day == days,
                    "audit50: budget month has the actual calendar length")
            let dates = [start.addingTimeInterval(-1), start, interval.end.addingTimeInterval(-1), interval.end]
            let inputs = dates.enumerated().map { index, date -> FinancialOperationInput in
                var input = op(-Int64(index + 1) * 100, kind: "expense", description: "Audit market",
                               date: date.formatted(.iso8601))
                input.categoryPath = "Еда/Супермаркеты"
                return input
            }
            let statuses = BudgetEngine.statuses(inputs: inputs, budgets: [Budget(group: nil, limitKopecks: 1_000)],
                                                  month: start, taxonomy: .builtin, calendar: calendar)
            require(statuses.first?.spentKopecks == 500, "audit50: first and last second count, adjacent months do not")
        }
    }

    static func testAudit50BudgetMutationAndFallback() {
        var history = SavedHistory()
        require(history.setBudget(group: "Audit missing group", limitKopecks: 1_000, month: nil), "audit50: general limit")
        let id = history.budgets!.first!.id
        for amount in [1_000, 1_500, 1_500] {
            require(history.setBudget(group: "Audit missing group", limitKopecks: Int64(amount), month: nil), "audit50: repeated set")
        }
        require(history.budgets?.count == 1 && history.budgets?.first?.id == id, "audit50: set keeps identity, no duplicates")
        require(history.setBudget(group: "Audit missing group", limitKopecks: 2_000, month: "2032-02"), "audit50: month-only limit")
        require(BudgetEngine.limit(history.budgets!, group: "Audit missing group", monthKey: "2032-02")?.isMonthOnly == true,
                "audit50: month-only overrides general")
        history.removeBudget(group: "Audit missing group", month: "2032-02")
        require(BudgetEngine.limit(history.budgets!, group: "Audit missing group", monthKey: "2032-02")?.limitKopecks == 1_500,
                "audit50: removing month-only restores general")
        history.removeBudget(group: "Audit absent", month: nil)
        let statuses = BudgetEngine.statuses(inputs: [], budgets: history.budgets!, month: Date(timeIntervalSince1970: 0), taxonomy: .builtin)
        require(statuses.count == 1 && statuses[0].spentKopecks == 0, "audit50: a removed tree group keeps a zero-spent limit")
        history.removeBudget(group: "Audit missing group", month: nil)
        history.removeBudget(group: "Audit missing group", month: nil)
        require(history.budgets == nil, "audit50: removing last limit repeatedly leaves nil")
    }

    static func testAudit50BudgetRefundsAndFutureDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let month = BankDateParser.parse("2032-06-10T12:00:00Z")!
        var purchase = op(-100, kind: "expense", description: "Audit market", date: "2032-06-02T10:00:00Z")
        purchase.categoryPath = "Еда/Супермаркеты"
        var future = purchase
        future = op(-200, kind: "expense", description: "Audit future", date: "2032-06-29T10:00:00Z")
        future.categoryPath = purchase.categoryPath
        let refund = op(500, kind: "refund", description: "Audit refund", date: "2032-06-04T10:00:00Z")
        let own = op(-900, kind: "internal_transfer", description: "Audit own move", date: "2032-06-05T10:00:00Z")
        let zero = op(0, kind: "expense", date: "2032-06-05T10:00:00Z")
        let budgets = [Budget(group: nil, limitKopecks: 1_000), Budget(group: "Еда", limitKopecks: 1_000)]
        let statuses = BudgetEngine.statuses(inputs: [purchase, future, refund, own, zero], budgets: budgets,
                                              month: month, taxonomy: .builtin, calendar: calendar)
        require(statuses[0].spentKopecks == -200 && statuses[0].percent == 0 && statuses[0].level == .calm,
                "audit50: overall budget nets refunds, ignores own transfers and zero spending")
        require(statuses[1].spentKopecks == 300, "audit50: group budgets intentionally use gross purchases, including future dates in that month")
        let cancelled = BudgetEngine.statuses(inputs: [purchase, op(100, kind: "refund", date: "2032-06-04T10:00:00Z")],
                                               budgets: budgets, month: month, taxonomy: .builtin, calendar: calendar)
        require(cancelled[0].spentKopecks == 0 && cancelled[1].spentKopecks == 100, "audit50: zero net spending differs from gross group spending")
    }

    static func testAudit50BudgetNotices() {
        func status(_ group: String?, _ spent: Int64) -> BudgetStatus {
            BudgetStatus(group: group, limitKopecks: 100, spentKopecks: spent, isMonthOnly: false)
        }
        let notices = BudgetEngine.notices([status(nil, 200), status("Audit near A", 90), status("Audit over A", 101),
                                           status("Audit calm", 89), status("Audit near B", 100), status("Audit over B", 150)])
        require(notices.map(\.level) == [.exceeded, .warning], "audit50: exceeded precedes warning")
        require(notices.map(\.text) == ["Превышен бюджет: Audit over A, Audit over B", "Почти исчерпан бюджет: Audit near A, Audit near B"],
                "audit50: notices name only relevant groups in input order")
        require(BudgetEngine.notices([]).isEmpty && BudgetEngine.notices([status(nil, 100), status("Audit calm", -10)]).isEmpty,
                "audit50: overall bar and negative spending produce no category notice")
    }

    static func testAudit50AccountScopeWithFilters() {
        let date = BankDateParser.parse("2032-06-02T10:00:00Z")!
        let interval = BudgetEngine.monthInterval(containing: date)
        let group = AccountGroup(name: "Audit group")
        let cash = Account(name: "Audit cash", icon: "banknote", color: "green", groupID: group.id, startBalanceKopecks: 0, startDate: date)
        let other = Account(name: "Audit wallet", icon: "wallet.pass", color: "blue", startBalanceKopecks: 0, startDate: date)
        let resolved = ReportAccountChoice.group(group.id).resolve(accounts: [cash, other], groups: [group])
        require(resolved.accounts == [cash] && resolved.scope == .accounts([cash]), "audit50: one-member group equals its account scope")
        require(!ReportAccountChoice.account(UUID()).resolve(accounts: [cash], groups: []).isValid, "audit50: missing account falls back")
        var history = SavedHistory()
        history.accounts = [cash, other]
        history.manualOperations = [
            ManualOperation(kind: .expense, amountKopecks: 100, date: date, accountID: cash.id, group: "Еда", subcategory: "Супермаркеты"),
            ManualOperation(kind: .expense, amountKopecks: 200, date: date, accountID: cash.id, group: "Транспорт", subcategory: "Такси"),
            ManualOperation(kind: .expense, amountKopecks: 400, date: date, accountID: other.id, group: "Еда", subcategory: "Супермаркеты"),
            ManualOperation(kind: .expense, amountKopecks: 800, date: date, accountID: nil, group: "Еда", subcategory: "Супермаркеты"),
            ManualOperation(kind: .transfer, amountKopecks: 1_000, date: date, accountID: cash.id, toAccountID: other.id),
            ManualOperation(kind: .income, amountKopecks: 50, date: date, accountID: cash.id, subcategory: "Прочие доходы")
        ]
        let inputs = history.financialInputs
        require(inputs.contains { $0.accountID == ReportAccountScope.noAccount }, "audit50: accountless manual entry has distinct sentinel")
        let filter = ReportFilter(excludedGroups: ["Транспорт"], scope: resolved.scope)
        let slices = ReportEngine.slices(inputs, in: interval, mode: .expenses, grouping: .categories, taxonomy: .builtin, filter: filter)
        let bars = ReportEngine.bars(inputs, buckets: [interval], mode: .expenses, grouping: .categories, filter: filter)
        let flow = ReportEngine.flow(inputs, buckets: [interval], filter: filter)
        require(slices.reduce(0) { $0 + $1.amountKopecks } == 100 && bars.reduce(0) { $0 + $1.amountKopecks } == 100,
                "audit50: slices and bars combine account scope with category exclusions; transfers do not count")
        require(flow.first?.expenseKopecks == 100 && flow.first?.incomeKopecks == 50, "audit50: flow applies both dimensions")
        let excludedPayees = Set(inputs.filter { $0.accountID == cash.id && $0.amountKopecks == -100 }.map { FinancialEngine.payeeRuleKey($0.description) })
        let payeeFilter = ReportFilter(excludedGroups: ["Транспорт"], excludedPayees: excludedPayees, scope: resolved.scope)
        require(ReportEngine.slices(inputs, in: interval, mode: .expenses, grouping: .payees, taxonomy: .builtin, filter: payeeFilter).isEmpty,
                "audit50: payee exclusions are applied within account scope")
        let scopes: [ReportAccountScope] = [.all, .accounts([]), .accounts([cash]), .accounts([other]), .accounts([cash, other]),
                                            ReportAccountScope(accountIDs: [cash.id], includesBankCard: true)]
        require(Set(scopes.map(\.cacheKey)).count == scopes.count, "audit50: distinct sets and bank flag have distinct keys")
        require(ReportAccountScope.accounts([cash, other]).cacheKey == ReportAccountScope.accounts([other, cash, cash]).cacheKey,
                "audit50: scope key is stable across order and duplicates")
    }

    static func testAudit50HistoryPeriods() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 6 * 3600)!
        for text in ["2031-12-31T23:59:59+06:00", "2032-01-01T00:00:00+06:00", "2032-02-29T23:59:59+06:00"] {
            let now = BankDateParser.parse(text)!
            let period = HistoryPeriod.currentMonth(now: now, calendar: calendar)
            require(HistoryPeriod(storageText: period.storageText) == period, "audit50: month survives storage across year and leap day")
            let interval = historyInterval(period, now: now, calendar: calendar)
            require(calendar.component(.day, from: interval.start) == 1 && interval.end > now, "audit50: current month starts on first and includes today")
        }
        for days in [1, 3660] { require(HistoryPeriod(storageText: "days:\(days)") == .lastDays(days), "audit50: storage day bounds") }
        for text in ["days:3661", "days:-1", "days:9223372036854775808", "custom::0", "custom:0:inf", "all:"] {
            require(HistoryPeriod(storageText: text) == nil, "audit50: malformed and excessive storage values are rejected")
        }
        let reversed = HistoryPeriod.custom(from: Date(timeIntervalSince1970: 1), through: Date(timeIntervalSince1970: -1))
        require(HistoryPeriod(storageText: reversed.storageText) == reversed, "audit50: epoch boundary and reversed dates survive storage")
    }

    static func testAudit50BackupDates() throws {
        for fraction in ["100", "900", "999"] {
            let anchor = BankDateParser.parse("2032-06-01T10:00:00.\(fraction)Z")!
            var history = SavedHistory()
            history.accounts = [Account(name: "Audit precision", icon: "banknote", color: "blue", startBalanceKopecks: 0, startDate: anchor)]
            history.manualOperations = [ManualOperation(kind: .income, amountKopecks: 1, date: anchor, accountID: history.accounts![0].id)]
            let restored = try HistoryBackup.decode(HistoryBackup.encode(history, exportedAt: anchor))
            require(restored.accounts?.first?.startDate == anchor && restored.manualOperations?.first?.date == anchor,
                    "audit50: backup preserves 0.\(fraction) seconds in account and manual dates")
        }
        let old = Data(#"{"format":1,"exportedAt":"2032-06-01T10:00:00Z","history":{"operations":[]}}"#.utf8)
        let restoredOld = try HistoryBackup.decode(old)
        require(restoredOld.operations.isEmpty, "audit50: pre-fraction backup opens")
    }

    // Stage 50 failures are compiled but intentionally not run until Claude fixes the underlying code.
    static func testKnownIssues50() {
        testKnownIssue50BudgetLevelOverflow()
        testKnownIssue50BudgetPercentOverflow()
        testKnownIssue50BudgetRemainingOverflow()
    }

    static func testKnownIssue50BudgetLevelOverflow() {
        require(BudgetEngine.level(spent: Int64.max - 1, limit: Int64.max) == .warning,
                "known issue50: comparing the 90 percent threshold must not multiply into overflow")
    }

    static func testKnownIssue50BudgetPercentOverflow() {
        let status = BudgetStatus(group: nil, limitKopecks: Int64.max, spentKopecks: Int64.max, isMonthOnly: false)
        require(status.percent == 100, "known issue50: the percent of an exactly spent large limit must be 100 without overflow")
    }

    static func testBudgetLargestAmount() {
        var history = SavedHistory()
        require(!history.setBudget(group: nil, limitKopecks: BudgetEngine.largestAmount + 1, month: nil) && history.budgets == nil,
                "a limit beyond any real amount is refused")
        require(history.setBudget(group: nil, limitKopecks: BudgetEngine.largestAmount, month: nil), "the largest limit is accepted")
        let huge = BudgetStatus(group: nil, limitKopecks: BudgetEngine.largestAmount, spentKopecks: BudgetEngine.largestAmount, isMonthOnly: false)
        require(huge.percent == 100 && huge.level == .warning && huge.remainingKopecks == 0, "the largest figures do not overflow")
        require(BudgetEngine.level(spent: Int64.max, limit: Int64.min) == .calm, "a negative limit is no limit")
        require(BudgetEngine.level(spent: Int64.min, limit: Int64.max) == .calm, "refunds beyond any amount are not spending")
    }

    static func testKnownIssue50BudgetRemainingOverflow() {
        let status = BudgetStatus(group: nil, limitKopecks: Int64.max, spentKopecks: -1, isMonthOnly: false)
        require(status.remainingKopecks >= 0, "known issue50: a large limit with net refunds must not crash calculating remaining")
    }

    // MARK: - Stage 52: synthetic receipt layouts and deterministic printed-text noise

    struct Audit52Receipt {
        let id: String
        let title: String
        let lines: [String]
        let total: Int64
        let date: Date
        let merchant: String
        let goods: [ReceiptGood]
    }

    enum Audit52Noise: String, CaseIterable { case none, light, strong }

    struct Audit52Random {
        var state: UInt64
        mutating func number(_ limit: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 16) % UInt64(limit))
        }
    }

    static func audit52Calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func audit52Receipts() -> [Audit52Receipt] {
        let calendar = audit52Calendar()
        var fixtures: [Audit52Receipt] = []
        func add(_ id: String, _ title: String, _ merchant: String, _ body: [String],
                 _ total: Int64, _ goods: [ReceiptGood], electronic: Bool = false) {
            let day = fixtures.count + 1
            let date = calendar.date(from: DateComponents(year: 2032, month: 5, day: day, hour: 14, minute: 25))!
            let stamp = electronic ? [String(format: "Дата: 2032-05-%02d", day), "Время: 14:25"]
                                   : [String(format: "%02d.05.2032 14:25", day)]
            let lines = ["ООО «" + merchant + "»", "КАССОВЫЙ ЧЕК"] + stamp + body
            fixtures.append(Audit52Receipt(id: id, title: title, lines: lines, total: total, date: date, merchant: merchant, goods: goods))
        }
        add("discount-table", "Таблица: название и числа раздельно", "Магазин Астра Тест",
            ["ЦЕНА / ЦЕНА СО СКИДКОЙ / КОЛ-ВО / ИТОГ", "Молоко учебное", "70.00 59.00 2ШТ. 118.00",
             "Хлеб учебный", "50.00 46.50 1ШТ. 46.50", "ИТОГ БЕЗ СКИДОК 190.00", "ИТОГ 164.50"], 16_450,
            [ReceiptGood(name: "Молоко учебное", kopecks: 11_800), ReceiptGood(name: "Хлеб учебный", kopecks: 4_650)])
        add("inline", "Название, количество и сумма в строке", "Маркет Маяк Тест",
            ["Молоко 2 x 65.00 130.00", "Хлеб 1 x 45.50 45.50", "ИТОГО 175.50"], 17_550,
            [ReceiptGood(name: "Молоко", kopecks: 13_000), ReceiptGood(name: "Хлеб", kopecks: 4_550)])
        add("wrapped-name", "Название товара на двух строках", "Магазин Ирис Тест",
            ["ЦЕНА КОЛ-ВО СУММА", "Йогурт натуральный", "с ягодами 2 x 89.00 178.00", "ИТОГО 178.00"], 17_800,
            [ReceiptGood(name: "Йогурт натуральный с ягодами", kopecks: 17_800)])
        add("cafe", "Кафе: обслуживание и чаевые в счёте", "Кафе Кедр Тест",
            ["Кофе учебный 1 x 250.00 250.00", "Пирог учебный 1 x 320.00 320.00",
             "Обслуживание 57.00", "Чаевые 40.00", "ИТОГО 667.00"], 66_700,
            [ReceiptGood(name: "Кофе учебный", kopecks: 25_000), ReceiptGood(name: "Пирог учебный", kopecks: 32_000),
             ReceiptGood(name: "Обслуживание", kopecks: 5_700), ReceiptGood(name: "Чаевые", kopecks: 4_000)])
        add("fuel", "АЗС: литры, цена за литр и колонка", "АЗС Орбита Тест",
            ["Колонка: 3", "ЦЕНА КОЛ-ВО СУММА", "Бензин тестовый 95 20.00 л 55.50 1110.00", "ИТОГО 1110.00"], 111_000,
            [ReceiptGood(name: "Бензин тестовый 95", kopecks: 111_000)])
        add("pharmacy", "Аптека", "Аптека Лира Тест",
            ["Витамины тестовые 1 x 240.00 240.00", "Бинт учебный 2 x 35.00 70.00", "ИТОГО 310.00"], 31_000,
            [ReceiptGood(name: "Витамины тестовые", kopecks: 24_000), ReceiptGood(name: "Бинт учебный", kopecks: 7_000)])
        add("vat", "НДС по двум ставкам", "Магазин Парус Тест",
            ["Хлеб учебный 1 x 110.00 110.00", "Альбом учебный 1 x 240.00 240.00",
             "НДС 10% 10.00", "НДС 20% 40.00", "ИТОГО 350.00"], 35_000,
            [ReceiptGood(name: "Хлеб учебный", kopecks: 11_000), ReceiptGood(name: "Альбом учебный", kopecks: 24_000)])
        add("points-card", "Баллы как скидка и оплата картой", "Маркет Лотос Тест",
            ["ЦЕНА ЦЕНА СО СКИДКОЙ КОЛ-ВО ИТОГ", "Фрукты учебные", "450.00 350.00 1ШТ. 350.00",
             "Сыр учебный", "450.00 350.00 1ШТ. 350.00", "ИТОГ БЕЗ СКИДОК 900.00",
             "Списано баллов 200.00", "ИТОГ 700.00", "БЕЗНАЛИЧНЫМИ 700.00"], 70_000,
            [ReceiptGood(name: "Фрукты учебные", kopecks: 35_000), ReceiptGood(name: "Сыр учебный", kopecks: 35_000)])
        add("cash-change", "Наличные и сдача", "Магазин Роса Тест",
            ["Молоко 2 x 65.00 130.00", "Хлеб 1 x 45.50 45.50", "ИТОГО 175.50", "НАЛИЧНЫМИ 200.00", "СДАЧА 24.50"], 17_550,
            [ReceiptGood(name: "Молоко", kopecks: 13_000), ReceiptGood(name: "Хлеб", kopecks: 4_550)])
        add("return", "Возврат: положительный модуль суммы чека", "Магазин Вега Тест",
            ["ВОЗВРАТ ПРИХОДА", "Шарф учебный 1 x 200.00 200.00", "ИТОГО 200.00", "БЕЗНАЛИЧНЫМИ 200.00"], 20_000,
            [ReceiptGood(name: "Шарф учебный", kopecks: 20_000)])
        add("electronic", "Электронный чек: итог на следующей строке", "Магазин Цифра Тест",
            ["Книга учебная 1 x 300.00 300.00", "ИТОГ", "300.00"], 30_000,
            [ReceiptGood(name: "Книга учебная", kopecks: 30_000)], electronic: true)
        var longLines = ["ЦЕНА КОЛ-ВО ИТОГ"]
        var longGoods: [ReceiptGood] = []
        for index in 1...40 {
            let name = String(format: "Позиция тестовая %02d", index)
            let price = Int64(index * 137)
            let money = String(format: "%lld.%02lld", price / 100, price % 100)
            longLines.append(name + " 1 x " + money + " " + money)
            longGoods.append(ReceiptGood(name: name, kopecks: price))
        }
        let longTotal = longGoods.reduce(Int64(0)) { $0 + $1.kopecks! }
        longLines.append(String(format: "ИТОГО %lld.%02lld", longTotal / 100, longTotal % 100))
        add("long-40", "Длинный чек на сорок позиций", "Магазин Кварц Тест", longLines, longTotal, longGoods)
        add("two-cards", "Один чек с двумя оплатами", "Магазин Атлас Тест",
            ["Карандаши учебные 2 x 150.00 300.00", "Блокнот учебный 1 x 300.00 300.00", "ИТОГО 600.00",
             "БЕЗНАЛИЧНЫМИ КАРТА А 350.00", "БЕЗНАЛИЧНЫМИ КАРТА Б 250.00"], 60_000,
            [ReceiptGood(name: "Карандаши учебные", kopecks: 30_000), ReceiptGood(name: "Блокнот учебный", kopecks: 30_000)])
        add("repeated-good", "Две реальные позиции с одинаковым названием", "Магазин Спектр Тест",
            ["Блокнот учебный 1 x 60.00 60.00", "Блокнот учебный 1 x 100.00 100.00", "ИТОГО 160.00"], 16_000,
            [ReceiptGood(name: "Блокнот учебный", kopecks: 6_000), ReceiptGood(name: "Блокнот учебный", kopecks: 10_000)])
        return fixtures
    }

    /// This simulates OCR text, not image recognition. No corrections from the tested parser are applied here.
    static func audit52Noisy(_ lines: [String], level: Audit52Noise, seed: UInt64 = 0x52A7) -> (lines: [String], events: [String: Int]) {
        guard level != .none else { return (lines, [:]) }
        var random = Audit52Random(state: seed)
        var events: [String: Int] = [:]
        let strong = level == .strong
        let alternatives: [Character: [Character]] = ["0": ["О", "O", "D"], "О": ["0"], "O": ["0"], "D": ["0"],
                                                      "1": ["l", "I"], "l": ["1"], "I": ["1"], "5": ["S"], "S": ["5"], "8": ["B"], "B": ["8"]]
        var changed: [String] = []
        for raw in lines {
            if random.number(100) < (strong ? 10 : 1) { events["drop", default: 0] += 1; continue }
            var line = raw
            if random.number(100) < (strong ? 30 : 5) {
                let replaced = line.replacingOccurrences(of: #"(?<=\d)[.,](?=\d{2}(?!\d))"#, with: " ", options: .regularExpression)
                if replaced != line { events["decimal", default: 0] += 1; line = replaced }
            }
            if line.range(of: #"\d{1,2}\.\d{1,2}\.\d{4}"#, options: .regularExpression) != nil,
               random.number(100) < (strong ? 70 : 20) {
                line = line.replacingOccurrences(of: ".", with: strong ? "  .  " : " . ")
                events["date-spaces", default: 0] += 1
            }
            var letters = ""
            for character in line {
                if let choices = alternatives[character], random.number(100) < (strong ? 8 : 1) {
                    letters.append(choices[random.number(choices.count)])
                    events["glyph", default: 0] += 1
                } else { letters.append(character) }
            }
            line = letters
            if random.number(100) < (strong ? 35 : 10) { line = "‹«" + line + "»›"; events["quotes", default: 0] += 1 }
            if line.count > 18, random.number(100) < (strong ? 25 : 3) {
                let spaces = line.indices.filter { line[$0].isWhitespace }
                if let at = spaces.min(by: { abs(line.distance(from: line.startIndex, to: $0) - line.count / 2) < abs(line.distance(from: line.startIndex, to: $1) - line.count / 2) }) {
                    changed += [String(line[..<at]), String(line[line.index(after: at)...])]
                    events["split", default: 0] += 1
                    continue
                }
            }
            changed.append(line)
        }
        var merged: [String] = []
        var index = 0
        while index < changed.count {
            if index + 1 < changed.count, random.number(100) < (strong ? 20 : 2) {
                merged.append(changed[index] + " " + changed[index + 1]); index += 2
                events["join", default: 0] += 1
            } else { merged.append(changed[index]); index += 1 }
        }
        return (merged, events)
    }

    static func audit52Fields(_ read: ParsedReceipt, expected: Audit52Receipt) -> [(String, Bool)] {
        [("total", read.totalKopecks == expected.total),
         ("datetime", read.date == expected.date && read.dateHasTime),
         ("merchant", read.merchant == expected.merchant),
         ("count", read.goods.count == expected.goods.count),
         ("goods", read.goods.map(\.name) == expected.goods.map(\.name)),
         ("prices", read.goods.map(\.kopecks) == expected.goods.map(\.kopecks))]
    }

    // Desired results stay in the fixtures. These clean-input failures are exercised separately
    // by testKnownIssues52(), so the normal run can verify every other field without freezing bugs.
    static let audit52KnownFields: [String: Set<String>] = [
        "wrapped-name": ["count", "goods", "prices"],
        "fuel": ["goods"],
        "two-cards": ["total"],
        "repeated-good": ["count", "goods", "prices"]
    ]

    static func audit52Parse(_ lines: [String]) -> ParsedReceipt {
        let calendar = audit52Calendar()
        let now = calendar.date(from: DateComponents(year: 2032, month: 6, day: 1, hour: 20))!
        return ReceiptParser.parseText(lines, now: now, calendar: calendar)
    }

    static func testAudit52ReceiptLayouts(assertClean: Bool = true) {
        let start = Date()
        let fixtures = audit52Receipts()
        require(fixtures.count >= 13 && Set(fixtures.map(\.id)).count == fixtures.count, "audit52: distinct receipt layouts")
        var totals: [String: [String: Int]] = [:]
        var allEvents: Set<String> = []
        for (index, fixture) in fixtures.enumerated() {
            require(fixture.goods.reduce(Int64(0), { $0 + ($1.kopecks ?? 0) }) == fixture.total,
                    "audit52: independent expected goods reconcile with total for \(fixture.id)")
            for level in Audit52Noise.allCases {
                let seed = UInt64(0x52A7) &+ UInt64(index) &* 0x9E37
                let noisy = audit52Noisy(fixture.lines, level: level, seed: seed)
                let repeatNoise = audit52Noisy(fixture.lines, level: level, seed: seed)
                require(noisy.lines == repeatNoise.lines && noisy.events == repeatNoise.events, "audit52: repeatable noise")
                if level == .none { require(noisy.lines == fixture.lines && noisy.events.isEmpty, "audit52: clean text unchanged") }
                allEvents.formUnion(noisy.events.keys)
                let read = audit52Parse(noisy.lines)
                let fields = audit52Fields(read, expected: fixture)
                for (field, correct) in fields {
                    if correct { totals[level.rawValue, default: [:]][field, default: 0] += 1 }
                    if level == .none, assertClean, !(audit52KnownFields[fixture.id]?.contains(field) ?? false) {
                        require(correct, "audit52: clean \(fixture.id) \(field); got \(read.goods.map(\.line)), total \(String(describing: read.totalKopecks)), merchant \(read.merchant ?? "nil")")
                    }
                }
                let json: [String: Any] = ["layout": fixture.id, "title": fixture.title, "level": level.rawValue,
                    "checks": Dictionary(uniqueKeysWithValues: fields), "events": noisy.events, "lines": noisy.lines,
                    "expectedTotal": fixture.total, "actualTotal": read.totalKopecks.map { $0 as Any } ?? NSNull(),
                    "expectedDate": fixture.date.timeIntervalSince1970, "actualDate": read.date.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
                    "dateHasTime": read.dateHasTime, "expectedMerchant": fixture.merchant, "actualMerchant": read.merchant ?? "nil",
                    "expectedGoods": fixture.goods.map { ["name": $0.name, "kopecks": $0.kopecks.map { $0 as Any } ?? NSNull()] },
                    "actualGoods": read.goods.map { ["name": $0.name, "kopecks": $0.kopecks.map { $0 as Any } ?? NSNull()] }]
                let encoded = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
                print("RECEIPT52\t" + String(data: encoded, encoding: .utf8)!)
            }
        }
        require(allEvents == ["drop", "decimal", "date-spaces", "glyph", "quotes", "split", "join"], "audit52: all requested noise forms exercised")
        for level in Audit52Noise.allCases {
            for field in ["total", "datetime", "merchant", "count", "goods", "prices"] {
                print("METRIC52\t\(level.rawValue)\t\(field)\t\(totals[level.rawValue]?[field] ?? 0)\t\(fixtures.count)")
            }
        }
        print("RUNTIME52\t\(Date().timeIntervalSince(start))")
    }

    /// Desired clean answers: deliberately not called by main until the parser issues have been resolved.
    static func testKnownIssues52(layoutID: String? = nil) {
        for fixture in audit52Receipts() where audit52KnownFields[fixture.id] != nil && (layoutID == nil || layoutID == fixture.id) {
            let read = audit52Parse(fixture.lines)
            for (field, correct) in audit52Fields(read, expected: fixture) {
                require(correct, "known issue52: clean \(fixture.id) \(field); total \(String(describing: read.totalKopecks)); goods \(read.goods.map(\.line))")
            }
        }
    }

    static func testAudit52PhotoListing() throws {
        let first = ReceiptLogic.fileName(id: UUID(uuidString: "00000001-0000-0000-0000-000000000001")!)
        let second = ReceiptLogic.fileName(id: UUID(uuidString: "00000002-0000-0000-0000-000000000002")!)
        let names = try ReceiptArchive.photoFileNames { [first, "other.txt", "../outside.jpg", second] }
        require(names == [first, second], "audit52: only valid photo names are listed")
        let empty = try ReceiptArchive.photoFileNames { [] }
        require(empty.isEmpty, "audit52: existing empty directory has no photos")
        for code in [NSFileNoSuchFileError, NSFileReadNoSuchFileError] {
            let missing = try ReceiptArchive.photoFileNames { throw NSError(domain: NSCocoaErrorDomain, code: code) }
            require(missing.isEmpty, "audit52: absent directory is empty")
        }
        for error in [NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
                      NSError(domain: NSPOSIXErrorDomain, code: 13), NSError(domain: "SyntheticIO", code: 1)] {
            do {
                _ = try ReceiptArchive.photoFileNames { throw error }
                require(false, "audit52: unreadable directory must not become zero photos")
            } catch let actual as NSError {
                require(actual.domain == error.domain && actual.code == error.code, "audit52: listing error preserved")
            }
        }
        var unavailable = true
        let read: () throws -> [String] = {
            if unavailable { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
            return [first, second]
        }
        do { _ = try ReceiptArchive.photoFileNames(read: read); require(false, "audit52: initial access failure") } catch { }
        unavailable = false
        let recovered = try ReceiptArchive.photoFileNames(read: read)
        require(recovered == [first, second], "audit52: retry restores photo count after access recovers")
    }

    // MARK: - Stage 53: four synthetic months, independent account ledgers

    struct Audit53Movement {
        let row: BankOperation
        let card: Int64
        let save: Int64
    }

    static func audit53History() -> (history: SavedHistory, card: Account, save: Account, ledger: [Audit53Movement]) {
        let start = BankDateParser.parse("2033-01-01T00:00:00Z")!
        let card = Account(name: "Яндекс банк", icon: "creditcard", color: "blue", startBalanceKopecks: 1_000_000,
                           startDate: start, tracksBankCard: true)
        let save = Account(name: "Сейв", icon: "building.columns", color: "green", startBalanceKopecks: 500_000,
                           startDate: start, tracksSave: true)
        var ledger: [Audit53Movement] = []
        func add(_ id: String, _ amount: Int64, _ kind: String, _ method: String?, _ title: String,
                 _ date: String, _ cardDelta: Int64, _ saveDelta: Int64,
                 category: String = "Супермаркеты", status: String = "Выполнено", providers: [String] = []) {
            let row = BankOperation(identity: "audit53-" + id, occurredAt: date, timePrecision: "exact", description: title,
                                    amountKopecks: amount, currency: "RUB", status: status, category: category, mcc: nil,
                                    purpose: nil, paymentMethod: method, providers: providers, kind: kind)
            ledger.append(Audit53Movement(row: row, card: cardDelta, save: saveDelta))
        }
        // Independent ledger: amounts below state what each bank account actually received/spent.
        // The cancelled row has no movement; the pending row reserves money but is not a completed expense.
        for month in 1...4 {
            let m = Int64(month)
            let prefix = String(format: "2033-%02d", month)
            let key = "m\(month)-"
            add(key+"salary", 100_000*m, "income", month == 1 ? "Выписка" : "Карта Пэй", "Зарплата Тест", prefix+"-02T10:00:00Z", 100_000*m, 0, category: "Зарплата")
            add(key+"buy", -10_000*m, "expense", "Карта Пэй", "Магазин Север Тест", prefix+"-03T10:00:00Z", -10_000*m, 0)
            add(key+"refund", 1_000*m, "refund", "Карта Пэй", "Возврат покупки Тест", prefix+"-04T10:00:00Z", 1_000*m, 0)
            add(key+"to-card", -20_000, "internal_transfer", "Карта Пэй", "Карта Пэй → Счёт в Сейвах", prefix+"-05T10:00:00Z", -20_000, 0)
            add(key+"to-save", 20_000, "internal_transfer", month == 1 ? "Сейв (выписка)" : "Счёт в Сейвах", "Карта Пэй → Счёт в Сейвах", prefix+"-05T10:00:00Z", 0, 20_000)
            add(key+"from-save", -5_000, "internal_transfer", "Счёт в Сейвах", "Счёт в Сейвах → Карта Пэй", prefix+"-06T10:00:00Z", 0, -5_000)
            add(key+"from-card", 5_000, "internal_transfer", "Карта Пэй", "Счёт в Сейвах → Карта Пэй", prefix+"-06T10:00:00Z", 5_000, 0)
            // Untagged pairs: a destination title, opposite signs, including exactly 120 seconds.
            add(key+"plain-to-card", -2_000, "internal_transfer", nil, "Счёт в Сейвах", prefix+"-07T10:00:00Z", -2_000, 0)
            add(key+"plain-to-save", 2_000, "internal_transfer", nil, "Счёт в Сейвах", prefix+"-07T10:02:00Z", 0, 2_000)
            add(key+"plain-from-save", -1_000, "internal_transfer", nil, "Карта Пэй", prefix+"-08T10:00:00Z", 0, -1_000)
            add(key+"plain-from-card", 1_000, "internal_transfer", nil, "Карта Пэй", prefix+"-08T10:01:00Z", 1_000, 0)
            add(key+"interest", 101*m, "interest_income", month == 2 ? "Сейв (выписка)" : "Счёт в Сейвах", "Выплата процентов Тест", prefix+"-09T10:00:00Z", 0, 101*m, category: "Проценты")
            add(key+"save-buy", -500*m, "expense", "Счёт в Сейвах", "Покупка со Сейва Тест", prefix+"-10T10:00:00Z", 0, -500*m)
            add(key+"split-buy", -7_000*m, "expense", "Сплит", "Магазин Рассвет Тест", prefix+"-11T10:00:00Z", 0, 0, providers: ["BNPL"])
            add(key+"split-payment", -2_000*m, "installment_payment", "Карта *2733", "Платёж Сплита Тест", prefix+"-12T10:00:00Z", -2_000*m, 0, category: "Платежи Сплита", providers: ["BNPL"])
            add(key+"points", -300*m, "expense", "Баллы Плюса", "Покупка баллами Тест", prefix+"-13T10:00:00Z", 0, 0)
            add(key+"cancel", -900*m, "expense", "Карта Пэй", "Отменённая покупка Тест", prefix+"-14T10:00:00Z", 0, 0, status: "Отменено")
            add(key+"pending", -700*m, "expense", "Карта Пэй", "Резерв покупки Тест", prefix+"-15T10:00:00Z", -700*m, 0, status: "В обработке")
        }
        var history = SavedHistory()
        history.accounts = [card, save]
        history.operations = ledger.map(\.row).reversed()
        return (history, card, save, ledger)
    }

    static func testAudit53AccountHistory() {
        let fixture = audit53History()
        let ledger = fixture.ledger
        let history = fixture.history
        let inputs = history.operations.map(\.financialInput)
        func expected(_ account: Account, _ moment: Date, _ isCard: Bool) -> Int64 {
            ledger.filter { let when = BankDateParser.parse($0.row.occurredAt)!; return when >= account.startDate && when < moment }
                .reduce(account.startBalanceKopecks) { $0 + (isCard ? $1.card : $1.save) }
        }
        var moments = [fixture.card.startDate, Date.distantFuture]
        for entry in ledger {
            let when = BankDateParser.parse(entry.row.occurredAt)!
            moments += [when, when.addingTimeInterval(0.001)]
        }
        for (account, isCard) in [(fixture.card, true), (fixture.save, false)] {
            let want = moments.map { expected(account, $0, isCard) }
            require(history.accountBalances(account, at: moments) == want, "stage53 every before/after ledger balance: \(account.name)")
            require(history.accountBalancesReconstructed(account, at: moments) == want.map(Optional.some), "stage53 reconstructed ledger: \(account.name)")
            require(account.balance(bankOperations: inputs, manual: []) == want[1], "stage53 current balance: \(account.name)")
            let movements = history.accountMovements(account)
            let expectedIDs = Set(ledger.filter { isCard ? $0.card != 0 : $0.save != 0 }.map { $0.row.identity })
            require(Set(movements.map(\.id)) == expectedIDs, "stage53 movement membership: \(account.name)")
            for movement in movements {
                let entry = ledger.first { $0.row.identity == movement.id }!
                require(movement.delta == (isCard ? entry.card : entry.save), "stage53 exact signed movement")
            }
            let boundary = BankDateParser.parse("2033-03-05T10:00:00Z")!
            var reopened = account
            reopened.startDate = boundary
            reopened.startBalanceKopecks = expected(account, boundary, isCard)
            require(reopened.balance(bankOperations: inputs, manual: []) == want[1], "stage53 startDate includes rows at the same second exactly once")
            let earlier = [BankDateParser.parse("2033-01-01T00:00:00Z")!, BankDateParser.parse("2033-02-01T00:00:00Z")!, boundary, Date.distantFuture]
            let reconstructed = history.accountBalancesReconstructed(reopened, at: earlier)
            require(reconstructed[0] == nil && Array(reconstructed.dropFirst()) == earlier.dropFirst().map { Optional(expected(account, $0, isCard)) }, "stage53 reconstruction before start, nil before first row")
        }
        // Every complete two-leg transfer conserves the independent total across the two real accounts.
        for month in 1...4 {
            for stem in ["to", "from", "plain-to", "plain-from"] {
                let pair = ledger.filter { $0.row.identity.hasPrefix("audit53-m\(month)-\(stem)-") }
                require(pair.count == 2 && pair.reduce(Int64(0)) { $0 + $1.card + $1.save } == 0, "stage53 transfer conserves card+Save")
                let start = pair.map { BankDateParser.parse($0.row.occurredAt)! }.min()!
                let end = pair.map { BankDateParser.parse($0.row.occurredAt)! }.max()!.addingTimeInterval(0.001)
                let before = history.accountBalances(fixture.card, at: [start])[0] + history.accountBalances(fixture.save, at: [start])[0]
                let after = history.accountBalances(fixture.card, at: [end])[0] + history.accountBalances(fixture.save, at: [end])[0]
                require(before == after, "stage53 actual engine transfer conservation")
            }
        }
        // Rotate the unsorted source without changing balances or exact movement identities.
        var rotated = history
        rotated.operations = Array(history.operations.dropFirst(19)) + Array(history.operations.prefix(19))
        for account in [fixture.card, fixture.save] {
            require(rotated.accountBalances(account, at: moments) == history.accountBalances(account, at: moments), "stage53 source order does not change balances")
            require(rotated.accountMovements(account).map(\.id) == history.accountMovements(account).map(\.id), "stage53 same-second movement order is stable")
        }
        // Flow is completed purchases minus refunds; category slices show gross spending before refunds.
        // Points are tested separately below because their account attribution currently needs a decision/fix.
        var withoutPoints = history
        withoutPoints.operations.removeAll { $0.paymentMethod == "Баллы Плюса" }
        for month in 1...4 {
            let start = BankDateParser.parse(String(format: "2033-%02d-01T00:00:00Z", month))!
            let end = BankDateParser.parse(String(format: "2033-%02d-01T00:00:00Z", month+1))!
            let interval = DateInterval(start: start, end: end)
            for (scope, income, expense) in [(ReportAccountScope.accounts([fixture.card]), Int64(100_000*month), Int64(9_000*month)),
                                              (.accounts([fixture.save]), Int64(101*month), Int64(500*month)),
                                              (.all, Int64(100_101*month), Int64(9_500*month))] {
                let actualIncome = ReportEngine.slices(withoutPoints.financialInputs, in: interval, mode: .income, grouping: .categories, taxonomy: .builtin, filter: ReportFilter(scope: scope)).reduce(Int64(0)) { $0 + $1.amountKopecks }
                let actualExpense = ReportEngine.slices(withoutPoints.financialInputs, in: interval, mode: .expenses, grouping: .categories, taxonomy: .builtin, filter: ReportFilter(scope: scope)).reduce(Int64(0)) { $0 + $1.amountKopecks }
                let gross = expense + (scope.isAll || scope.includesBankCard ? Int64(1_000*month) : 0)
                let flow = ReportEngine.flow(withoutPoints.financialInputs, buckets: [interval], filter: ReportFilter(scope: scope))[0]
                if actualIncome != income || actualExpense != gross || flow.expenseKopecks != expense {
                    fputs("ACCOUNT53 month=\(month) scope=\(scope.cacheKey) income expected=\(income) actual=\(actualIncome); gross expected=\(gross) actual=\(actualExpense); net expected=\(expense) actual=\(flow.expenseKopecks)\n", stderr)
                }
                require(actualIncome == income && actualExpense == gross && flow.incomeKopecks == income && flow.expenseKopecks == expense, "stage53 month \(month) scoped income/spending, Save interest belongs only to Save")
            }
        }
        print("ACCOUNT53: 72 synthetic rows, 146 moments x 2 accounts, 16 transfers, 4 months x 3 report scopes passed (points attribution is a separate known-issue probe).")
    }

    // Not called by main: desired account scope for points. Do not freeze the current incorrect attribution as an oracle.
    static func testKnownAccountIssues53() {
        let fixture = audit53History()
        let interval = DateInterval(start: fixture.card.startDate, end: BankDateParser.parse("2033-05-01T00:00:00Z")!)
        let cardExpense = ReportEngine.flow(fixture.history.financialInputs, buckets: [interval], filter: ReportFilter(scope: .accounts([fixture.card])))[0].expenseKopecks
        fputs("ACCOUNT53 KNOWN: card cash expense expected 90000, actual \(cardExpense); points must not be assigned to the bank card.\n", stderr)
        require(cardExpense == 90_000, "stage53 Plus points purchase is not spending from the selected bank card")
    }

    static func audit53AngledReceipts() -> [Audit52Receipt] {
        let merchant = "Маркет Угол Тест"
        let normalGoods = [ReceiptGood(name: "Молоко учебное", kopecks: 11_800), ReceiptGood(name: "Хлеб учебный", kopecks: 4_650)]
        func fixture(_ id: String, _ day: Int, _ title: String, _ body: [String], _ total: Int64, _ goods: [ReceiptGood]) -> Audit52Receipt {
            let date = audit52Calendar().date(from: DateComponents(year: 2032, month: 5, day: day, hour: 14, minute: 25))!
            return Audit52Receipt(id: id, title: title,
                                  lines: ["ООО «\(merchant)»", "КАССОВЫЙ ЧЕК", String(format: "%02d.05.2032 14:25", day),
                                          "ЦЕНА / ЦЕНА СО СКИДКОЙ / КОЛ-ВО / ИТОГ"] + body + ["ИТОГО \(ReceiptGood.rubles(total))"],
                                  total: total, date: date, merchant: merchant, goods: goods)
        }
        return [
            fixture("angle-columns", 20, "Итог на строке названия; цифры липнут к следующему товару",
                    ["Молоко учебное 118.00", "70.00 59.00 2ШТ. 118.00 Хлеб учебный 46.50", "50.00 46.50 1ШТ. 46.50"], 16_450, normalGoods),
            fixture("angle-merged", 21, "Две строки чисел слиты, итоги остались рядом с названиями",
                    ["Молоко учебное 118.00", "Хлеб учебный 46.50", "70.00 59.00 2ШТ. 118.00 50.00 46.50 1ШТ. 46.50"], 16_450, normalGoods),
            fixture("angle-wrong-total", 22, "Итог товара прочитан 19.99 вместо 73.99; цена и общий итог сохранились",
                    ["Сахар учебный 19.99", "89.99 73.99 1ШТ. 19.99"], 7_399,
                    [ReceiptGood(name: "Сахар учебный", kopecks: 7_399)]),
        ]
    }

    /// Desired results for angled OCR text. Run separately; never accept the wrong price as the expected result.
    static func testKnownIssues53(layoutID: String? = nil) {
        for fixture in audit53AngledReceipts() where layoutID == nil || fixture.id == layoutID {
            require(fixture.goods.reduce(Int64(0)) { $0 + ($1.kopecks ?? 0) } == fixture.total, "stage53 independent goods reconcile with total")
            let read = audit52Parse(fixture.lines)
            let fields = audit52Fields(read, expected: fixture)
            let json: [String: Any] = ["layout": fixture.id, "title": fixture.title, "lines": fixture.lines,
                "checks": Dictionary(uniqueKeysWithValues: fields), "expectedTotal": fixture.total,
                "actualTotal": read.totalKopecks.map { $0 as Any } ?? NSNull(),
                "expectedGoods": fixture.goods.map { ["name": $0.name, "kopecks": $0.kopecks.map { $0 as Any } ?? NSNull()] },
                "actualGoods": read.goods.map { ["name": $0.name, "kopecks": $0.kopecks.map { $0 as Any } ?? NSNull()] }]
            let encoded = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            fputs("RECEIPT53\t" + String(data: encoded, encoding: .utf8)! + "\n", stderr)
            for (field, correct) in fields {
                require(correct, "known issue53: \(fixture.id) \(field); total \(String(describing: read.totalKopecks)); goods \(read.goods.map(\.line))")
            }
        }
    }

    static func testAudit53AngledReceipts() {
        for fixture in audit53AngledReceipts() {
            let read = audit52Parse(fixture.lines)
            for (field, correct) in audit52Fields(read, expected: fixture) {
                // The desired 73.99 price remains in the oracle and is required by testKnownIssues53.
                if fixture.id == "angle-wrong-total" && field == "prices" { continue }
                require(correct, "stage53 angled \(fixture.id) \(field): \(read.goods.map(\.line))")
            }
        }
    }

    /// Stage 65: independent contract checks. Collect all failures in one local run; never accept observed output as expected.
    static func testAudit65() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        var checked = 0
        var failed = 0
        func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
            checked += 1
            if actual != expected {
                failed += 1
                fputs("FAIL STAGE65 \(name): expected=\(expected), actual=\(actual)\n", stderr)
            }
        }
        let monthly = Subscription(name: "Подписка учебная", amountKopecks: 10_000, day: 31)
        for (year, last) in [(2032, 29), (2033, 28)] {
            let dues = FinancialEngine.commitmentDues(subscriptions: [monthly], loans: [], from: at(year, 2, 1), to: at(year, 3, 1), calendar: calendar)
            expect(dues.map(\.date), [at(year, 2, last)], "February \(year)")
        }
        let annual = Subscription(name: "Годовая учебная", amountKopecks: 12_000, day: 31, month: 12)
        expect(FinancialEngine.commitmentDues(subscriptions: [annual], loans: [], from: at(2032, 12, 1), to: at(2033, 2, 1), calendar: calendar).map(\.date),
               [at(2032, 12, 31)], "annual December to January")
        var january = annual
        january.month = 1
        expect(FinancialEngine.commitmentDues(subscriptions: [january], loans: [], from: at(2032, 12, 1), to: at(2033, 2, 1), calendar: calendar).map(\.date),
               [at(2033, 1, 31)], "annual January after December")
        var sameDay = monthly
        sameDay.since = at(2032, 2, 29, 18)
        expect(FinancialEngine.commitmentDues(subscriptions: [sameDay], loans: [], from: at(2032, 2, 1), to: at(2032, 3, 1), calendar: calendar).map(\.date),
               [at(2032, 2, 29)], "since includes payment day")
        var loan = Loan(name: "Кредит учебный", paymentKopecks: 10_000, day: 31, balanceKopecks: 10_000,
                        balanceDate: at(2032, 1, 31, 18), reducesBalance: true, since: at(2032, 1, 31))
        func amounts(_ loan: Loan) -> [Int64] {
            FinancialEngine.commitmentDues(subscriptions: [], loans: [loan], from: at(2032, 1, 1), to: at(2032, 5, 1), calendar: calendar).map(\.amountKopecks)
        }
        expect(amounts(loan), [10_000], "equal balance: one final payment, entered day excluded")
        expect(loan.balance(now: at(2032, 2, 29), calendar: calendar), Int64(0), "balance reaches zero on leap February due")
        loan.balanceKopecks = 0
        expect(amounts(loan), [], "zero balance has no dues")
        loan.balanceKopecks = 15_000
        expect(amounts(loan), [10_000, 5_000], "last loan payment capped at remaining balance")
        var withoutBalance = Loan(name: "Без остатка учебный", paymentKopecks: 10_000, day: 29, since: at(2033, 2, 28, 18))
        expect(FinancialEngine.commitmentDues(subscriptions: [], loans: [withoutBalance], from: at(2033, 2, 1), to: at(2033, 3, 1), calendar: calendar).map(\.date),
               [at(2033, 2, 28)], "loan since on due day")
        withoutBalance.since = at(2033, 3, 1)
        expect(FinancialEngine.commitmentDues(subscriptions: [], loans: [withoutBalance], from: at(2033, 2, 1), to: at(2033, 3, 1), calendar: calendar).count,
               0, "loan since excludes earlier due")

        var history = SavedHistory()
        let original = bankOp("audit65-edit", -10_000, description: "Магазин учебный", date: "2032-03-01T10:00:00Z")
        history.operations = [original]
        expect(history.editBankOperation(identity: original.identity, amountKopecks: -12_000, occurredAt: "2032-03-02T10:00:00Z", description: "Поправлено учебное"), true, "edit accepted")
        let once = history.operations
        history.applyOperationEdits()
        history.applyOperationEdits()
        expect(history.operations, once, "double apply idempotent")
        let fresh = bankOp(original.identity, -11_000, description: "Магазин учебный", date: original.occurredAt)
        history.operations = [fresh]
        history.applyOperationEdits()
        expect(history.operations.first?.amountKopecks, Int64(-12_000), "owner amount wins over changed bank amount")
        expect(history.operationEdits?[original.identity]?.original, fresh, "fresh bank amount retained for revert")
        expect(history.deleteBankOperation(identity: original.identity), true, "edited operation deleted")
        expect(history.operationEdits == nil, true, "delete removes edit")
        history.operations = [fresh]
        history.operationEdits = [original.identity: OperationEdit(original: original, amountKopecks: -12_000, occurredAt: original.occurredAt, description: original.description)]
        history.applyOperationEdits()
        expect(history.operations.count, 0, "tombstone wins even when edit exists")
        expect(history.editBankOperation(identity: original.identity, amountKopecks: -13_000, occurredAt: original.occurredAt, description: original.description), false, "deleted operation cannot be edited")

        let taxonomy = ExpenseTaxonomy(groups: ["А", "Б", "В"].map { ExpenseTaxonomy.Group(name: $0, subcategories: ["Учебная"], isFixedCosts: false) })
        func expense(_ group: String, _ raw: String, _ amount: Int64 = 100) -> FinancialOperationInput {
            var input = op(-amount, kind: "expense", date: raw)
            input.categoryPath = group + "/Учебная"
            return input
        }
        let inputs = [expense("А", "2033-02-28T10:00:00Z", 400), expense("А", "2033-03-31T10:00:00Z"),
                      expense("Б", "2033-03-01T10:00:00Z"), expense("В", "2033-03-01T10:00:00Z")]
        let leaders = ReportEngine.spendingLeaders(inputs, month: at(2033, 3, 1), now: at(2033, 3, 31, 12), taxonomy: taxonomy, calendar: calendar)
        expect(leaders.periods.previous.end, at(2033, 3, 1), "March 31 comparison clamps at February end")
        expect(leaders.leaders.first?.previousKopecks, Int64(400), "February 28 comparison included")
        expect(leaders.leaders.map(\.group), ["А", "Б", "В"], "equal groups follow taxonomy order")
        expect(leaders.leaders.reduce(0) { $0 + $1.sharePercent }, 99, "three equal shares round down")
        expect(leaders.leaders.reduce(0) { $0 + $1.sharePercent } <= 100, true, "shares never exceed 100")
        let reversed = ReportEngine.spendingLeaders(Array(inputs.reversed()), month: at(2033, 3, 1), now: at(2033, 3, 31, 12), taxonomy: taxonomy, calendar: calendar)
        expect(reversed.leaders, leaders.leaders, "input order does not break tie stability")
        let first = monthComparisonPeriods(selectedStart: at(2033, 3, 1), currentDate: at(2033, 3, 1), calendar: calendar)
        expect(first.current.end, at(2033, 3, 2), "first day current interval")
        expect(first.previous.end, at(2033, 2, 2), "first day prior interval")
        let future = monthComparisonPeriods(selectedStart: at(2033, 4, 1), currentDate: at(2033, 3, 1), calendar: calendar)
        expect(future.current.end, at(2033, 5, 1), "future month whole")
        expect(historyInterval(.monthToDate, now: at(2033, 1, 1), calendar: calendar).start, at(2033, 1, 1), "running month year boundary")
        let custom = HistoryPeriod.custom(from: at(2032, 12, 1), through: at(2032, 12, 31))
        expect(HistoryPeriod(storageText: custom.storageText), custom, "old custom period stays fixed")
        var east = calendar
        east.timeZone = TimeZone(secondsFromGMT: 14 * 3600)!
        expect(historyInterval(.monthToDate, now: at(2032, 12, 31, 12), calendar: east).start,
               at(2032, 12, 31, 10), "month boundary uses supplied timezone")
        let oldJSON = Data(#"{"format":1,"exportedAt":"2032-01-01T00:00:00Z","history":{"operations":[]}}"#.utf8)
        expect((try? HistoryBackup.decode(oldJSON))?.operations.count, 0, "old JSON backup opens")
        let full = FullBackup.make(history: oldJSON, photos: [("audit.bin", Data([1, 2]))])
        expect(FullBackup.read(full)?.history, oldJSON, "full backup retains history")
        expect(FullBackup.read(Data(full.dropLast(22))) == nil, true, "truncated full backup refused")

        // Contract regressions: expected behavior comes from the stage brief, not the current classifier.
        var transfer = op(10_000, kind: "refund", category: "Возврат", description: "Перевод от Учебного магазина")
        transfer.confirmedNature = "income"
        expect(FinancialEngine.classify(transfer).type, .income, "W65-1 owner confirmation beats bank refund metadata")
        let commission = BankOperation(identity: "audit65-fee", occurredAt: original.occurredAt, timePrecision: "exact", description: "Комиссия учебная",
                                       amountKopecks: -100, currency: "RUB", status: "Выполнено", category: "Комиссии", mcc: nil, purpose: nil,
                                       paymentMethod: nil, providers: [], kind: "commission")
        let flipped = OperationEdit(original: commission, amountKopecks: 100, occurredAt: commission.occurredAt, description: commission.description).applied(to: commission)
        expect(FinancialEngine.classify(flipped.financialInput).type, .income, "W65-2 changing bank operation to income changes financial type")
        let overpaid = CreditCards.resave(oldLimit: 100_000, oldStartBalance: 120_000, newLimit: 100_000, debt: 0)
        expect(overpaid.startBalanceKopecks, Int64(120_000), "W65-3 untouched overpaid card preserves start balance")
        expect(overpaid.restarts, false, "W65-3 untouched overpaid card keeps anchor")
        let moved = Subscription(name: "Годовая перенесённая учебная", amountKopecks: 30_000, day: 5, month: 4, since: at(2032, 4, 1))
        let key = FinancialEngine.commitmentKey(id: moved.id, due: at(2032, 4, 5), calendar: calendar)
        let forecast = FinancialEngine.monthForecast([], now: at(2032, 6, 10), calendar: calendar,
            answers: [key: .init(kind: .moved, movedTo: at(2032, 6, 20))], subscriptions: [moved])
        expect(forecast.upcoming.filter { $0.key == key }.map(\.amountKopecks), [30_000], "W65-4 moved annual due survives beyond previous month")
        let oldLoan = Loan(name: "Кредит учебный", paymentKopecks: 10_000, day: 15, balanceKopecks: 50_000,
                           balanceDate: at(2032, 1, 1), reducesBalance: true, since: at(2032, 1, 1))
        let editedOn = at(2032, 3, 20)
        let entered = oldLoan.balance(now: editedOn, calendar: calendar)
        expect(entered, Int64(20_000), "loan balance before payment edit")
        let kept = Loan.keptBalance(old: oldLoan, entered: entered, reduces: true, now: editedOn, calendar: calendar)
        var changedLoan = oldLoan
        changedLoan.paymentKopecks = 20_000
        changedLoan.balanceKopecks = kept.kopecks
        changedLoan.balanceDate = kept.date
        expect(changedLoan.balance(now: editedOn, calendar: calendar), Int64(20_000), "W65-5 changing future payment preserves today's entered balance")
        let aprilMoved = at(2032, 4, 20)
        let paid = op(-30_000, kind: "expense", description: moved.name, date: "2032-04-20T12:00:00Z")
        let paidForecast = FinancialEngine.monthForecast([paid], now: at(2032, 4, 21), calendar: calendar,
            answers: [key: .init(kind: .moved, movedTo: aprilMoved)], subscriptions: [moved])
        expect(paidForecast.upcoming.filter { $0.key == key }.count, 0, "W65-6 actual payment matched against moved due date")
        print("STAGE65: \(checked - failed)/\(checked) passed; \(failed) failed")
        require(failed == 0, "Stage 65 contract failures (all listed above)")
    }

    /// Fixes after the audit of stage 65 beyond the contract checks: the owner's side of an edited operation and the statuses, what
    /// goes with a deleted operation, a payment moved from an old day, the names in the key of the forecast.
    static func testAudit65Fixes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2032, month: month, day: day, hour: 12))! }
        // an income changed to an expense and back: the owner's side is the type, the original stays
        let income = bankOp("fx1", 50_000, description: "Поступление учебное", kind: "income", date: "2032-06-02T10:00:00Z")
        var history = SavedHistory()
        history.operations = [income]
        require(history.editBankOperation(identity: "fx1", amountKopecks: -50_000, occurredAt: income.occurredAt, description: income.description), "to an expense")
        let asExpense = history.operations[0]
        require(asExpense.editedSide == "expense", "the side the owner chose is kept")
        require(FinancialEngine.classify(asExpense.financialInput).type == .expense, "an income changed to an expense is an expense")
        require(history.editBankOperation(identity: "fx1", amountKopecks: 50_000, occurredAt: income.occurredAt, description: income.description), "back")
        require(history.operations[0] == income && history.operationEdits == nil, "back to the bank's own values: no edit, no side")
        // a pending or cancelled status keeps its force over the owner's side
        let pending = BankOperation(identity: "fx2", occurredAt: "2032-06-02T10:00:00Z", timePrecision: "exact", description: "Комиссия учебная",
                                    amountKopecks: -100, currency: "RUB", status: "В обработке", category: "Комиссии", mcc: nil, purpose: nil,
                                    paymentMethod: nil, providers: [], kind: "commission")
        let flipped = OperationEdit(original: pending, amountKopecks: 100, occurredAt: pending.occurredAt, description: pending.description).applied(to: pending)
        require(FinancialEngine.classify(flipped.financialInput).type == .pending, "a pending operation stays pending")
        // a confirmation does not lift a cancelled operation either
        var cancelled = op(10_000, kind: "unclassified_income", status: "Отменено", description: "Перевод от Учебного человека")
        cancelled.confirmedNature = "income"
        require(FinancialEngine.classify(cancelled).type == .cancelled, "a cancelled operation stays cancelled")

        // deleting takes what belonged to the operation with it
        var kept = SavedHistory()
        let doomed = bankOp("fx3", -10_000, description: "Магазин учебный", date: "2032-06-03T10:00:00Z")
        kept.operations = [doomed]
        kept.operationLooks = ["fx3": OperationLook(title: "Моё название", icon: nil, note: nil), "other": OperationLook(title: "Чужое", icon: nil, note: nil)]
        kept.operationNatures = ["fx3": "income"]
        kept.receipts = ["fx3": ["a.jpg"], "other": ["b.jpg"]]
        kept.receiptGoods = ["fx3": [ReceiptGood(name: "Товар")]]
        require(kept.deleteBankOperation(identity: "fx3"), "deleted")
        require(kept.operationLooks?["fx3"] == nil && kept.operationLooks?["other"] != nil, "the title goes, another stays")
        require(kept.operationNatures?["fx3"] == nil, "the confirmation goes")
        require(kept.receipts?["fx3"] == nil && kept.receipts?["other"] == ["b.jpg"], "the link to the photos goes, another stays")
        require(kept.receiptGoods?["fx3"] == nil, "the goods go")

        // a payment moved from an old day is still waited for; one not moved is not asked about a year later
        let yearly = Subscription(name: "Годовая учебная", amountKopecks: 30_000, day: 5, month: 2, since: at(1, 1))
        let oldKey = FinancialEngine.commitmentKey(id: yearly.id, due: at(2, 5), calendar: calendar)
        let notMoved = FinancialEngine.monthForecast([], now: at(6, 10), calendar: calendar, subscriptions: [yearly])
        require(notMoved.upcoming.isEmpty, "an old unanswered payment is not asked about months later")
        let movedLater = FinancialEngine.monthForecast([], now: at(6, 10), calendar: calendar,
                                                       answers: [oldKey: .init(kind: .moved, movedTo: at(6, 25))], subscriptions: [yearly])
        require(movedLater.upcoming.count == 1, "a payment moved to this month is waited for")
        let movedToOld = FinancialEngine.monthForecast([], now: at(6, 10), calendar: calendar,
                                                       answers: [oldKey: .init(kind: .moved, movedTo: at(3, 1))], subscriptions: [yearly])
        require(movedToOld.upcoming.isEmpty, "a payment moved to an old day is not waited for")

        // the name is in the key of the forecast: a renamed subscription draws the forecast again
        var named = SavedHistory()
        named.subscriptions = [Subscription(name: "Старое", amountKopecks: 100, day: 5)]
        let before = named.commitmentsKey
        named.subscriptions?[0].name = "Новое"
        require(named.commitmentsKey != before, "the name is in the key")
    }

    static func main() {
        testAudit65Fixes()
        testAudit65()
        testSpendingLeaders()
        testBankOperationEdits()
        testCreditCards()
        testCommitments()
        testAudit53AngledReceipts()
        testAudit53AccountHistory()
        testAudit52ReceiptLayouts()
        do { try testAudit52PhotoListing() } catch { require(false, "audit52: photo listing fixture failed: \(error)") }
        testKnownIssues50()
        testBudgetLargestAmount()
        testAudit50ReceiptResults()
        testAudit50BudgetMonthBoundaries()
        testAudit50BudgetMutationAndFallback()
        testAudit50BudgetRefundsAndFutureDates()
        testAudit50BudgetNotices()
        testAudit50AccountScopeWithFilters()
        testAudit50HistoryPeriods()
        do { try testAudit50BackupDates() } catch { require(false, "audit50: backup date fixture failed") }
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
        // An interest payout the collector tagged «refund» (the bank draws it with the refund arrow) is income, not a refund.
        let taggedInterest = FinancialEngine.classify(op(2_494, kind: "refund", category: "Проценты", description: "Выплата процентов"))
        require(taggedInterest.type == .interestIncome && taggedInterest.incomeContributionKopecks == 2_494 && taggedInterest.refundContributionKopecks == 0,
                "interest tagged as refund is income")
        require(FinancialEngine.classify(op(2_494, kind: "refund", category: "Перевод", description: "Выплата процентов")).type == .interestIncome,
                "interest wording beats the refund tag")
        // A real refund stays a refund: its own words, the bank's «Возврат» category, a purchase without interest words.
        require(FinancialEngine.classify(op(2_494, kind: "refund", category: "Возврат", description: "Выплата процентов")).type == .refund,
                "bank refund category stays a refund")
        require(FinancialEngine.classify(op(2_494, kind: "refund", category: "Проценты", description: "Возврат покупки")).type == .refund,
                "refund words stay a refund")
        require(FinancialEngine.classify(op(2_494, kind: "refund", category: "Супермаркеты", description: "Магазин учебный")).type == .refund,
                "ordinary refund stays a refund")
        // GPT stage 63 (W63-2): the category «Проценты» alone, or the phrase inside a shop's name, is not an interest payout.
        require(FinancialEngine.classify(op(2_494, kind: "refund", category: "Проценты", description: "Магазин учебный")).type == .refund,
                "a refund with the category «Проценты» stays a refund")
        require(FinancialEngine.classify(op(2_494, kind: "refund", category: "Супермаркеты", description: "Учебный магазин выплата процентов")).type == .refund,
                "the payout phrase inside a shop's name does not make income")
        // The day of the payout: no spending below zero, the interest in income.
        let payoutDay = FinancialEngine.report([op(2_494, kind: "refund", category: "Проценты", description: "Выплата процентов", date: "2032-06-02T08:00:00Z")],
                                               in: DateInterval(start: Date(timeIntervalSince1970: 1_969_747_200), duration: 86_400))
        require(payoutDay.netExpenseKopecks == 0 && payoutDay.incomeKopecks == 2_494, "interest payout day: spending 0, income 24,94")
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
        testCategorySuggestions()
        testRuleCandidates()
        testSuggestionsInBatch()
        testExpenseReviewEdits()
        testManualExpenseReviewUndo()
        testFixedCostGroups()
        testIncomeCategories()
        testSaveStatementSource()
        testCardToSaveTransfer()
        testOperationLooks()
        testOtherShrinks()
        testReserveAccounts()
        testReportEngine()
        testReportAccountScope()
        testBudgets()
        testHistoryPeriodStorage()
        testReceiptTotals()
        testSaveAccountAndOtherSides()
        testReceiptItems()
        testReceiptNoise()
        testReceiptGoods()
        testReceiptCheckReport()
        testReceiptPriceBands()
        testReceiptLayoutsRepaired()
        testReceiptRepairs()
        testForecastSpeed()
        testForecastRefunds()
        testForecastCompletenessAndReturns()
        testForecastLatePaymentsAndIrregularIncome()
        testBalanceReconciliation()
        testForecastRange()
        testKnownIssues52()
        testKnownIssues53()
        testKnownAccountIssues53()
        testRegularPayments()
        testReceipts()
        testReceiptParser()
        testReceiptArchive()
        testForecastFixes()
        testConfirmedNature()
        testAppLockLogic()
        testReceiptBankMatch()
        testAccountMovements()
        testReportSeries()
        testAccountSeries()

        testAuditReportBoundaries()
        testAuditCalendarTransitions()
        testAuditReportFilterAndEmptyFlow()
        testAuditAccountMoments()
        do { try testAuditBackupAndReceiptReferences() }
        catch { require(false, "audit: valid synthetic backup round trip threw an error") }
        testAuditReceiptParsingEdges()
        testAuditReceiptArchiveCorruption()
        testAuditRegularPaymentsEdges()
        testAuditSuggestionsAndLockEdges()
        testKnownIssues()

        print("Finance engine tests passed")
    }
}
