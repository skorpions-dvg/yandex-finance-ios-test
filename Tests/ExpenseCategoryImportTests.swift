import Foundation

@main
struct ExpenseCategoryImportTests {
    static func main() throws {
        let expense = operation("purchase", amount: -12500)
        let transfer = operation("transfer", amount: -4500000, kind: "transfer", category: "Перевод")
        let income = operation("income", amount: 10000, kind: "unclassified_income")
        var original = SavedHistory()
        original.operations = [expense, transfer, income]
        let assignment = ExpenseCategoryImport.Assignment(identity: expense.identity, description: expense.description,
            occurredAt: expense.occurredAt, amountKopecks: expense.amountKopecks,
            fromPath: "Другое/Прочее", toPath: "Еда/Супермаркеты")
        let move = ExpenseCategoryImport.Move(fromGroup: "Другое", category: "Переводы другим", toGroup: "Переводы")
        let plan = ExpenseCategoryImport(format: "finance-test-category-plan-v1", moves: [move], assignments: [assignment])
        let roundTrip = try ExpenseCategoryImport.decode(JSONEncoder().encode(plan))
        let result = try roundTrip.preview(original)
        precondition(result.assigned == 1 && result.moved == 1 && result.skipped == 0)
        precondition(result.history.operations == original.operations)
        precondition(result.history.accounts == original.accounts)
        precondition(result.history.manualOperations == original.manualOperations)
        precondition(result.history.financialInput(for: expense).categoryPath == "Еда/Супермаркеты")
        precondition(result.history.financialInput(for: transfer).categoryPath == "Переводы/Переводы другим")
        precondition(result.history.expenseCategoryID(for: income) == nil)
        let repeatResult = try plan.preview(result.history)
        precondition(repeatResult.assigned == 0 && repeatResult.moved == 0 && repeatResult.skipped == 1)
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 2_000_000_000))
        let before = FinancialEngine.report(original.financialInputs, in: interval, taxonomy: original.expenseTaxonomy)
        let after = FinancialEngine.report(result.history.financialInputs, in: interval, taxonomy: result.history.expenseTaxonomy)
        precondition(before.grossExpenseKopecks == after.grossExpenseKopecks && before.incomeKopecks == after.incomeKopecks)

        var edited = original
        let category = edited.categoryTree[0].categories[1].id
        precondition(edited.setExpenseCategory(category, for: expense, forPayee: true))
        let editedResult = try plan.preview(edited)
        precondition(editedResult.assigned == 0)
        var changed = original
        changed.operations = [operation("purchase", amount: -13000), transfer, income]
        let changedResult = try plan.preview(changed)
        precondition(changedResult.assigned == 0)
        let invalid = ExpenseCategoryImport.Assignment(identity: expense.identity, description: expense.description,
            occurredAt: expense.occurredAt, amountKopecks: expense.amountKopecks,
            fromPath: "Другое/Прочее", toPath: "Нет/Категории")
        do {
            _ = try ExpenseCategoryImport(format: plan.format, moves: [move], assignments: [assignment, invalid]).preview(original)
            preconditionFailure("Invalid plan accepted")
        } catch {}
        precondition(original.expenseCategories == nil && original.categoryOverrides == nil)
        do {
            _ = try ExpenseCategoryImport.decode(Data("{\"format\":1,\"history\":{}}".utf8))
            preconditionFailure("Backup accepted as assignments")
        } catch { precondition(error.localizedDescription.contains("резервная копия")) }
        do {
            _ = try ExpenseCategoryImport.decode(Data("{\"operations\":[]}".utf8))
            preconditionFailure("Manual review list accepted as assignments")
        } catch { precondition(error.localizedDescription.contains("ручного разбора")) }
        do {
            _ = try ExpenseCategoryImport.decode(Data())
            preconditionFailure("Empty provider file accepted")
        } catch { precondition(error.localizedDescription.contains("Файл пуст")) }
        print("Category import checks passed: preservation, totals, transfers, stale data, existing rules, repeat import and rejection")
    }

    static func operation(_ identity: String, amount: Int64, kind: String = "expense", category: String = "Не определено") -> BankOperation {
        BankOperation(identity: identity, occurredAt: "2026-09-05T12:00:00Z", timePrecision: "source_timestamp",
            description: "Synthetic \(identity)", amountKopecks: amount, currency: "RUB", status: "Выполнено",
            category: category, mcc: nil, purpose: nil, paymentMethod: nil, providers: [], kind: kind)
    }
}

