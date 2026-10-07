import SwiftUI

/// Which accounts the reserve until the end of the month counts. Money put aside (a savings goal, a deposit) is switched
/// off here: it stays in the current balance but does not take part in the reserve.
struct ReserveAccountsView: View {
    @ObservedObject var browser: BankBrowser
    @State private var error: String?

    private var groups: [AccountGroup] { browser.history.accountGroups ?? [] }
    /// Accounts of the balance only: an account that is not in the balance cannot be in the reserve either.
    private var candidates: [Account] {
        (browser.history.accounts ?? []).filter { $0.contributesToBalance(groups: groups) }
    }

    var body: some View {
        List {
            Section {
                Text("Запас до конца месяца считается от остатка выбранных счетов. Деньги, которые вы откладываете, отключите: они останутся в текущем остатке, но не попадут в запас.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.glassRows()
            if candidates.isEmpty {
                Section {
                    ContentUnavailableView("Нет счетов", systemImage: "wallet.pass",
                                           description: Text("Добавьте счета в панели «Счета»."))
                }.glassRows()
            }
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.accounts) { account in
                        Toggle(isOn: binding(for: account)) {
                            Label(account.name, systemImage: account.icon).foregroundStyle(accountColor(account.color))
                        }
                    }
                } header: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        // One switch for the whole group: «Копилки» out of the reserve in a tap.
                        Button(section.allCounted ? "Выключить все" : "Включить все") {
                            change(section.accounts.map(\.id), counts: !section.allCounted)
                        }
                        .font(.caption).textCase(nil)
                    }
                }.glassRows()
            }
        }
        .appSurface()
        .navigationTitle("Запас до конца месяца")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Не удалось сохранить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private struct AccountSection { let title: String; let accounts: [Account]
        var allCounted: Bool { accounts.allSatisfy { $0.countsInReserve ?? true } } }

    private var sections: [AccountSection] {
        var result: [AccountSection] = groups.compactMap { group in
            let members = candidates.filter { $0.groupID == group.id }
            return members.isEmpty ? nil : AccountSection(title: group.name, accounts: members)
        }
        let known = Set(groups.map(\.id))
        let loose = candidates.filter { account in account.groupID.map { !known.contains($0) } ?? true }
        if !loose.isEmpty { result.append(AccountSection(title: "Без группы", accounts: loose)) }
        return result
    }

    private func binding(for account: Account) -> Binding<Bool> {
        Binding(get: { account.countsInReserve ?? true }, set: { change([account.id], counts: $0) })
    }

    private func change(_ ids: [UUID], counts: Bool) {
        if !browser.updateUserData({ $0.setReserveCounting(counts, accountIDs: Set(ids)) }) { error = browser.message }
    }
}
