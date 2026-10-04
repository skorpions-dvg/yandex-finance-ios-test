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
    }
}

@MainActor
struct FinanceDashboardView: View {
    @ObservedObject var browser: BankBrowser

    private var interval: DateInterval {
        Calendar.current.dateInterval(of: .month, for: Date()) ?? DateInterval(start: .distantPast, end: .distantFuture)
    }

    private var report: FinanceReport {
        FinancialEngine.report(browser.history.operations.map(\.financialInput), in: interval)
    }

    private func rubles(_ kopecks: Int64) -> String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }

    private func signed(_ kopecks: Int64) -> String {
        let prefix = kopecks > 0 ? "+" : ""
        return prefix + rubles(kopecks)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Текущий месяц") {
                    LabeledContent("Операций в периоде", value: String(report.operationCount))
                    if report.invalidDateCount > 0 {
                        LabeledContent("Не распознано дат", value: String(report.invalidDateCount))
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Доходы", value: signed(report.incomeKopecks))
                    LabeledContent("Расходы", value: rubles(report.netExpenseKopecks))
                    LabeledContent("Разница", value: signed(report.differenceKopecks))
                    if report.pendingDebitKopecks > 0 {
                        LabeledContent("В обработке", value: rubles(report.pendingDebitKopecks))
                    }
                    Text("Период: \(interval.start.formatted(date: .abbreviated, time: .omitted)) — \(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                moneySection("Доходы", total: report.incomeKopecks, lines: report.incomeLines, empty: "Доходов за месяц нет.")
                expenseSection
                if !report.movementLines.isEmpty {
                    moneySection("Перемещения", total: report.movementKopecks, lines: report.movementLines, empty: "")
                }
                if !report.incompleteLines.isEmpty {
                    Section("Не завершено") {
                        ForEach(report.incompleteLines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(line.title)
                                    Spacer()
                                    Text(signed(line.amountKopecks))
                                }
                                Text("Операций: \(line.count)").font(.caption).foregroundStyle(.secondary)
                                if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }

                Section("Сверка с банком") {
                    LabeledContent("Завершённые списания", value: rubles(report.grossExpenseKopecks))
                    LabeledContent("Возвраты", value: rubles(report.refundsKopecks))
                    LabeledContent("Списания с учётом обработки", value: rubles(report.bankDebitKopecks))
                    Text("Верхняя цифра списаний в банке обычно включает операции в обработке. Окончательный расход в приложении их не включает.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Правила") {
                    Text("Возврат уменьшает расходы и не считается доходом. Перевод между своими счетами и снятие наличных — перемещение, а не трата и не заработок.")
                    Text("Сплит виден отдельно и не входит в итог, пока покупка и платежи не связаны.")
                    Text("Старое завершённое списание без современного типа считается расходом. Непонятное поступление доходом не назначается.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Финансы")
        }
    }

    private var expenseSection: some View {
        Section("Расходы") {
            LabeledContent("До возвратов", value: rubles(report.grossExpenseKopecks))
            LabeledContent("Расходы после возвратов", value: rubles(report.netExpenseKopecks))
            ForEach(report.expenseLines) { line in
                DisclosureGroup {
                    if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    ForEach(line.children) { child in
                        HStack {
                            Text(child.title)
                            Spacer()
                            Text(rubles(child.amountKopecks))
                        }.font(.subheadline)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(line.title)
                            Text("Операций: \(line.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text((line.title == "Возвраты" ? "−" : "") + rubles(line.amountKopecks))
                    }
                }
            }
            if report.expenseLines.isEmpty { Text("Расходов за месяц нет.").foregroundStyle(.secondary) }
        }
    }

    private func moneySection(_ title: String, total: Int64, lines: [FinanceLine], empty: String) -> some View {
        Section(title) {
            LabeledContent("Итого", value: rubles(total))
            ForEach(lines) { line in
                DisclosureGroup {
                    if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    ForEach(line.children) { child in
                        HStack { Text(child.title); Spacer(); Text(rubles(child.amountKopecks)) }.font(.subheadline)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(line.title)
                            Text("Операций: \(line.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(rubles(line.amountKopecks))
                    }
                }
            }
            if lines.isEmpty, !empty.isEmpty { Text(empty).foregroundStyle(.secondary) }
        }
    }
}
