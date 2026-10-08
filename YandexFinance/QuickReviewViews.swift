import SwiftUI

extension CategorySuggestion {
    var explanation: String {
        switch reason {
        case .history: return "по прошлым покупкам"
        case .words: return "по словам в названии"
        case .similarPayees: return "по похожим получателям"
        }
    }
    var label: String { group + " / " + subcategory + " · " + explanation }
}

/// Shared by the list and its group destination so undo survives advancing or returning to the list.
@MainActor
final class QuickReviewState: ObservableObject {
    typealias Undo = ExpenseReviewUndo

    @Published private(set) var undo: Undo?
    private var expiration: Task<Void, Never>?

    func offerUndo(_ previous: Undo) {
        expiration?.cancel()
        undo = previous
        expiration = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            guard self?.undo?.id == previous.id else { return }
            self?.undo = nil
        }
    }

    func apply(_ categoryID: UUID, to group: ReviewGroup, browser: BankBrowser) -> String? {
        let previous = Undo(browser.history)
        let error = saveExpenseCategoryChange(browser) { history in
            ExpenseReviewEdits.apply(categoryID, to: group, history: &history)
        }
        if error == nil && previous.changed(in: browser.history) { offerUndo(previous) }
        return error
    }

    func apply(_ candidate: RuleCandidate, browser: BankBrowser) -> String? {
        let resolver = ExpenseCategoryResolver(browser.history)
        guard let operation = browser.history.operations.first(where: {
            !$0.isManual && FinancialEngine.payeeRuleKey($0.description) == candidate.payeeKey && resolver.resolve($0) != nil
        }) else { return "Получатель больше не найден. Обновите список." }
        let previous = Undo(browser.history)
        let error = saveExpenseCategoryChange(browser) {
            $0.setExpenseCategory(candidate.categoryID, for: operation, forPayee: true)
        }
        if error == nil { offerUndo(previous) }
        return error
    }

    func cancelApplication(browser: BankBrowser) -> String? {
        guard let previous = undo else { return nil }
        // Restore category settings only; bank sync, accounts and other edits keep their current values.
        guard browser.updateUserData({ history in
            previous.restore(in: &history)
        }) else { return browser.message }
        expiration?.cancel()
        undo = nil
        return nil
    }
}

enum QuickReviewCache {
    static func groups(_ history: SavedHistory, presentation: FinancePresentationCache) -> [ReviewGroup] {
        presentation.prepare(history)
        return presentation.value("uncategorized") { UncategorizedReview.groups(history) }
    }

    static func suggestions(_ history: SavedHistory, presentation: FinancePresentationCache) -> [String: [CategorySuggestion]] {
        let pending = groups(history, presentation: presentation)
        return presentation.value("quick-review-suggestions") {
            Dictionary(uniqueKeysWithValues: pending.map { ($0.id, CategorySuggestions.suggest(for: $0, history: history)) })
        }
    }

    static func candidates(_ history: SavedHistory, presentation: FinancePresentationCache) -> [RuleCandidate] {
        presentation.prepare(history)
        return presentation.value("quick-review-rules") { CategorySuggestions.ruleCandidates(history) }
    }

    static func money(_ amount: Decimal) -> String { (amount / 100).formatted(.currency(code: "RUB")) }
}

struct QuickReviewSummary: View {
    let groups: [ReviewGroup]
    var body: some View {
        Text("Осталось \(groups.count) получателей · \(groups.reduce(0) { $0 + $1.operations.count }) операций · \(QuickReviewCache.money(groups.reduce(Decimal.zero) { $0 + $1.amountKopecks }))")
            .font(.subheadline).foregroundStyle(.primary)
            .listRowBackground(Color.clear)
    }
}

struct QuickReviewSuggestionLabel: View {
    let suggestion: CategorySuggestion
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(suggestion.group + " / " + suggestion.subcategory).foregroundStyle(.primary)
            Text(suggestion.explanation).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct QuickReviewUndoPanel: View {
    @ObservedObject var state: QuickReviewState
    @ObservedObject var browser: BankBrowser
    @State private var error: String?
    var body: some View {
        HStack {
            Text("Применено").foregroundStyle(.primary)
            Spacer()
            Button("Отменить") { error = state.cancelApplication(browser: browser) }
        }
        .font(.subheadline).padding()
        .background { GlassRowBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20).padding(.top, 8)
        .alert("Не удалось отменить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

@MainActor
struct QuickReviewUndoModifier: ViewModifier {
    @ObservedObject var state: QuickReviewState
    @ObservedObject var browser: BankBrowser
    @Environment(\.bottomBarSpace) private var bottomBarSpace
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if state.undo != nil {
                QuickReviewUndoPanel(state: state, browser: browser)
                    .padding(.bottom, bottomBarSpace)
            }
        }
    }
}

/// The existing picker stays intact; capture only category settings when it opens, offer undo when it returns.
@MainActor
struct QuickReviewCategoryPicker: View {
    @ObservedObject var browser: BankBrowser
    @ObservedObject var state: QuickReviewState
    let operation: BankOperation
    let appliesToAll: Bool
    @State private var previous: QuickReviewState.Undo?

    var body: some View {
        OperationExpenseCategoryView(browser: browser, operation: operation, applyToAll: appliesToAll)
            .onAppear { previous = QuickReviewState.Undo(browser.history) }
            .onDisappear {
                if let previous, previous.changed(in: browser.history) { state.offerUndo(previous) }
            }
    }
}
