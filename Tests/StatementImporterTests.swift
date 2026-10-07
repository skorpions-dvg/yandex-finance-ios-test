import Foundation
import CoreGraphics
import CoreText
import PDFKit

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct StatementImporterTests {
    static func main() throws {
        let page = """
        Яндекс Банк
        Выписка по Договору за период с 11.07.2026 по 04.10.2026
        Иванов Иван Иванович
        Дата рождения 01.01.1990
        Описание операции Дата и время
        операции
        МСК
        Дата
        обработки
        МСК
        Карта Сумма в валюте
        операции
        Сумма в валюте
        Договора
        Входящий перевод с карты *3915 29.09.2026
        в 10:00
        29.09.2026 +1 000,00 ₽ +1 000,00 ₽
        Оплата товаров и услуг
        Yandex*5399*Ysplit
        29.09.2026
        в 10:01
        30.09.2026 *2733 –500,00 ₽ –500,00 ₽
        Входящий перевод СБП, Иван Иванович И., +7 900 000-00-00, Тест Банк
        30.09.2026
        в 12:00
        30.09.2026 +250,00 ₽ +250,00 ₽
        Возврат средств СБП QR (Магазин) 30.09.2026
        в 13:00
        30.09.2026 +100,00 ₽ +100,00 ₽
        Оплата СБП QR (Магнит) 01.10.2026
        в 10:19
        01.10.2026 –418,96 ₽ –418,96 ₽
        Страница 1 из 1
        """

        let result = try StatementImporter.parsePages([page])
        expect(result.operations.count == 4, "only operations before 01.10.2026 must enter archive")
        expect(result.ignoredAtOrAfterCutoff == 1, "01.10.2026 operation must be left to live scanner")

        let ownCard = result.operations.first { $0.description.contains("карты *3915") }
        expect(ownCard?.kind == "internal_transfer", "card top-up must not become income")

        let split = result.operations.first { $0.description.lowercased().contains("ysplit") }
        expect(split?.kind == "installment_payment", "Split must remain separate")
        expect(split?.providers.contains("bnpl") == true, "Split provider marker must be preserved")

        let ownSBP = result.operations.first { $0.description.contains("Иван Иванович И.") }
        expect(ownSBP?.kind == "internal_transfer", "SBP transfer from the statement holder must be own transfer")

        let refund = result.operations.first { $0.description.contains("Возврат") }
        expect(refund?.kind == "refund", "refund must reduce expenses rather than create income")

        expect(split?.identity == "statement:8d6ea4b423fe5065abd82be77566e15aee45010c2cdb9415e45e2a649fb44e9c", "legacy account identity must stay fixed")

        let ids = Set(result.operations.map(\.identity))
        expect(ids.count == result.operations.count, "statement identities must be unique")
        expect(result.operations.allSatisfy { $0.status == "Выполнено" }, "posted statement operations are settled")

        let repeatResult = try StatementImporter.parsePages([page])
        expect(result.operations.map(\.identity) == repeatResult.operations.map(\.identity), "reimport must be deterministic")

        let savePage = """
        Яндекс Банк
        Договор банковского вклада до востребования для физических лиц
        Выписка по Договору за период с 01.09.2026 по 04.10.2026
        Описание операции Дата операции Сумма в валюте
        МСК
        Договора
        Перевод между счетами одного клиента 29.09.2026 +500,00 ₽
        Капитализация процентов 30.09.2026 +12,34 ₽
        Перевод между счетами одного клиента 01.10.2026 –100,00 ₽
        Страница 1 из 1
        """
        let save = try StatementImporter.parsePages([savePage])
        expect(save.source == .save && save.operations.count == 2 && save.ignoredAtOrAfterCutoff == 1, "Save detection and cutoff")
        expect(save.operations.allSatisfy { $0.identity.hasPrefix("statement-save:") && $0.timePrecision == "statement_day" && $0.paymentMethod == "Сейв (выписка)" }, "Save source markers")
        expect(save.operations.contains { $0.kind == "interest_income" && $0.occurredAt == "2026-09-30T09:00:00.000Z" }, "interest at Moscow noon")
        expect(save.operations.contains { $0.kind == "internal_transfer" }, "Save top-up is internal")
        let otherSave = try StatementImporter.parsePages([savePage.replacingOccurrences(of: "Страница 1 из 1", with: "Исходящий перевод СБП, Тестовый получатель 30.09.2026 –25,00 ₽\nСтраница 1 из 1")])
        expect(otherSave.operations.contains { $0.description.contains("Тестовый получатель") && $0.financialAssessment.type == .expense }, "ordinary Save payment uses the existing classifier")
        var original = SavedHistory()
        original.operations = result.operations
        original.incomeCategoryOverrides = ["untouched": "Кэшбэк"]
        let both = try StatementImporter.merging([result, save, result], into: original)
        expect(both.operations.count == 6 && both.statementOperationCount == 6, "overlapping account PDFs are deduplicated")
        let repeated = try StatementImporter.merging([result, save], into: both)
        expect(repeated.operations == both.operations, "repeat preserves identical rows including verification times")
        let saveOnly = try StatementImporter.merging([save], into: both)
        expect(saveOnly.operations == both.operations, "Save-only import preserves account rows")
        let accountOnly = try StatementImporter.merging([result], into: both)
        expect(accountOnly.operations == both.operations, "account-only import preserves Save rows")
        expect(accountOnly.incomeCategoryOverrides == original.incomeCategoryOverrides, "user category choices untouched")
        do {
            _ = try StatementImporter.importPDFs([URL(fileURLWithPath: "/missing-synthetic-statement.pdf")])
            expect(false, "bad selection must fail")
        } catch { expect(original.operations == result.operations, "failure cannot mutate the original") }

        try testGeometryAndMigration()

        print("Statement importer: archive cutoff, own transfers, Split, refunds and deterministic IDs passed.")
    }
}

extension StatementImporterTests {
    static func testGeometryAndMigration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-statement-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { fatalError("synthetic PDF context") }
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
            let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attrs))
            context.textMatrix = .identity; context.textPosition = CGPoint(x: x, y: 842 - y)
            CTLineDraw(line, context)
        }
        for page in 0..<2 {
            context.beginPDFPage(nil)
            text("Яндекс Банк", 20, 40)
            text("Выписка по Договору за период с 01.09.2026 по 30.09.2026", 20, 60)
            text("Описание операции", 20, 100)
            text("Дата и время", 210, 100); text("операции МСК", 210, 114)
            text("Дата", 310, 100); text("обработки", 280, 114); text("МСК", 310, 128)
            text("Карта", 350, 100)
            text("Сумма в валюте", 410, 100); text("операции", 410, 114)
            text("Сумма в валюте", 505, 100); text("Договора", 505, 114)
            let descriptions = page == 0
                ? [["Оплата товаров и услуг", "Yandex*5399*Ysplit"], ["Возврат средств", "СБП QR", "Тестовый магазин"]]
                : [["Перевод между счетами", "одного клиента", "Тестовое назначение", "Архив"], ["Оплата товаров и услуг", "Тестовый магазин"]]
            for (index, description) in descriptions.enumerated() {
                let y = CGFloat(160 + index * 90)
                // Deliberately draw columns out of reading order, like the bank PDF.
                let money = page == 0 && index == 1 ? "+100,00 ₽" : "–500,00 ₽"
                text(money, 410, y); text(money, 505, y)
                text("29.09.2026", 210, y); text("в 10:01", 210, y + 14)
                text("30.09.2026", 280, y)
                if index == 0 { text("*2733", 350, y) }
                for (offset, value) in description.enumerated() { text(value, 20, y + CGFloat(offset * 14)) }
            }
            text("Исходящий остаток", 20, 380)
            text("Страница \(page + 1) из 2", 20, 800)
            context.endPDFPage()
        }
        context.closePDF()
        let document = PDFDocument(url: url)!
        let cells = StatementImporter.cells(from: document.page(at: 0)!)
        expect(cells.contains { $0.text == "Описание" }, "PDF extraction keeps heading word boundaries")
        expect(cells.contains { $0.text == "29.09.2026" }, "PDF extraction keeps date word boundaries")
        let parsed = try StatementImporter.importPDF(at: url)
        expect(parsed.operations.count == 4, "two physical tables with multiline descriptions")
        expect(parsed.operations.contains { $0.kind == "installment_payment" && $0.description == "Оплата товаров и услуг Yandex*5399*Ysplit" }, "Split description belongs to its own row")
        expect(parsed.operations.contains { $0.kind == "refund" && $0.description == "Возврат средств СБП QR Тестовый магазин" }, "refund physical row")
        expect(parsed.operations.contains { $0.kind == "internal_transfer" && $0.description.hasSuffix("Тестовое назначение Архив") }, "four-line own transfer physical row")
        expect(parsed.operations.allSatisfy { !$0.description.contains("29.09.2026") && !$0.description.contains("₽") && !$0.description.contains("*2733") }, "no adjacent data contaminates descriptions")

        func copy(_ operation: BankOperation, id: String, description: String) -> BankOperation {
            BankOperation(identity: id, occurredAt: operation.occurredAt, timePrecision: operation.timePrecision,
                description: description, amountKopecks: operation.amountKopecks, currency: operation.currency,
                status: operation.status, category: operation.category, mcc: operation.mcc, purpose: description,
                paymentMethod: operation.paymentMethod, providers: operation.providers, kind: operation.kind)
        }
        let correct = parsed.operations.first { $0.description == "Оплата товаров и услуг Тестовый магазин" }!
        let old = copy(correct, id: "statement:damaged-expense", description: "29.09.2026 –500,00 ₽")
        let category = ExpenseCategoryGroup.builtin[0].categories[0].id
        var original = SavedHistory()
        original.operations = [old]
        original.categoryOverrides = [old.identity: category]
        original.categoryRules = [CategoryRule(payeeKey: "test", title: "Тест", categoryID: category)]
        original.incomeCategoryRules = [IncomeCategoryRule(payeeKey: "sender", title: "Тестовый отправитель", category: "Кэшбэк")]
        original.manualOperations = [ManualOperation(kind: .expense, amountKopecks: 100, date: Date(), group: "Еда", subcategory: "Супермаркеты")]
        let single = StatementImportResult(source: .account, operations: [correct], coverageStart: parsed.coverageStart,
            coverageEnd: parsed.coverageEnd, ignoredAtOrAfterCutoff: 0)
        let migrated = try StatementImporter.preview([single], into: original)
        expect(migrated.history.operations.map(\.identity) == [correct.identity] && migrated.transferred == 1 && migrated.corrected == 1 && migrated.ambiguousChoices == 0, "unique migration replaces one row and transfers category")
        expect(migrated.history.categoryOverrides?[correct.identity] == category && migrated.history.categoryOverrides?[old.identity] == nil, "expense override follows the new ID")
        expect(migrated.history.manualOperations == original.manualOperations && migrated.history.categoryRules == original.categoryRules && migrated.history.incomeCategoryRules == original.incomeCategoryRules, "manual operations and both rule sets survive")
        let repeatPreview = try StatementImporter.preview([single], into: migrated.history)
        expect(repeatPreview.unchanged && repeatPreview.transferred == 0 && repeatPreview.history.categoryOverrides == migrated.history.categoryOverrides, "repeat migration changes nothing")
        let another = copy(correct, id: "statement:another", description: "Другой магазин")
        let ambiguousResult = StatementImportResult(source: .account, operations: [correct, another], coverageStart: nil, coverageEnd: nil, ignoredAtOrAfterCutoff: 0)
        let ambiguous = try StatementImporter.preview([ambiguousResult], into: original)
        expect(ambiguous.transferred == 0 && ambiguous.ambiguousChoices == 1 && ambiguous.history.categoryOverrides?[correct.identity] == nil, "two matching new rows never guess a category")
        let missing = StatementImportResult(source: .account, operations: [], coverageStart: nil, coverageEnd: nil, ignoredAtOrAfterCutoff: 0)
        let missingPreview = try StatementImporter.preview([missing], into: original)
        expect(missingPreview.ambiguousChoices == 1, "missing matching row is counted")
        // Test income choices independently from expense categorization.
        let income = BankOperation(identity: "statement:income-new", occurredAt: "2026-09-28T09:00:00.000Z", timePrecision: "statement_minute",
            description: "Входящий перевод СБП, Тестовый отправитель", amountKopecks: 900, currency: "RUB", status: "Выполнено",
            category: "Перевод", mcc: nil, purpose: nil, paymentMethod: "Выписка", providers: [], kind: "transfer")
        let oldIncome = copy(income, id: "statement:income-old", description: "28.09.2026 +9,00 ₽")
        original.operations = [oldIncome]; original.categoryOverrides = nil
        original.incomeCategoryOverrides = [oldIncome.identity: "Зарплата и выплаты"]
        let incomeResult = StatementImportResult(source: .account, operations: [income], coverageStart: nil, coverageEnd: nil, ignoredAtOrAfterCutoff: 0)
        let incomePreview = try StatementImporter.preview([incomeResult], into: original)
        expect(incomePreview.transferred == 1 && incomePreview.history.incomeCategoryOverrides?[income.identity] == "Зарплата и выплаты", "income choice follows repaired identity")
        expect(incomePreview.history.incomeCategory(for: income) == "Зарплата и выплаты", "income resolver uses migrated choice")
        // Text fallback also rejects an obviously contaminated description atomically.
        let bad = """
        Яндекс Банк
        Выписка по Договору за период с 01.09.2026 по 30.09.2026
        Договора
        28.09.2026 –1,00 ₽ 29.09.2026
        в 10:00
        29.09.2026 –1,00 ₽ –1,00 ₽
        """
        do { _ = try StatementImporter.parsePages([bad]); expect(false, "contaminated text description must fail") }
        catch { expect(error.localizedDescription.contains("Строка 1 страницы 1"), "ambiguous row error includes location") }
        print("Statement geometry and category migration: multiline PDF, identities, expense/income choices, ambiguity and repeats passed.")
    }
}
