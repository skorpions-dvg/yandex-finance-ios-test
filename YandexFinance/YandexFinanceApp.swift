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
        TabView {
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
            }.tabItem { Label("Банк", systemImage: "building.columns") }
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
                        Text("Возвраты, переводы и Сплит пока не объединены в итог расходов.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let issues = browser.history.unresolvedIssues, !issues.isEmpty {
                        Section("Не удалось прочитать") {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(issue.rowSummary ?? "Операция из предыдущей версии").font(.headline)
                                    if let month = issue.monthOrdinal {
                                        Text("Период: \(month % 12 + 1).\(month / 12)").font(.caption)
                                    }
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
                                LabeledContent("Сумма", value: operation.formattedAmount)
                                LabeledContent("Категория", value: operation.category)
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
                                Text(operation.category + " · " + operation.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.navigationTitle("Мои операции")
            }.tabItem { Label("Операции", systemImage: "list.bullet.rectangle") }
        }
    }
}
