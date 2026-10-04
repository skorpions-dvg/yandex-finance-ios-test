import SwiftUI

@main
@MainActor
struct YandexFinanceApp: App {
    @StateObject private var browser = BankBrowser()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(browser: browser)
                .onAppear { if scenePhase == .active { browser.becameActive() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { browser.becameActive() }
                    else { browser.becameInactive() }
                }
        }
    }
}

@MainActor
struct ContentView: View {
    @ObservedObject var browser: BankBrowser
    @State private var confirmStorageReset = false
    var body: some View {
        TabView(selection: $browser.selectedTab) {
            VStack(spacing: 8) {
                HStack {
                    Text(browser.host).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("История") { browser.openHistory() }.disabled(browser.busy)
                }.padding(.horizontal)
                BankWebView(browser: browser)
                Text(browser.message).font(.footnote).padding(.horizontal).accessibilityIdentifier("syncStatus")
                if browser.busy {
                    HStack { ProgressView(); Button("Остановить") { browser.cancel() } }.padding(.bottom, 8)
                } else {
                    VStack(spacing: 8) {
                        HStack {
                            Button("Прочитать карточку") { browser.read(mode: "card", lookbackDays: nil) }
                            Button("Обновить 30 дней") { browser.read(mode: "history", lookbackDays: 30) }.buttonStyle(.borderedProminent)
                        }
                        if browser.canResume {
                            Button("Продолжить загрузку истории") { browser.continueInitialHistory() }
                        }
                        Button("Синхронизировать 6 месяцев") { browser.syncSixMonthsHistory() }
                            .font(.footnote)
                    }.font(.footnote).padding(.bottom, 8)
                }
            }.tabItem { Label("Банк", systemImage: "building.columns") }.tag(0)
            NavigationStack {
                List {
                    if let storageError = browser.storageError {
                        Section("Хранилище недоступно") {
                            Text(storageError).font(.footnote)
                            Text("Сброс удалит только локально сохранённую историю и ключ шифрования. После этого историю нужно будет синхронизировать заново.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Сбросить локальное хранилище", role: .destructive) { confirmStorageReset = true }
                                .disabled(browser.busy)
                        }
                    }
                    Section {
                        Text("Сохранено операций: \(browser.history.operations.count)")
                        if let date = browser.history.lastSync {
                            Text("Последнее сохранение: \(date.formatted(date: .abbreviated, time: .shortened))")
                        }
                        Text(browser.bootstrapComplete ? "Первичная загрузка завершена" : "Полнота первичной загрузки ещё не подтверждена")
                        Text("Не разобрано: \(browser.history.unresolvedIssues?.count ?? 0)")
                        if let date = browser.history.lastCompletedSync {
                            Text("Проверено: \(date.formatted(date: .abbreviated, time: .shortened))")
                        }
                        Toggle("Обновлять при открытии", isOn: $browser.autoUpdate).disabled(browser.busy)
                        Text("Автообновление проверяет период с последней успешной проверки с запасом 7 дней. После перерыва период расширяется. В этой версии первая проверка сохранённой истории охватывает 6 месяцев. Незавершённую первичную загрузку можно продолжить отдельной кнопкой. При закрытом приложении обновление не гарантируется.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(browser.message).font(.footnote)
                        if browser.busy { ProgressView("Обновление операций…") }
                        Text("Итоги, возвраты и категории считаются на вкладке «Финансы». Здесь полный список операций.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let issues = browser.history.unresolvedIssues, !issues.isEmpty {
                        Section("Не удалось прочитать") {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(issue.rowSummary ?? "Операция из предыдущей версии").font(.headline)
                                    if let month = issue.monthOrdinal {
                                        Text("Месяц сканера (не дата платежа): \(String(month % 12 + 1)).\(String(month / 12))").font(.caption)
                                    }
                                    if let date = issue.bankDate {
                                        Text("Дата из данных банка: " + date).font(.caption)
                                    } else { Text("Дата платежа пока не определена").font(.caption) }
                                    if let identity = issue.identity {
                                        Text("Идентификатор: " + identity).font(.caption2).textSelection(.enabled)
                                    }
                                    Text(issue.reason).font(.footnote)
                                    Button(issue.operationURL == nil ? "Найти и перечитать" : "Перечитать эту операцию") { browser.retry(issue) }
                                        .disabled(browser.busy)
                                    if issue.operationURL == nil {
                                        Text("У старой записи нет ссылки: поиск пройдёт только по сохранённому месяцу. Откройте вкладку «Банк» → «История» перед поиском.").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                    ForEach(browser.history.operations) { operation in
                        NavigationLink {
                            Form {
                                LabeledContent(operation.components == nil ? "Сумма" : "Итог группы", value: operation.formattedAmount)
                                if let components = operation.components {
                                    Section("Составляющие") {
                                        ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                                            VStack(alignment: .leading) {
                                                HStack {
                                                    Text(component.amountKopecks < 0 ? "Списание" : "Поступление")
                                                    Spacer()
                                                    Text(component.formattedAmount)
                                                }
                                                Text(component.displayDate).font(.caption)
                                            }
                                        }
                                        Text("Итог группы — сумма этих составляющих, не дополнительная операция. Вид поступления пока не определён.").font(.footnote)
                                    }
                                }
                                LabeledContent("Категория", value: operation.category)
                                LabeledContent("Финансовый тип", value: operation.financialAssessment.type.title)
                                Text(operation.financialAssessment.reason).font(.footnote).foregroundStyle(.secondary)
                                LabeledContent("Статус", value: operation.status)
                                LabeledContent("Дата UTC", value: operation.occurredAt)
                                LabeledContent("Точность", value: operation.timePrecision == "source_timestamp" ? "Время банка" : "До минуты")
                                if let mcc = operation.mcc { LabeledContent("MCC", value: mcc) }
                                if let purpose = operation.purpose { LabeledContent("Назначение", value: purpose) }
                                if let method = operation.paymentMethod { LabeledContent("Способ оплаты", value: method) }
                            }.navigationTitle(operation.description)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(operation.description); Spacer(); Text(operation.formattedAmount) }
                                if let components = operation.components {
                                    Text("Сводная карточка: \(components.count) составляющих").font(.caption)
                                }
                                Text(operation.category + " · " + operation.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.navigationTitle("Мои операции")
            }.tabItem { Label("Операции", systemImage: "list.bullet.rectangle") }.tag(1)
            FinanceDashboardView(browser: browser)
                .tabItem { Label("Финансы", systemImage: "chart.pie") }.tag(2)
        }
        .confirmationDialog("Сбросить локальное хранилище?", isPresented: $confirmStorageReset, titleVisibility: .visible) {
            Button("Сбросить и удалить локальную историю", role: .destructive) { browser.resetLocalStorage() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Используйте это только если зашифрованная база больше не открывается. Действие необратимо для локальной копии.")
        }
    }
}

@MainActor
struct FinanceDashboardView: View {
    @ObservedObject var browser: BankBrowser

    private var currentInterval: DateInterval {
        Calendar.current.dateInterval(of: .month, for: Date()) ?? DateInterval(start: .distantPast, end: .distantFuture)
    }

    private func rubles(_ kopecks: Int64) -> String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }

    private func signed(_ kopecks: Int64) -> String {
        let prefix = kopecks > 0 ? "+" : ""
        return prefix + rubles(kopecks)
    }

    var body: some View {
        let interval = currentInterval
        let report = FinancialEngine.report(browser.history.operations.map(\.financialInput), in: interval)
        NavigationStack {
            List {
                Section("Текущий месяц") {
                    LabeledContent("Доходы", value: rubles(report.incomeKopecks))
                    LabeledContent("Расходы", value: rubles(report.netExpenseKopecks))
                    LabeledContent("Разница", value: signed(report.differenceKopecks))
                    if report.pendingDebitKopecks > 0 {
                        LabeledContent("В обработке", value: rubles(report.pendingDebitKopecks))
                    }
                    LabeledContent("Операций", value: String(report.operationCount))
                    if report.invalidDateCount > 0 {
                        LabeledContent("Не распознано дат", value: String(report.invalidDateCount))
                            .foregroundStyle(.orange)
                    }
                    Text("Период: \(interval.start.formatted(date: .abbreviated, time: .omitted)) — \(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                incomeBlock(report)
                expenseBlock(report)

                if !report.movementLines.isEmpty {
                    movementBlock(report)
                }
                if !report.incompleteLines.isEmpty {
                    incompleteBlock(report)
                }

                Section("Сверка с банком") {
                    LabeledContent("Банковские списания", value: rubles(report.bankDebitKopecks))
                    LabeledContent("Банковские поступления", value: rubles(report.bankCreditKopecks))
                    Text("Это банковский оборот за период: все завершённые и находящиеся в обработке движения по знаку суммы, кроме отменённых. Он нужен для сверки с цифрами банка и не равен финансовым доходам/расходам: сюда могут входить свои переводы, снятие наличных, Сплит и возвраты.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Правила") {
                    Text("Возвраты уменьшают расходы и не считаются доходом. Подтверждённые переводы между своими счетами и снятие наличных относятся к перемещениям.")
                    Text("Сплит показывается отдельно и пока не входит в итог расходов, пока исходная покупка и платежи не связаны — так мы не создаём двойной расход.")
                    Text("Старое завершённое списание без современного типа считается расходом. Непонятное положительное поступление автоматически доходом не назначается.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Финансы")
        }
    }

    private func incomeBlock(_ report: FinanceReport) -> some View {
        Section {
            DisclosureGroup {
                if report.incomeLines.isEmpty {
                    Text("Доходов за месяц нет.").foregroundStyle(.secondary)
                } else {
                    ForEach(report.incomeLines) { line in
                        simpleFinanceRow(line, amount: rubles(line.amountKopecks))
                    }
                }
            } label: {
                blockLabel("Доходы", value: rubles(report.incomeKopecks))
            }
        }
    }

    private func expenseBlock(_ report: FinanceReport) -> some View {
        Section {
            DisclosureGroup {
                if report.expenseLines.isEmpty {
                    Text("Расходов за месяц нет.").foregroundStyle(.secondary)
                } else {
                    ForEach(report.expenseLines) { line in
                        expenseLine(line)
                    }
                    Text("Итог расходов уже уменьшен на возвраты.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                blockLabel("Расходы", value: rubles(report.netExpenseKopecks))
            }
        }
    }

    private func movementBlock(_ report: FinanceReport) -> some View {
        Section {
            DisclosureGroup {
                ForEach(report.movementLines) { line in
                    simpleFinanceRow(line, amount: rubles(line.amountKopecks))
                }
                Text("Перемещения не входят ни в доходы, ни в расходы. Показанная сумма — оборот перемещений.")
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                blockLabel("Перемещения", value: rubles(report.movementKopecks))
            }
        }
    }

    private func incompleteBlock(_ report: FinanceReport) -> some View {
        Section {
            DisclosureGroup {
                ForEach(report.incompleteLines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(line.title)
                            Spacer()
                            Text(signed(line.amountKopecks))
                        }
                        Text("Операций: \(line.count)").font(.caption).foregroundStyle(.secondary)
                        if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            } label: {
                blockLabel("Не завершено", value: "\(incompleteCount(report)) оп.")
            }
        }
    }

    private func incompleteCount(_ report: FinanceReport) -> Int {
        report.incompleteLines.reduce(0) { $0 + $1.count }
    }

    private func expenseAmount(_ line: FinanceLine) -> String {
        line.title == "Возвраты" ? "−" + rubles(line.amountKopecks) : rubles(line.amountKopecks)
    }

    @ViewBuilder
    private func expenseLine(_ line: FinanceLine) -> some View {
        if line.children.isEmpty {
            simpleFinanceRow(line, amount: expenseAmount(line))
        } else {
            DisclosureGroup {
                if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                ForEach(line.children) { child in
                    HStack {
                        Text(child.title)
                        Spacer()
                        Text(rubles(child.amountKopecks))
                    }
                    .font(.subheadline)
                }
            } label: {
                financeRowLabel(line, amount: expenseAmount(line))
            }
        }
    }

    private func simpleFinanceRow(_ line: FinanceLine, amount: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            financeRowLabel(line, amount: amount)
            if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func financeRowLabel(_ line: FinanceLine, amount: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                Text("Операций: \(line.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(amount)
        }
    }

    private func blockLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text(value).font(.headline)
        }
    }
}
