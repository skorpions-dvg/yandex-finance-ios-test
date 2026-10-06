import Foundation

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

        print("Statement importer: archive cutoff, own transfers, Split, refunds and deterministic IDs passed.")
    }
}
