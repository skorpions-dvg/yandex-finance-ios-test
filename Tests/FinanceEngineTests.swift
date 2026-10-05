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

    static func main() {
        require(FinancialEngine.classify(op(-10_000, kind: "expense")).type == .expense, "expense")
        require(FinancialEngine.classify(op(5_000, kind: "income")).type == .income, "explicit income")
        require(FinancialEngine.classify(op(5_100, kind: "unclassified_income")).type == .unknown, "technical unclassified income must stay unknown")
        require(FinancialEngine.classify(op(5_200, kind: "unclassified_income", category: "Зарплата", description: "Зарплата за месяц")).type == .income, "salary text confirms income")
        require(FinancialEngine.classify(op(5_300, kind: "unclassified_income", description: "Кэшбэк 5 процентов")).type == .income, "cashback with percent text remains cashback income")
        require(FinancialEngine.classify(op(3_000, kind: "refund", category: "Возврат")).type == .refund, "refund")
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

        print("Finance engine tests passed")
    }
}
