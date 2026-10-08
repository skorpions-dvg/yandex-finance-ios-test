import SwiftUI

private enum QuickReviewDestination: Hashable {
    case group(String)
}

@MainActor
struct UncategorizedReviewView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    @StateObject private var review = QuickReviewState()
    @State private var error: String?

    var body: some View {
        let groups = QuickReviewCache.groups(browser.history, presentation: presentation)
        let suggestions = QuickReviewCache.suggestions(browser.history, presentation: presentation)
        let candidates = QuickReviewCache.candidates(browser.history, presentation: presentation)
        let named = groups.filter { !$0.key.isEmpty }
        let unnamed = groups.filter { $0.key.isEmpty }
        List {
            if groups.isEmpty {
                ContentUnavailableView("Всё разобрано", systemImage: "checkmark.circle")
                    .listRowBackground(Color.clear)
            } else {
                Section { QuickReviewSummary(groups: groups) }
            }
            if !candidates.isEmpty {
                Section("Предложения правил") {
                    ForEach(candidates) { candidate in
                        if let category = browser.history.expenseCategory(id: candidate.categoryID) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(candidate.title).foregroundStyle(.primary)
                                Text("→ \(category.group.name) / \(category.category.name) · \(candidate.operationCount) операций")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Применять всегда") { error = review.apply(candidate, browser: browser) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }.glassRows()
            }
            if !named.isEmpty {
                Section("Получатели") { rows(named, suggestions: suggestions) }.glassRows()
            }
            if !unnamed.isEmpty {
                Section("Без названия") { rows(unnamed, suggestions: suggestions) }.glassRows()
            }
        }
        .appSurface()
        .navigationTitle("Разобрать операции")
        .navigationBarTitleDisplayMode(.inline)
        // A value destination stays alive after its original recipient row is removed by the category choice.
        .navigationDestination(for: QuickReviewDestination.self) { destination in
            switch destination {
            case .group(let id):
                ReviewGroupOperationsView(browser: browser, presentation: presentation, review: review, groupID: id)
            }
        }
        .modifier(QuickReviewUndoModifier(state: review, browser: browser))
        .alert("Не удалось изменить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func rows(_ groups: [ReviewGroup], suggestions: [String: [CategorySuggestion]]) -> some View {
        ForEach(groups) { group in
            NavigationLink(value: QuickReviewDestination.group(group.id)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        Text(group.title).foregroundStyle(.primary)
                        Spacer()
                        Text(QuickReviewCache.money(group.amountKopecks)).monospacedDigit().fixedSize()
                    }
                    if let suggestion = suggestions[group.id]?.first {
                        Text(suggestion.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(group.kind == .expense ? "Расходы" : "Доходы") · \(group.operations.count) операций")
                        .font(.caption).foregroundStyle(.secondary)
                    if let date = group.latestDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

@MainActor
private struct ReviewGroupOperationsView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    @ObservedObject var review: QuickReviewState
    @Environment(\.dismiss) private var dismiss
    @State private var groupID: String
    @State private var error: String?

    init(browser: BankBrowser, presentation: FinancePresentationCache, review: QuickReviewState, groupID: String) {
        self.browser = browser
        self.presentation = presentation
        self.review = review
        _groupID = State(initialValue: groupID)
    }

    var body: some View {
        let groups = QuickReviewCache.groups(browser.history, presentation: presentation)
        let suggestions = QuickReviewCache.suggestions(browser.history, presentation: presentation)
        List {
            if let group = groups.first(where: { $0.id == groupID }), let operation = group.operations.first {
                // Manual entries keep the existing picker until their undo scope is clarified (their category is not an override).
                if group.kind == .expense && !operation.isManual, let options = suggestions[group.id], !options.isEmpty {
                    Section("Подсказки категории") {
                        ForEach(options) { suggestion in
                            Button {
                                apply(suggestion, to: group, groups: groups)
                            } label: { QuickReviewSuggestionLabel(suggestion: suggestion) }
                        }
                    }.glassRows()
                }
                Section {
                    NavigationLink {
                        if group.kind == .expense {
                            QuickReviewCategoryPicker(browser: browser, state: review, operation: operation, appliesToAll: group.appliesToAll)
                        } else {
                            OperationIncomeCategoryView(browser: browser, operation: operation, applyToAll: group.appliesToAll)
                        }
                    } label: {
                        Text(group.kind == .expense ? "Другая категория…" : (group.appliesToAll ? "Выбрать категорию для всех" : "Выбрать категорию"))
                            .foregroundStyle(.primary)
                    }
                }.glassRows()
                Section(group.title) {
                    ForEach(group.operations.sorted {
                        (BankDateParser.parse($0.occurredAt) ?? .distantPast) > (BankDateParser.parse($1.occurredAt) ?? .distantPast)
                    }) { item in
                        NavigationLink {
                            OperationDetailView(browser: browser, operation: item)
                        } label: {
                            HStack {
                                if let date = BankDateParser.parse(item.occurredAt) {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                } else { Text(item.occurredAt) }
                                Spacer()
                                Text(item.formattedAmount)
                            }.font(.subheadline)
                        }
                    }
                }.glassRows()
            } else {
                ContentUnavailableView("Всё разобрано", systemImage: "checkmark.circle")
                    .listRowBackground(Color.clear)
            }
        }
        .appSurface()
        .navigationTitle("Операции получателя")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(QuickReviewUndoModifier(state: review, browser: browser))
        .alert("Не удалось изменить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func apply(_ suggestion: CategorySuggestion, to group: ReviewGroup, groups: [ReviewGroup]) {
        // Follow the displayed order: named payees first, then unnamed operations.
        let ordered = groups.filter { !$0.key.isEmpty } + groups.filter { $0.key.isEmpty }
        let index = ordered.firstIndex { $0.id == group.id }
        error = review.apply(suggestion.categoryID, to: group, browser: browser)
        guard error == nil else { return }
        let remaining = QuickReviewCache.groups(browser.history, presentation: presentation)
        let next = index.flatMap { position in
            ordered.dropFirst(position + 1).first { candidate in remaining.contains { $0.id == candidate.id } }
        }
        if let next { groupID = next.id } else { dismiss() }
    }
}
