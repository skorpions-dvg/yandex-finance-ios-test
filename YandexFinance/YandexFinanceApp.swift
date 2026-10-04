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
                    HStack {
                        Button("Прочитать карточку") { browser.read(mode: "card", lookbackDays: nil) }
                        Button("Обновить 30 дней") { browser.read(mode: "history", lookbackDays: 30) }.buttonStyle(.borderedProminent)
                    }.font(.footnote).padding(.bottom, 8)
                }
            }.tabItem { Label("Банк", systemImage: "building.columns") }
            NavigationStack {
                List {
                    Section {
                        Text("Сохранено операций: \(browser.history.operations.count)")
                        if let date = browser.history.lastSync {
                            Text("Обновлено: \(date.formatted(date: .abbreviated, time: .shortened))")
                        }
                        Toggle("Обновлять при открытии", isOn: $browser.autoUpdate).disabled(browser.busy)
                        Text("При первой синхронизации приложение читает всю доступную историю. Затем при открытии автоматически перепроверяет последние 7 дней. Кнопка «Обновить 30 дней» запускает ручную перепроверку 30 дней. При закрытом приложении обновление не выполняется.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(browser.message).font(.footnote)
                        if browser.busy { ProgressView("Обновление операций…") }
                        Text("Возвраты, переводы и Сплит пока не объединены в итог расходов.")
                            .font(.footnote).foregroundStyle(.secondary)
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
