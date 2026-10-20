import SwiftUI

func accountColor(_ name: String) -> Color {
    switch name {
    case "orange": return .orange
    case "red": return .red
    case "yellow": return .yellow
    case "green": return .green
    case "teal": return .teal
    case "blue": return .blue
    case "indigo": return .indigo
    case "purple": return .purple
    case "pink": return .pink
    default: return .gray
    }
}

private func accountMoney(_ kopecks: Int64) -> String {
    (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
}

private func accountBalance(_ account: Account, history: SavedHistory) -> Int64 {
    account.balance(bankOperations: history.operations.map(\.financialInput),
                    manual: history.manualOperations ?? [])
}

struct AccountsView: View {
    @ObservedObject var browser: BankBrowser
    var onClose: (() -> Void)? = nil
    var usesGlass = false
    var onHorizontalPan: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }
    @State private var presentation = FinancePresentationCache()
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var collapsed: Set<UUID> = []
    @State private var editedAccount: Account?
    @State private var detailedAccount: Account?
    @State private var editedGroup: AccountGroup?
    @State private var newAccount = false
    @State private var newGroup = false
    @State private var deletedAccounts: Set<UUID> = []
    @State private var confirmAccountDeletion = false
    @State private var deletedGroup: AccountGroup?
    @State private var confirmGroupDeletion = false
    @State private var showsInfo = true
    @State private var saveError = false
    /// The eyes just tapped, shown at once while the change is being saved (saving and redrawing the balances takes a moment).
    @State private var accountEyes: [UUID: Bool] = [:]
    @State private var groupEyes: [UUID: Bool] = [:]
    /// The number of the latest tap on each eye: only that tap saves and clears what is shown (quick taps are merged).
    @State private var eyeTaps: [UUID: Int] = [:]

    private var accounts: [Account] { browser.history.accounts ?? [] }
    private var groups: [AccountGroup] { browser.history.accountGroups ?? [] }

    var body: some View {
        let _ = presentation.prepare(browser.history)
        Group {
            if usesGlass {
                accountContent
            } else {
                NavigationStack { accountContent }
            }
        }
        .sheet(isPresented: $newAccount) {
            AccountFormView(browser: browser, account: nil, showsInfo: $showsInfo)
        }
        .sheet(item: $editedAccount) { account in
            AccountFormView(browser: browser, account: account, showsInfo: $showsInfo)
        }
        .sheet(item: $detailedAccount) { account in
            AccountDetailView(browser: browser, account: account, showsInfo: $showsInfo)
        }
        .sheet(isPresented: $newGroup) { AccountGroupFormView(browser: browser, group: nil) }
        .sheet(item: $editedGroup) { group in AccountGroupFormView(browser: browser, group: group) }
        .confirmationDialog("Удалить счёт? Операции банка не удаляются.",
                            isPresented: $confirmAccountDeletion, titleVisibility: .visible) {
            Button("Удалить счёт", role: .destructive) {
                persist { history in history.accounts?.removeAll { deletedAccounts.contains($0.id) } }
                deletedAccounts = []
            }
            Button("Отмена", role: .cancel) { deletedAccounts = [] }
        }
        .confirmationDialog("Удалить группу?", isPresented: $confirmGroupDeletion, titleVisibility: .visible) {
            Button("Удалить группу", role: .destructive) { deleteGroup() }
            Button("Отмена", role: .cancel) { deletedGroup = nil }
        } message: {
            Text("Счета останутся в разделе «Без группы».")
        }
        .alert("Не удалось сохранить", isPresented: $saveError) {
            Button("OK", role: .cancel) { }
        } message: { Text(browser.message) }
    }

    // The glass drawer has no navigation container: its material cannot extend into the status bar.
    private var accountContent: some View {
            List {
                Section {
                    HStack {
                        Label("Все счета", systemImage: "wallet.pass")
                        Spacer()
                        Text(total(accounts)).bold().multilineTextAlignment(.trailing)
                    }
                    .moveDisabled(true)
                    .deleteDisabled(true)
                    .listRowBackground(usesGlass ? Color.clear : Color(uiColor: .systemBackground))
                }
                accountList.listRowBackground(usesGlass ? Color.clear : Color(uiColor: .systemBackground))
                if accounts.isEmpty && groups.isEmpty {
                    ContentUnavailableView("Счетов пока нет", systemImage: "wallet.pass",
                                           description: Text("Добавьте наличные, банковскую карту или копилку."))
                    Button("Создать стандартные группы", action: createStandardGroups)
                }
            }
            .environment(\.editMode, $editMode)
            .listStyle(.plain)
            .font(usesGlass ? .subheadline : .body)
            .scrollContentBackground(.hidden)
            .containerBackground(Color.clear, for: .navigation)
            .presentationBackground { WallpaperBackground() }
            .toolbarBackground(usesGlass ? .hidden : .automatic, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if usesGlass { compactHeader }
            }
            .toolbar(usesGlass ? .hidden : .visible, for: .navigationBar)
            .navigationTitle("Счета")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть", systemImage: "xmark") {
                        if let onClose { onClose() } else { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button("Новый счёт", systemImage: "wallet.pass") { newAccount = true }
                        Button("Новая группа", systemImage: "folder") { newGroup = true }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить")
                    Button(editMode.isEditing ? "Готово" : "Изменить",
                           systemImage: editMode.isEditing ? "checkmark" : "pencil") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
            }
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            Button("Закрыть", systemImage: "xmark") {
                if let onClose { onClose() } else { dismiss() }
            }
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            Text("Счета").font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Button("Новый счёт", systemImage: "wallet.pass") { newAccount = true }
                Button("Новая группа", systemImage: "folder") { newGroup = true }
            } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
            .accessibilityLabel("Добавить")
            Button(editMode.isEditing ? "Готово" : "Изменить", systemImage: editMode.isEditing ? "checkmark" : "pencil") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var accountList: some View {
        let accountsByGroup = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.groupID) })
        let fullItems = AccountListItem.flatten(groups: groups, accounts: accounts)
        let items = editMode.isEditing ? fullItems : fullItems.filter { item in
            if case .account(let id) = item, let groupID = accountsByGroup[id] ?? nil {
                return !collapsed.contains(groupID)
            }
            return true
        }
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        return Section {
            ForEach(items, id: \.self) { item in
                switch item {
                case .group(let id):
                    if let group = groupsByID[id] {
                        groupHeader(group)
                            .moveDisabled(!editMode.isEditing)
                            // No red minus in edit mode and no row swipe (the drawer itself closes by swiping):
                            // a group is deleted from its context menu, an account from its form.
                            .deleteDisabled(true)
                    }
                case .account(let id):
                    if let account = accountsByID[id] {
                        accountRow(account).padding(.leading, 20)
                            .moveDisabled(!editMode.isEditing)
                            // No red minus in edit mode and no row swipe (the drawer itself closes by swiping):
                            // a group is deleted from its context menu, an account from its form.
                            .deleteDisabled(true)
                    }
                case .ungroupedHeader:
                    HStack {
                        Text("Без группы").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(total(accounts.filter { account in
                            account.groupID.map { id in !groups.contains { $0.id == id } } ?? true
                        })).foregroundStyle(.secondary)
                    }
                        .moveDisabled(true)
                        .deleteDisabled(true)
                }
            }
            .onMove { source, destination in
                guard editMode.isEditing else { return }
                let moved = AccountListItem.move(items, from: source, to: destination)
                let result = AccountListItem.apply(moved, groups: groups, accounts: accounts)
                persist { history in
                    history.accountGroups = result.groups
                    history.accounts = result.accounts
                }
            }
            .onDelete { offsets in
                guard editMode.isEditing, let index = offsets.first else { return }
                switch items[index] {
                case .group(let id):
                    deletedGroup = groupsByID[id]
                    confirmGroupDeletion = deletedGroup != nil
                case .account(let id):
                    deletedAccounts = [id]
                    confirmAccountDeletion = true
                case .ungroupedHeader:
                    break
                }
            }
        }
    }

    private func cachedBalance(_ account: Account) -> Int64 {
        presentation.accountBalance(account, history: browser.history)
    }

    /// The sum of the accounts; a credit card is the bank's money and is not added (a group of cards alone shows its debt).
    private func total(_ accounts: [Account]) -> String {
        let cards = accounts.filter(\.isCreditCard)
        let own = accounts.filter { !$0.isCreditCard }
        if own.isEmpty && !cards.isEmpty {
            let debt = cards.reduce(Int64(0)) { $0 + CreditCards.debt(limit: $1.creditLimitKopecks ?? 0, balance: cachedBalance($1)) }
            return "долг " + accountMoney(debt)
        }
        return accountMoney(own.reduce(0) { $0 + cachedBalance($1) })
    }

    private func groupHeader(_ group: AccountGroup) -> some View {
        HStack {
            Button {
                // While editing, a tap on a group opens its name; deleting stays in the long-press menu.
                guard !editMode.isEditing else { editedGroup = group; return }
                withAnimation {
                    if collapsed.contains(group.id) { collapsed.remove(group.id) }
                    else { collapsed.insert(group.id) }
                }
            } label: {
                HStack {
                    if !editMode.isEditing {
                        Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    // One line in every mode: the name shortens, the amount shrinks slightly instead of wrapping.
                    Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    if !editMode.isEditing {
                        Text(total(accounts.filter { $0.groupID == group.id }))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(!editMode.isEditing && collapsed.contains(group.id) ? "Свёрнуто" : "Развёрнуто")
            if editMode.isEditing {
                let included = groupEyes[group.id] ?? (group.includesInBalance != false)
                Button { toggleGroupBalance(group) } label: {
                    Image(systemName: included ? "eye" : "eye.slash")
                        .font(.caption)
                        .foregroundStyle(included ? Color.primary : Color.secondary)
                        .frame(width: 30, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(included ? "Исключить группу из текущего остатка" : "Учитывать группу в текущем остатке")
            }
        }
        .contextMenu { groupActions(group) }
    }

    private func toggleGroupBalance(_ group: AccountGroup) {
        // The state now, not the one the row was drawn with: a second quick tap turns it back.
        let saved = browser.history.accountGroups?.first(where: { $0.id == group.id })?.includesInBalance != false
        groupEyes[group.id] = !(groupEyes[group.id] ?? saved)
        saveEye(group.id, save: {
            guard let include = groupEyes[group.id] else { return }
            persist { history in
                guard let index = history.accountGroups?.firstIndex(where: { $0.id == group.id }) else { return }
                history.accountGroups?[index].includesInBalance = include
            }
        }, clear: { groupEyes[group.id] = nil })
    }

    private func toggleAccountBalance(_ account: Account) {
        let saved = browser.history.accounts?.first(where: { $0.id == account.id })?.showsBalance ?? account.showsBalance
        accountEyes[account.id] = !(accountEyes[account.id] ?? saved)
        saveEye(account.id, save: {
            guard let shows = accountEyes[account.id] else { return }
            persist { history in
                guard let index = history.accounts?.firstIndex(where: { $0.id == account.id }) else { return }
                history.accounts?[index].showsBalance = shows
            }
        }, clear: { accountEyes[account.id] = nil })
    }

    /// The tapped icon is drawn at once; the latest state of the eye is saved a moment later. A newer tap on the same eye takes
    /// over: the older one neither saves nor clears what is shown.
    private func saveEye(_ id: UUID, save: @escaping @MainActor () -> Void, clear: @escaping @MainActor () -> Void) {
        let tap = (eyeTaps[id] ?? 0) + 1
        eyeTaps[id] = tap
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard eyeTaps[id] == tap else { return }
            save()
            clear()
        }
    }

    @ViewBuilder private func groupActions(_ group: AccountGroup) -> some View {
        Button("Переименовать", systemImage: "pencil") { editedGroup = group }
        Button(group.includesInBalance == false ? "Учитывать в общем балансе" : "Исключить из общего баланса",
               systemImage: group.includesInBalance == false ? "eye" : "eye.slash") {
            toggleGroupBalance(group)
        }
        Button("Удалить группу", systemImage: "trash", role: .destructive) {
            deletedGroup = group
            confirmGroupDeletion = true
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack {
            Button {
                if editMode.isEditing { editedAccount = account }
                else { detailedAccount = account }
            } label: {
                HStack {
                    Image(systemName: account.icon)
                        .foregroundStyle(accountColor(account.color))
                        .frame(width: 28, height: 28)
                        .background(accountColor(account.color).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail)
                        // The bank shows another balance: what it shows (the card of the account explains the difference).
                        if !editMode.isEditing, account.isCreditCard {
                            Text("Долг \(accountMoney(CreditCards.debt(limit: account.creditLimitKopecks ?? 0, balance: cachedBalance(account))))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if !editMode.isEditing, let bank = browser.history.bankBalance(for: account), bank != cachedBalance(account) {
                            Text("банк: \(accountMoney(bank))").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 6)
                    // Amounts return after «Готово»; while editing the full name has the room.
                    if !editMode.isEditing {
                        Text(accountMoney(cachedBalance(account)))
                            .foregroundStyle(.primary)
                            .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if editMode.isEditing {
                let shows = accountEyes[account.id] ?? account.showsBalance
                Button {
                    toggleAccountBalance(account)
                } label: {
                    Image(systemName: shows ? "eye" : "eye.slash")
                        .font(.caption)
                        .foregroundStyle(shows ? Color.primary : Color.secondary)
                        .frame(width: 30, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(shows ? "Исключить счёт из текущего остатка" : "Учитывать счёт в текущем остатке")
            }
        }
    }

    private func deleteGroup() {
        guard let group = deletedGroup else { return }
        persist { history in
            history.accountGroups?.removeAll { $0.id == group.id }
            var accounts = history.accounts ?? []
            for index in accounts.indices where accounts[index].groupID == group.id { accounts[index].groupID = nil }
            history.accounts = accounts
        }
        deletedGroup = nil
    }

    private func createStandardGroups() {
        persist { history in
            guard (history.accountGroups ?? []).isEmpty, (history.accounts ?? []).isEmpty else { return }
            history.accountGroups = ["Наличные", "Банковские карты", "Копилки (цели)"].map { AccountGroup(name: $0) }
            history.accounts = []
        }
    }

    private func persist(_ change: (inout SavedHistory) -> Void) {
        if !browser.updateUserData(change) { saveError = true }
    }
}

struct AccountFormView: View {
    @ObservedObject var browser: BankBrowser
    @Environment(\.dismiss) private var dismiss
    private let account: Account?
    private let sessionInfo: Binding<Bool>?
    @State private var localInfo = true
    @State private var name: String
    @State private var icon: String
    @State private var color: String
    @State private var balanceText: String
    @State private var showsBalance: Bool
    @State private var tracksBankCard: Bool
    @State private var tracksSave: Bool
    @State private var isCredit: Bool
    @State private var limitText: String
    @State private var groupID: UUID?
    @State private var showsIcons = false
    @State private var confirmDeletion = false
    @State private var saveError = false

    private let icons = AppSymbols.all.map(\.symbol)
    private let iconNames = AppSymbols.all.map(\.name)

    init(browser: BankBrowser, account: Account?, showsInfo: Binding<Bool>? = nil) {
        self.browser = browser
        self.account = account
        sessionInfo = showsInfo
        _name = State(initialValue: account?.name ?? "")
        _icon = State(initialValue: account?.icon ?? "banknote")
        _color = State(initialValue: account?.color ?? "orange")
        // A credit card keeps its debt at creation in this field (the balance is the limit less the debt).
        _balanceText = State(initialValue: account.map { saved in
            saved.isCreditCard
                ? (Decimal(CreditCards.debt(limit: saved.creditLimitKopecks ?? 0, balance: saved.startBalanceKopecks)) / 100).description
                : (Decimal(saved.startBalanceKopecks) / 100).description
        } ?? "0")
        _isCredit = State(initialValue: account?.isCreditCard ?? false)
        _limitText = State(initialValue: account?.creditLimitKopecks.map { (Decimal($0) / 100).description } ?? "")
        _showsBalance = State(initialValue: account?.showsBalance ?? true)
        _tracksBankCard = State(initialValue: account?.tracksBankCard ?? false)
        _tracksSave = State(initialValue: account?.tracksSave ?? false)
        let groups = browser.history.accountGroups ?? []
        _groupID = State(initialValue: groups.contains { $0.id == account?.groupID } ? account?.groupID : nil)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var infoVisible: Bool { sessionInfo?.wrappedValue ?? localInfo }

    var body: some View {
        NavigationStack {
            Form {
                if infoVisible { infoBanner }
                Section {
                    TextField("Название", text: $name)
                } footer: { Text("Например, «Наличные» или «Карта».") }.glassRows()
                Section {
                    Button { showsIcons.toggle() } label: {
                        HStack {
                            Text("Иконка").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: icon).foregroundStyle(accountColor(color))
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    if showsIcons { iconGrid }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Цвет")
                        colorPicker
                    }
                }.glassRows()
                Section {
                    Toggle("Кредитная карта", isOn: $isCredit)
                        .onChange(of: isCredit) { _, on in if on && account == nil { showsBalance = false } }
                    if isCredit {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Кредитный лимит")
                            TextField("Лимит", text: $limitText).keyboardType(.decimalPad)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.18)))
                        }
                        if (parsedLimit ?? 0) <= 0 {
                            Text("Введите лимит с точностью до копеек.").font(.footnote).foregroundStyle(.red)
                        }
                    }
                } footer: {
                    if isCredit {
                        Text("Остаток счёта — доступные деньги: лимит минус долг. Покупки уменьшают его, платёж (перевод на карту) увеличивает. Минимальный платёж, льготный период и проценты не считаются: сверяйте цифры с банком. Такой счёт по умолчанию не входит в общий остаток.")
                    }
                }.glassRows()
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(isCredit ? (account == nil ? "Текущий долг" : "Долг на момент создания")
                                      : (account == nil ? "Начальный баланс" : "Остаток на момент создания"))
                        TextField("Сумма", text: $balanceText).keyboardType(.decimalPad)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.18)))
                    }
                    if let account {
                        Text((isCredit ? "Доступно сейчас: " : "Текущий остаток: ") + accountMoney(accountBalance(account, history: browser.history)))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if parsedBalance == nil {
                        Text("Введите сумму с точностью до копеек.").font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text(isCredit ? "Сколько уже потрачено с карты (для новой карты — 0). Дальше остаток меняется операциями."
                                  : "Остаток на счёте сейчас. Дальше он меняется операциями.")
                }.glassRows()
                Section {
                    Toggle("Учитывать счёт в текущем остатке", isOn: $showsBalance)
                }.glassRows()
                Section {
                    Toggle("Карта Яндекс Банка", isOn: $tracksBankCard)
                        .onChange(of: tracksBankCard) { _, isOn in if isOn { tracksSave = false } }
                    Toggle("Сейв Яндекс Банка", isOn: $tracksSave)
                        .onChange(of: tracksSave) { _, isOn in if isOn { tracksBankCard = false } }
                } footer: {
                    Text("Операции, загруженные из банка, меняют остаток такого счёта: карты — её покупки и переводы, Сейва — проценты и переводы с карты и на карту. Введите остаток, как в банке, и сохраните: дальше приложение считает от него. Сверить с банком можно в любой момент: введите остаток из банка и сохраните.")
                }.glassRows()
                Section {
                    Picker("Группа", selection: $groupID) {
                        Text("Без группы").tag(nil as UUID?)
                        ForEach(browser.history.accountGroups ?? []) { group in
                            Text(group.name).tag(Optional(group.id))
                        }
                    }
                }.glassRows()
                if account != nil {
                    Section {
                        Button("Удалить счёт", role: .destructive) { confirmDeletion = true }
                    }.glassRows()
                }
            }
            .tint(.accentColor)
            .appSurface()
            .navigationTitle(account == nil ? "Новый счёт" : "Счёт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить", systemImage: "checkmark", action: save)
                        .tint(.accentColor).disabled(trimmedName.isEmpty || parsedBalance == nil || (isCredit && (parsedLimit ?? 0) <= 0))
                }
            }
        }
        .confirmationDialog("Удалить счёт? Операции банка не удаляются.",
                            isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Удалить счёт", role: .destructive, action: delete)
            Button("Отмена", role: .cancel) { }
        }
        .alert("Не удалось сохранить", isPresented: $saveError) {
            Button("OK", role: .cancel) { }
        } message: { Text(browser.message) }
    }

    private var infoBanner: some View {
        HStack(alignment: .top) {
            Text("Счёт отражает один из ваших счетов, будь то наличные, счёт в банке или копилка.")
                .font(.subheadline)
            Spacer(minLength: 8)
            Button {
                localInfo = false
                sessionInfo?.wrappedValue = false
            } label: { Image(systemName: "xmark").font(.caption) }
            .buttonStyle(.plain).accessibilityLabel("Скрыть подсказку")
        }
        .foregroundStyle(.white)
        .listRowBackground(Color.blue)
    }

    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
            ForEach(icons, id: \.self) { symbol in
                Button { icon = symbol } label: {
                    Image(systemName: symbol)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .foregroundStyle(symbol == icon ? accountColor(color) : .secondary)
                        .background(symbol == icon ? accountColor(color).opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).accessibilityLabel(iconNames[icons.firstIndex(of: symbol) ?? 0])
                .accessibilityAddTraits(symbol == icon ? .isSelected : [])
            }
        }
    }

    private var colorPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Account.palette, id: \.self) { value in
                    Button { color = value } label: {
                        Circle().fill(accountColor(value)).frame(width: 26, height: 26)
                            .padding(4)
                            .overlay(Circle().strokeBorder(color == value ? accountColor(value) : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain).accessibilityLabel(colorName(value))
                    .accessibilityAddTraits(color == value ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func colorName(_ value: String) -> String {
        let names = ["orange": "Оранжевый", "red": "Красный", "yellow": "Жёлтый", "green": "Зелёный",
                     "teal": "Бирюзовый", "blue": "Синий", "indigo": "Индиго", "purple": "Фиолетовый",
                     "pink": "Розовый", "gray": "Серый"]
        return names[value] ?? "Серый"
    }

    private var parsedBalance: Int64? { Self.kopecks(from: balanceText) }
    private var parsedLimit: Int64? { Self.kopecks(from: limitText) }

    private static func kopecks(from value: String) -> Int64? {
        let text = value.filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
        guard text.range(of: "^[+-]?[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let kopecks = amount * 100
        guard kopecks >= Decimal(Int64.min), kopecks <= Decimal(Int64.max) else { return nil }
        return NSDecimalNumber(decimal: kopecks).int64Value
    }

    private func save() {
        guard !trimmedName.isEmpty, let balance = parsedBalance else { return }
        var saved = account ?? Account(name: trimmedName, icon: icon, color: color, groupID: groupID,
                                       startBalanceKopecks: balance, startDate: Date())
        saved.name = trimmedName
        saved.icon = icon
        saved.color = color
        saved.groupID = groupID
        if isCredit, let limit = parsedLimit, limit > 0 {
            let oldLimit = account?.isCreditCard == true ? account?.creditLimitKopecks : nil
            let result = CreditCards.resave(oldLimit: oldLimit, oldStartBalance: account?.startBalanceKopecks, newLimit: limit, debt: balance)
            saved.creditLimitKopecks = limit
            saved.startBalanceKopecks = result.startBalanceKopecks
            if account == nil || result.restarts { saved.startDate = Date() }
        } else {
            saved.creditLimitKopecks = nil
            if account == nil || account?.startBalanceKopecks != balance { saved.startDate = Date() }
            saved.startBalanceKopecks = balance
        }
        saved.showsBalance = showsBalance
        saved.tracksBankCard = tracksBankCard
        saved.tracksSave = tracksSave ? true : nil
        let success = browser.updateUserData { history in
            if history.accountGroups == nil { history.accountGroups = [] }
            var accounts = history.accounts ?? []
            if !((history.accountGroups ?? []).contains { $0.id == saved.groupID }) { saved.groupID = nil }
            if saved.tracksBankCard {
                for index in accounts.indices { accounts[index].tracksBankCard = false }
            }
            if saved.tracksSave == true {
                for index in accounts.indices { accounts[index].tracksSave = nil }
            }
            if let index = accounts.firstIndex(where: { $0.id == saved.id }) { accounts[index] = saved }
            else { accounts.append(saved) }
            history.accounts = accounts
        }
        if success { dismiss() } else { saveError = true }
    }

    private func delete() {
        guard let account else { return }
        if browser.updateUserData({ history in history.accounts?.removeAll { $0.id == account.id } }) {
            dismiss()
        } else { saveError = true }
    }
}

struct AccountGroupFormView: View {
    @ObservedObject var browser: BankBrowser
    @Environment(\.dismiss) private var dismiss
    private let group: AccountGroup?
    @State private var name: String
    @State private var includesInBalance: Bool
    @State private var saveError = false

    init(browser: BankBrowser, group: AccountGroup? = nil) {
        self.browser = browser
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _includesInBalance = State(initialValue: group?.includesInBalance ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название группы", text: $name)
                Section {
                    Toggle("Учитывать в текущем остатке", isOn: $includesInBalance)
                } footer: {
                    Text("Настройка влияет на текущий остаток и запас на главном экране. Суммы на странице счетов остаются видимыми.")
                }.glassRows()
            }
                .appSurface()
                .navigationTitle(group == nil ? "Новая группа" : "Группа")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Отмена", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Сохранить", systemImage: "checkmark", action: save)
                            .tint(.accentColor).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .alert("Не удалось сохранить", isPresented: $saveError) {
            Button("OK", role: .cancel) { }
        } message: { Text(browser.message) }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var saved = group ?? AccountGroup(name: name)
        saved.name = name
        saved.includesInBalance = includesInBalance
        let success = browser.updateUserData { history in
            var groups = history.accountGroups ?? []
            if let index = groups.firstIndex(where: { $0.id == saved.id }) { groups[index] = saved }
            else { groups.append(saved) }
            history.accountGroups = groups
            if history.accounts == nil { history.accounts = [] }
        }
        if success { dismiss() } else { saveError = true }
    }
}
