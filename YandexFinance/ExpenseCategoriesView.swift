import SwiftUI
import UniformTypeIdentifiers

/// Validate on a copy first: rejected edits never reach the storage writer.
@MainActor
private func saveExpenseCategoryChange(_ browser: BankBrowser,
                                       change: (inout SavedHistory) -> Bool) -> String? {
    var preview = browser.history
    guard change(&preview) else {
        return "Изменение невозможно. Проверьте название, выбранную группу и категорию."
    }
    if !browser.updateUserData({ history in _ = change(&history) }) { return browser.message }
    return nil
}

struct ExpenseCategoriesView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    @State private var editMode: EditMode = .inactive
    @State private var collapsed: Set<UUID> = []
    @State private var newGroup = false
    @State private var newCategory = false
    @State private var editedGroup: ExpenseCategoryGroup?
    @State private var editedCategory: ExpenseCategory?
    @State private var deletion: ExpenseCategoryDeletion?
    @State private var error: String?
    @State private var showCategoryImporter = false
    @State private var importedPlan: ExpenseCategoryImport?

    private var tree: [ExpenseCategoryGroup] { browser.history.categoryTree }
    private var fullItems: [AccountListItem] {
        tree.flatMap { [.group($0.id)] + $0.categories.map { .account($0.id) } }
    }
    private var visibleItems: [AccountListItem] {
        editMode.isEditing ? fullItems : tree.flatMap { group in
            [.group(group.id)] + (collapsed.contains(group.id) ? [] : group.categories.map { .account($0.id) })
        }
    }
    private var monthReport: FinanceReport {
        let start = monthStart(of: Date())
        let end = Calendar.current.date(byAdding: .month, value: 1, to: start)!
        return presentation.report(browser.history, interval: DateInterval(start: start, end: end))
    }

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let lines = monthReport.expenseLines
        List {
            Section {
                Button("Импортировать разметку категорий", systemImage: "square.and.arrow.down") {
                    showCategoryImporter = true
                }
                .disabled(browser.busy || !browser.storageAvailable)
            }.listRowBackground(GlassRowBackground())
            Section {
                Text(Date().formatted(.dateTime.month(.wide).year()))
                    .font(.subheadline).foregroundStyle(.secondary)
            }.listRowBackground(GlassRowBackground())
            Section {
                ForEach(visibleItems, id: \.self) { item in
                    switch item {
                    case .group(let id):
                        if let group = tree.first(where: { $0.id == id }) {
                            groupRow(group, amount: lines.first { $0.title == group.name }?.amountKopecks ?? 0)
                        }
                    case .account(let id):
                        if let pair = browser.history.expenseCategory(id: id) {
                            categoryRow(pair.category, group: pair.group,
                                        amount: lines.first { $0.title == pair.group.name }?.children.first { $0.title == pair.category.name }?.amountKopecks ?? 0)
                        }
                    case .ungroupedHeader: EmptyView()
                    }
                }
                .onMove(perform: move)
                .onDelete { offsets in
                    guard editMode.isEditing, let index = offsets.first else { return }
                    requestDeletion(visibleItems[index])
                }
                .moveDisabled(!editMode.isEditing)
                .deleteDisabled(!editMode.isEditing)
            }.listRowBackground(GlassRowBackground())
            if !(browser.history.categoryRules ?? []).isEmpty {
                Section("Правила") {
                    ForEach(browser.history.categoryRules ?? []) { rule in
                        if let pair = browser.history.expenseCategory(id: rule.categoryID) {
                            Text("\(rule.title) → \(pair.group.name) / \(pair.category.name)")
                                .font(.subheadline)
                        }
                    }
                    .onDelete { offsets in
                        let rules = browser.history.categoryRules ?? []
                        let ids = offsets.compactMap { rules.indices.contains($0) ? rules[$0].id : nil }
                        if !browser.updateUserData({ history in ids.forEach { history.removeCategoryRule($0) } }) {
                            error = browser.message
                        }
                    }
                }.listRowBackground(GlassRowBackground())
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .appSurface()
        .navigationTitle("Категории расходов")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Группа", systemImage: "folder") { newGroup = true }
                    Button("Категория", systemImage: "square.grid.2x2") { newCategory = true }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Добавить")
                Button(editMode.isEditing ? "Готово" : "Изменить",
                       systemImage: editMode.isEditing ? "checkmark" : "pencil") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
        .sheet(isPresented: $newGroup) { ExpenseCategoryFormView(browser: browser, createsGroup: true) }
        .sheet(isPresented: $newCategory) { ExpenseCategoryFormView(browser: browser) }
        .sheet(item: $editedGroup) { ExpenseCategoryFormView(browser: browser, group: $0, createsGroup: true) }
        .sheet(item: $editedCategory) { ExpenseCategoryFormView(browser: browser, category: $0) }
        .sheet(item: $deletion) { ExpenseCategoryMergeView(browser: browser, deletion: $0) }
        .fileImporter(isPresented: $showCategoryImporter, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let plan = try ExpenseCategoryImport.decode(Data(contentsOf: url))
                _ = try plan.preview(browser.history)
                importedPlan = plan
            } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { importedPlan != nil }, set: { if !$0 { importedPlan = nil } })) {
            if let plan = importedPlan { ExpenseCategoryImportPreview(browser: browser, plan: plan) }
        }
        .alert("Не удалось изменить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func groupRow(_ group: ExpenseCategoryGroup, amount: Int64) -> some View {
        Button {
            if editMode.isEditing { editedGroup = group }
            else {
                withAnimation {
                    if collapsed.contains(group.id) { collapsed.remove(group.id) }
                    else { collapsed.insert(group.id) }
                }
            }
        } label: {
            HStack {
                if !editMode.isEditing {
                    Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").foregroundStyle(.secondary)
                }
                Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                Text(money(amount)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Изменить группу", systemImage: "pencil") { editedGroup = group }
            Button("Удалить группу", systemImage: "trash", role: .destructive) { requestDeletion(.group(group.id)) }
        }
    }

    private func categoryRow(_ category: ExpenseCategory, group: ExpenseCategoryGroup, amount: Int64) -> some View {
        let icon = OperationRow.expenseGroupIcon(group.name)
        return Button { editedCategory = category } label: {
            HStack {
                Image(systemName: icon.name).foregroundStyle(icon.color).frame(width: 28)
                Text(category.name).foregroundStyle(.primary)
                Spacer()
                Text(money(amount)).foregroundStyle(.primary)
            }
            .padding(.leading, 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Изменить категорию", systemImage: "pencil") { editedCategory = category }
            Button("Удалить категорию", systemImage: "trash", role: .destructive) { requestDeletion(.account(category.id)) }
        }
    }

    private func money(_ amount: Int64) -> String { (Decimal(amount) / 100).formatted(.currency(code: "RUB")) }

    private func requestDeletion(_ item: AccountListItem) {
        let target: ExpenseCategoryDeletion
        switch item {
        case .group(let id):
            guard let group = tree.first(where: { $0.id == id }) else { return }
            target = ExpenseCategoryDeletion(id: id, name: group.name, isGroup: true)
        case .account(let id):
            guard let pair = browser.history.expenseCategory(id: id) else { return }
            target = ExpenseCategoryDeletion(id: id, name: pair.category.name, isGroup: false)
        case .ungroupedHeader: return
        }
        guard tree.contains(where: { group in
            (!target.isGroup || group.id != target.id) && group.categories.contains { $0.id != target.id }
        }) else {
            error = "Последнюю категорию удалить нельзя. Сначала добавьте категорию для переноса операций."
            return
        }
        deletion = target
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        guard editMode.isEditing, let source = offsets.first, offsets.count == 1 else { return }
        let items = fullItems
        let item = items[source]
        // Reuse the account screen's block drag semantics, including moving a group with its children.
        let moved = AccountListItem.move(items, from: offsets, to: destination)
        guard moved != items else { return }
        switch item {
        case .group(let id):
            let groups = moved.compactMap { item -> UUID? in if case .group(let id) = item { return id }; return nil }
            guard let index = groups.firstIndex(of: id) else { return }
            error = saveExpenseCategoryChange(browser) { $0.moveExpenseGroup(id, to: index) }
        case .account(let id):
            guard let index = moved.firstIndex(of: item),
                  let header = moved[..<index].lastIndex(where: { if case .group = $0 { return true }; return false }),
                  case .group(let groupID) = moved[header] else { return }
            let position = moved[(header + 1)..<index].count
            error = saveExpenseCategoryChange(browser) { $0.moveExpenseCategory(id, toGroup: groupID, at: position) }
        case .ungroupedHeader: break
        }
    }
}

private struct ExpenseCategoryImportPreview: View {
    @ObservedObject var browser: BankBrowser
    let plan: ExpenseCategoryImport
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let result = try? plan.preview(browser.history) {
                    Section {
                        Text("Назначить категории: \(result.assigned)")
                        Text("Перенести категории между группами: \(result.moved)")
                        if result.skipped > 0 {
                            Text("Пропущено: \(result.skipped). Операции уже размечены, изменились или отсутствуют.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("Суммы, даты, счета и история сохранятся. Разметка применяется только к указанным в файле операциям.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.listRowBackground(GlassRowBackground())
                    Section("Категории назначения") {
                        ForEach(result.destinations.keys.sorted(), id: \.self) { path in
                            LabeledContent(path.replacingOccurrences(of: "/", with: " → "),
                                           value: String(result.destinations[path] ?? 0))
                        }
                    }.listRowBackground(GlassRowBackground())
                }
            }
            .appSurface()
            .navigationTitle("Разметка категорий")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Применить") {
                        do {
                            let result = try plan.preview(browser.history)
                            guard result.assigned > 0 || result.moved > 0 else {
                                error = "Все назначения уже применены или операции изменились."
                                return
                            }
                            if browser.updateUserData({ $0 = result.history }) {
                                browser.message = "Разметка применена: \(result.assigned) операций, \(result.moved) перенесённых категорий."
                                dismiss()
                            } else { error = browser.message }
                        } catch { self.error = error.localizedDescription }
                    }.disabled(browser.busy || !browser.storageAvailable)
                }
            }
            .alert("Разметка не применена", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

private struct ExpenseCategoryFormView: View {
    @ObservedObject var browser: BankBrowser
    @Environment(\.dismiss) private var dismiss
    let group: ExpenseCategoryGroup?
    let category: ExpenseCategory?
    let createsGroup: Bool
    @State private var name: String
    @State private var groupID: UUID?
    @State private var fixedCosts: Bool
    @State private var error: String?

    init(browser: BankBrowser, group: ExpenseCategoryGroup? = nil, category: ExpenseCategory? = nil, createsGroup: Bool = false) {
        self.browser = browser
        self.group = group
        self.category = category
        self.createsGroup = createsGroup
        _name = State(initialValue: group?.name ?? category?.name ?? "")
        _groupID = State(initialValue: browser.history.categoryTree.first?.id)
        _fixedCosts = State(initialValue: group?.isFixedCosts ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $name)
                if createsGroup {
                    Section {
                        Toggle("Обязательные платежи", isOn: $fixedCosts)
                    } footer: { Text("Крупные платежи этой группы не считаются разовыми в прогнозе") }.listRowBackground(GlassRowBackground())
                } else if category == nil {
                    Picker("Группа", selection: $groupID) {
                        Text("Выберите группу").tag(nil as UUID?)
                        ForEach(browser.history.categoryTree) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            .tint(.orange)
            .appSurface()
            .navigationTitle(createsGroup ? (group == nil ? "Новая группа" : "Группа") : (category == nil ? "Новая категория" : "Категория"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить", systemImage: "checkmark", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!createsGroup && category == nil && groupID == nil))
                }
            }
        }
        .alert("Не удалось сохранить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save() {
        error = saveExpenseCategoryChange(browser) { history in
            if createsGroup {
                if let group {
                    return history.renameExpenseGroup(group.id, to: name) && history.setFixedCosts(fixedCosts, groupID: group.id)
                }
                guard let id = history.addExpenseGroup(name: name) else { return false }
                return history.setFixedCosts(fixedCosts, groupID: id)
            }
            if let category { return history.renameExpenseCategory(category.id, to: name) }
            guard let groupID else { return false }
            return history.addExpenseCategory(name: name, groupID: groupID) != nil
        }
        if error == nil { dismiss() }
    }
}

private struct ExpenseCategoryDeletion: Identifiable {
    let id: UUID
    let name: String
    let isGroup: Bool
}

private struct ExpenseCategoryMergeView: View {
    @ObservedObject var browser: BankBrowser
    @Environment(\.dismiss) private var dismiss
    let deletion: ExpenseCategoryDeletion
    @State private var targetID: UUID?
    @State private var confirm = false
    @State private var error: String?

    private var targetName: String {
        targetID.flatMap { browser.history.expenseCategory(id: $0) }.map { "\($0.group.name) / \($0.category.name)" } ?? ""
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(browser.history.categoryTree.filter { !deletion.isGroup || $0.id != deletion.id }) { group in
                    let categories = group.categories.filter { $0.id != deletion.id }
                    if !categories.isEmpty {
                        Section(group.name) {
                            ForEach(categories) { category in
                                Button { targetID = category.id; confirm = true } label: {
                                    Text(category.name).foregroundStyle(.primary)
                                }
                            }
                        }.listRowBackground(GlassRowBackground())
                    }
                }
            }
            .appSurface()
            .navigationTitle("Куда перенести операции?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Отмена", systemImage: "xmark") { dismiss() } } }
        }
        .confirmationDialog("Удалить „\(deletion.name)“? Операции перейдут в „\(targetName)“", isPresented: $confirm, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                guard let targetID else { return }
                error = saveExpenseCategoryChange(browser) { history in
                    deletion.isGroup ? history.deleteExpenseGroup(deletion.id, mergingInto: targetID) : history.deleteExpenseCategory(deletion.id, mergingInto: targetID)
                }
                if error == nil { dismiss() }
            }
            Button("Отмена", role: .cancel) { }
        }
        .alert("Не удалось удалить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct OperationExpenseCategoryView: View {
    @ObservedObject var browser: BankBrowser
    @Environment(\.dismiss) private var dismiss
    let operation: BankOperation
    @State private var forPayee = true
    @State private var error: String?

    var body: some View {
        let selectedID = browser.history.expenseCategoryID(for: operation)
        List {
            ForEach(browser.history.categoryTree) { group in
                Section(group.name) {
                    ForEach(group.categories) { category in
                        Button {
                            error = saveExpenseCategoryChange(browser) {
                                $0.setExpenseCategory(category.id, for: operation, forPayee: forPayee)
                            }
                            if error == nil { dismiss() }
                        } label: {
                            HStack {
                                Text(category.name).foregroundStyle(.primary)
                                Spacer()
                                if selectedID == category.id {
                                    Image(systemName: "checkmark").foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }.listRowBackground(GlassRowBackground())
            }
            Section {
                Toggle("Для всех операций „\(operation.description)“", isOn: $forPayee)
            } footer: {
                Text("Прошлые и будущие расходы этого получателя тоже перейдут в эту категорию")
            }.listRowBackground(GlassRowBackground())
        }
        .tint(.orange)
        .appSurface()
        .navigationTitle("Категория")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Не удалось изменить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
