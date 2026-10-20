import SwiftUI
import UserNotifications

/// How often a payment of a subscription or a loan comes, said the way it is entered.
func commitmentSchedule(day: Int, month: Int?) -> String {
    let genitive = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]
    if let month, (1...12).contains(month) { return "раз в год, \(day) \(genitive[month - 1])" }
    return "каждый месяц, \(day)-го"
}

private func commitmentRubles(_ kopecks: Int64) -> String {
    (Decimal(kopecks) / 100).formatted(.currency(code: "RUB").precision(.fractionLength(0...2)))
}

private func commitmentMonthName(_ month: Int) -> String {
    let names = Calendar.current.standaloneMonthSymbols
    guard (1...names.count).contains(month) else { return "\(month)" }
    return names[month - 1].capitalized
}

/// «1 299,50» as the form shows an amount that was entered.
private func commitmentAmountText(_ kopecks: Int64) -> String {
    (Decimal(kopecks) / 100).description.replacingOccurrences(of: ".", with: ",")
}

/// Reminders a day before a payment: local notifications at ten in the morning for the next forty days. The text carries no
/// name and no amount, so the lock screen shows nothing about the money (the app shows the rest).
enum CommitmentReminders {
    static let idPrefix = "commit-"

    /// Asks for the permission to notify; false when it was refused (then the switch of the form goes back).
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Replaces the reminders by the ones that are due now: only for the entries with the reminder on.
    static func reschedule(subscriptions: [Subscription], loans: [Loan], answers: [String: FinancialEngine.PaymentAnswer] = [:],
                           now: Date = Date(), calendar: Calendar = .current) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let subscriptions = subscriptions.filter(\.remind)
        let loans = loans.filter(\.remind)
        guard !subscriptions.isEmpty || !loans.isEmpty else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let until = calendar.date(byAdding: .day, value: 40, to: now) ?? now
        // A payment the owner moved comes on its new day; one he answered «came» or «not this month» gets no reminder. The days are
        // looked at from two months back: a moved payment may have been due earlier.
        let from = calendar.date(byAdding: .day, value: -60, to: now) ?? now
        var coming: [(due: FinancialEngine.CommitmentDue, day: Date)] = []
        for due in FinancialEngine.commitmentDues(subscriptions: subscriptions, loans: loans, from: from, to: until, calendar: calendar) {
            let answer = answers[FinancialEngine.commitmentKey(id: due.id, due: due.date, calendar: calendar)]
            if answer?.kind == .arrived || answer?.kind == .skipped { continue }
            let day = answer?.kind == .moved ? (answer?.movedTo ?? due.date) : due.date
            if day >= now { coming.append((due, day)) }
        }
        coming.sort { $0.day < $1.day }
        for (due, day) in coming.prefix(50) {
            guard let eve = calendar.date(byAdding: .day, value: -1, to: day),
                  let moment = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: eve), moment > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Завтра списание"
            content.body = "Откройте Horizon: там подписка или платёж по кредиту."
            content.sound = .default
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
            let identifier = idPrefix + FinancialEngine.commitmentKey(id: due.id, due: due.date, calendar: calendar)
            let request = UNNotificationRequest(identifier: identifier, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
    }
}

// MARK: - Subscriptions

struct SubscriptionFormTarget: Identifiable {
    let id = UUID()
    let subscription: Subscription?
}

/// «Подписки»: what is paid every month or every year; the forecast counts the payments.
@MainActor
struct SubscriptionsView: View {
    @ObservedObject var browser: BankBrowser
    @State private var editing: SubscriptionFormTarget?

    var body: some View {
        let subscriptions = browser.history.subscriptions ?? []
        List {
            Section {
                Text("Добавьте подписки, которые подключены сейчас. В прогнозе их платежи считаются ожидаемым расходом; если нужное списание уже прошло по операции (та же сумма в пределах трёх дней), второй раз оно не учитывается.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.glassRows()
            if subscriptions.isEmpty {
                Section {
                    ContentUnavailableView("Подписок пока нет", systemImage: "repeat",
                                           description: Text("Название, сумма и день списания."))
                    Button { editing = SubscriptionFormTarget(subscription: nil) } label: {
                        Label { Text("Добавить подписку").foregroundStyle(.primary) } icon: { Image(systemName: "plus.circle").foregroundStyle(.primary) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }.glassRows()
            } else {
                Section {
                    ForEach(subscriptions) { subscription in
                        Button { editing = SubscriptionFormTarget(subscription: subscription) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(subscription.name).font(.headline).lineLimit(2)
                                    Text(commitmentSchedule(day: subscription.day, month: subscription.month))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if subscription.remind { Image(systemName: "bell").font(.caption).foregroundStyle(.secondary) }
                                Text(commitmentRubles(subscription.amountKopecks)).font(.subheadline).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in remove(at: offsets, from: subscriptions) }
                } footer: {
                    let monthly = subscriptions.reduce(Int64(0)) { $0 + ($1.month == nil ? $1.amountKopecks : $1.amountKopecks / 12) }
                    Text("≈ " + commitmentRubles(monthly) + " в месяц")
                }.glassRows()
            }
        }
        .appSurface()
        .navigationTitle("Подписки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = SubscriptionFormTarget(subscription: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить подписку")
            }
        }
        .sheet(item: $editing) { target in
            SubscriptionFormView(browser: browser, existing: target.subscription)
        }
    }

    private func remove(at offsets: IndexSet, from subscriptions: [Subscription]) {
        let ids = Set(offsets.map { subscriptions[$0].id })
        _ = browser.updateUserData { history in
            let left = (history.subscriptions ?? []).filter { !ids.contains($0.id) }
            history.subscriptions = left.isEmpty ? nil : left
        }
    }
}

@MainActor
struct SubscriptionFormView: View {
    @ObservedObject var browser: BankBrowser
    let existing: Subscription?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amountText = ""
    @State private var day = 1
    @State private var yearly = false
    @State private var month = 1
    @State private var accountID: UUID?
    @State private var remind = false
    @State private var error: String?
    @State private var loaded = false

    private var parsedAmount: Int64? {
        guard let kopecks = ReceiptParser.kopecks(fromDecimal: amountText.filter { !$0.isWhitespace }), kopecks > 0 else { return nil }
        return kopecks
    }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && parsedAmount != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Название", text: $name)
                    TextField("Сумма, ₽", text: $amountText).keyboardType(.decimalPad)
                    Picker("Как часто", selection: $yearly) {
                        Text("Раз в месяц").tag(false)
                        Text("Раз в год").tag(true)
                    }
                    if yearly {
                        Picker("Месяц", selection: $month) { ForEach(1...12, id: \.self) { Text(commitmentMonthName($0)).tag($0) } }
                    }
                    Picker("День", selection: $day) { ForEach(1...31, id: \.self) { Text("\($0)").tag($0) } }
                    Picker("Счёт", selection: $accountID) {
                        Text("Не указан").tag(UUID?.none)
                        ForEach(browser.history.accounts ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Toggle("Напомнить за сутки", isOn: $remind)
                } footer: {
                    Text("31-е число в коротком месяце — последний день месяца. Напоминание приходит в 10 утра накануне, без названия и суммы.")
                }.glassRows()
                if existing != nil {
                    Section {
                        Button("Удалить подписку", role: .destructive) { remove() }
                    }.glassRows()
                }
            }
            .appSurface()
            .navigationTitle(existing == nil ? "Новая подписка" : "Подписка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Сохранить") { save() }.disabled(!canSave) }
            }
            .alert("Не удалось сохранить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onChange(of: remind) { _, on in
                guard on else { return }
                Task {
                    if !(await CommitmentReminders.requestAuthorization()) {
                        remind = false
                        error = "Разрешите уведомления для Horizon в настройках iPhone, чтобы получать напоминания."
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                guard let existing else { return }
                name = existing.name
                amountText = commitmentAmountText(existing.amountKopecks)
                day = existing.day
                yearly = existing.month != nil
                month = existing.month ?? 1
                accountID = existing.accountID
                remind = existing.remind
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        guard let kopecks = parsedAmount else { return }
        let subscription = Subscription(id: existing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), amountKopecks: kopecks,
                                        day: day, month: yearly ? month : nil, accountID: accountID, remind: remind,
                                        since: existing?.since ?? Calendar.current.startOfDay(for: Date()))
        let ok = browser.updateUserDataAfterClosing { history in
            var all = history.subscriptions ?? []
            if let index = all.firstIndex(where: { $0.id == subscription.id }) { all[index] = subscription } else { all.append(subscription) }
            history.subscriptions = all
        }
        if ok { dismiss() } else { error = browser.message }
    }

    private func remove() {
        guard let id = existing?.id else { return }
        let ok = browser.updateUserDataAfterClosing { history in
            let left = (history.subscriptions ?? []).filter { $0.id != id }
            history.subscriptions = left.isEmpty ? nil : left
        }
        if ok { dismiss() } else { error = browser.message }
    }
}

// MARK: - Loans

struct LoanFormTarget: Identifiable {
    let id = UUID()
    let loan: Loan?
}

/// «Кредиты»: the monthly payment and the balance the owner keeps by hand; the forecast counts the payments.
@MainActor
struct LoansView: View {
    @ObservedObject var browser: BankBrowser
    @State private var editing: LoanFormTarget?

    var body: some View {
        let loans = browser.history.loans ?? []
        let now = Date()
        List {
            Section {
                Text("Ежемесячный платёж считается в прогнозе ожидаемым расходом. Остаток по кредиту вводится и правится вручную: проценты приложение не считает.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.glassRows()
            if loans.isEmpty {
                Section {
                    ContentUnavailableView("Кредитов пока нет", systemImage: "banknote",
                                           description: Text("Название, платёж и день списания."))
                    Button { editing = LoanFormTarget(loan: nil) } label: {
                        Label { Text("Добавить кредит").foregroundStyle(.primary) } icon: { Image(systemName: "plus.circle").foregroundStyle(.primary) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }.glassRows()
            } else {
                Section {
                    ForEach(loans) { loan in
                        Button { editing = LoanFormTarget(loan: loan) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(loan.name).font(.headline).lineLimit(2)
                                    Text(commitmentSchedule(day: loan.day, month: nil)).font(.caption).foregroundStyle(.secondary)
                                    if let balance = loan.balance(now: now) {
                                        Text(loan.reducesBalance && balance == 0 ? "погашен" : "остаток " + commitmentRubles(balance))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if loan.remind { Image(systemName: "bell").font(.caption).foregroundStyle(.secondary) }
                                Text(commitmentRubles(loan.paymentKopecks)).font(.subheadline).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in remove(at: offsets, from: loans) }
                } footer: {
                    Text("≈ " + commitmentRubles(loans.reduce(Int64(0)) { $0 + $1.paymentKopecks }) + " в месяц")
                }.glassRows()
            }
        }
        .appSurface()
        .navigationTitle("Кредиты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = LoanFormTarget(loan: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить кредит")
            }
        }
        .sheet(item: $editing) { target in
            LoanFormView(browser: browser, existing: target.loan)
        }
    }

    private func remove(at offsets: IndexSet, from loans: [Loan]) {
        let ids = Set(offsets.map { loans[$0].id })
        _ = browser.updateUserData { history in
            let left = (history.loans ?? []).filter { !ids.contains($0.id) }
            history.loans = left.isEmpty ? nil : left
        }
    }
}

@MainActor
struct LoanFormView: View {
    @ObservedObject var browser: BankBrowser
    let existing: Loan?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var paymentText = ""
    @State private var day = 1
    @State private var accountID: UUID?
    @State private var remind = false
    @State private var balanceText = ""
    @State private var reduces = false
    @State private var error: String?
    @State private var loaded = false

    private var parsedPayment: Int64? {
        guard let kopecks = ReceiptParser.kopecks(fromDecimal: paymentText.filter { !$0.isWhitespace }), kopecks > 0 else { return nil }
        return kopecks
    }
    private var balanceEntered: Bool { !balanceText.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The balance as typed; nil when the field is empty or is not an amount.
    private var parsedBalance: Int64? {
        guard balanceEntered else { return nil }
        return ReceiptParser.kopecks(fromDecimal: balanceText.filter { !$0.isWhitespace })
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && parsedPayment != nil && (!balanceEntered || parsedBalance != nil)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Название", text: $name)
                    TextField("Платёж в месяц, ₽", text: $paymentText).keyboardType(.decimalPad)
                    Picker("День списания", selection: $day) { ForEach(1...31, id: \.self) { Text("\($0)").tag($0) } }
                    Picker("Счёт", selection: $accountID) {
                        Text("Не указан").tag(UUID?.none)
                        ForEach(browser.history.accounts ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Toggle("Напомнить за сутки", isOn: $remind)
                } footer: {
                    Text("31-е число в коротком месяце — последний день месяца. Напоминание приходит в 10 утра накануне, без названия и суммы.")
                }.glassRows()
                Section {
                    TextField("Остаток долга, ₽ (необязательно)", text: $balanceText).keyboardType(.decimalPad)
                    Toggle("Уменьшать остаток после платежа", isOn: $reduces)
                } footer: {
                    Text("Остаток вводится и правится вручную. С переключателем в день платежа он уменьшается на сумму платежа (без процентов, это оценка: при расхождении с банком поправьте остаток). Когда остаток дойдёт до нуля, платежи в прогноз не входят.")
                }.glassRows()
                if existing != nil {
                    Section {
                        Button("Удалить кредит", role: .destructive) { remove() }
                    }.glassRows()
                }
            }
            .appSurface()
            .navigationTitle(existing == nil ? "Новый кредит" : "Кредит")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Сохранить") { save() }.disabled(!canSave) }
            }
            .alert("Не удалось сохранить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onChange(of: remind) { _, on in
                guard on else { return }
                Task {
                    if !(await CommitmentReminders.requestAuthorization()) {
                        remind = false
                        error = "Разрешите уведомления для Horizon в настройках iPhone, чтобы получать напоминания."
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                guard let existing else { return }
                name = existing.name
                paymentText = commitmentAmountText(existing.paymentKopecks)
                day = existing.day
                accountID = existing.accountID
                remind = existing.remind
                reduces = existing.reducesBalance
                if let shown = existing.balance(now: Date()) { balanceText = commitmentAmountText(shown) }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        guard let payment = parsedPayment else { return }
        let now = Date()
        let kept = Loan.keptBalance(old: existing, entered: parsedBalance, reduces: reduces, now: now)
        let loan = Loan(id: existing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), paymentKopecks: payment, day: day,
                        accountID: accountID, remind: remind, balanceKopecks: kept.kopecks, balanceDate: kept.date,
                        reducesBalance: reduces, since: existing?.since ?? Calendar.current.startOfDay(for: now))
        let ok = browser.updateUserDataAfterClosing { history in
            var all = history.loans ?? []
            if let index = all.firstIndex(where: { $0.id == loan.id }) { all[index] = loan } else { all.append(loan) }
            history.loans = all
        }
        if ok { dismiss() } else { error = browser.message }
    }

    private func remove() {
        guard let id = existing?.id else { return }
        let ok = browser.updateUserDataAfterClosing { history in
            let left = (history.loans ?? []).filter { $0.id != id }
            history.loans = left.isEmpty ? nil : left
        }
        if ok { dismiss() } else { error = browser.message }
    }
}
