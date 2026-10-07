import SwiftUI
import Charts

@MainActor
struct AccountDetailView: View {
    @ObservedObject var browser: BankBrowser
    let account: Account
    @Binding var showsInfo: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var presentation = FinancePresentationCache()
    @State private var range: ReportSeries.AccountRange = .days30
    @State private var showsEditor = false
    @State private var editedManualOperation: ManualOperation?

    private var activeAccount: Account {
        browser.history.accounts?.first { $0.id == account.id } ?? account
    }

    var body: some View {
        let account = activeAccount
        let _ = presentation.prepare(browser.history)
        let interval = ReportSeries.accountInterval(range: range)
        let key = "\(account.id):\(interval.start):\(interval.end)"
        let movements = presentation.value("account-movements:\(account.id)") {
            browser.history.accountMovements(account)
        }
        let current = presentation.value("account-current:\(account.id)") {
            browser.history.accountBalances(account, at: [.distantFuture])[0]
        }
        let period = presentation.value("account-period:\(key)") {
            ReportSeries.accountPeriod(movements, interval: interval)
        }
        let points = presentation.value("account-balance:\(range.rawValue):\(key)") {
            ReportSeries.balancePoints(browser.history, account: account, interval: interval, range: range)
        }
        let days = presentation.value("account-days:\(key)") {
            ReportSeries.accountDays(period.movements)
        }
        let inputs = presentation.value("account-inputs") {
            Dictionary(zip(browser.history.allOperations.map(\.identity), presentation.inputs(browser.history)),
                       uniquingKeysWith: { first, _ in first })
        }
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Label(account.name, systemImage: account.icon)
                            .font(.headline).foregroundStyle(accountColor(account.color))
                        Text(money(current)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text("Текущий остаток").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }.glassRows()

                Section("Остаток на счёте") {
                    Picker("Период", selection: $range) {
                        ForEach(ReportSeries.AccountRange.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }.pickerStyle(.segmented)
                    AccountBalanceChart(points: points, color: accountColor(account.color), range: range)
                    LabeledContent("Поступило за период", value: money(period.incomingKopecks))
                    LabeledContent("Списано за период", value: money(period.outgoingKopecks))
                }.glassRows()

                if days.isEmpty {
                    Section {
                        ContentUnavailableView(movements.isEmpty ? "Операций пока нет" : "За этот период операций нет",
                                               systemImage: "tray")
                    }.glassRows()
                } else {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.movements) { movement in
                                if movement.operation.isManual {
                                    Button {
                                        editedManualOperation = browser.history.manualOperations?.first {
                                            $0.id == movement.operation.manualID
                                        }
                                    } label: {
                                        movementRow(movement, input: inputs[movement.id])
                                    }.buttonStyle(.plain)
                                } else {
                                    NavigationLink {
                                        OperationDetailView(browser: browser, operation: movement.operation)
                                    } label: {
                                        movementRow(movement, input: inputs[movement.id])
                                    }
                                }
                            }
                        } header: {
                            Text(day.date.formatted(date: .complete, time: .omitted))
                        }.glassRows()
                    }
                }
            }
            .appSurface()
            .navigationTitle("Счёт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Изменить") { showsEditor = true }
                }
            }
            .sheet(isPresented: $showsEditor) {
                AccountFormView(browser: browser, account: activeAccount, showsInfo: $showsInfo)
            }
            .sheet(item: $editedManualOperation) {
                ManualOperationFormView(browser: browser, operation: $0)
            }
        }
        .onChange(of: browser.history.accounts?.contains { $0.id == self.account.id } ?? false) { _, exists in
            if !exists { dismiss() }
        }
    }

    private func movementRow(_ movement: AccountMovement, input: FinancialOperationInput?) -> some View {
        OperationRow(operation: movement.operation, input: input,
                     look: browser.history.look(for: movement.operation), displayedAmountKopecks: movement.delta,
                     hasReceipt: browser.history.hasReceipt(movement.operation))
    }

    private func money(_ amount: Int64) -> String {
        (Decimal(amount) / 100).formatted(.currency(code: "RUB"))
    }
}

private struct AccountBalanceChart: View {
    let points: [ReportSeries.BalancePoint]
    let color: Color
    let range: ReportSeries.AccountRange

    private var bounds: ClosedRange<Double> {
        let values = points.map { Double($0.amountKopecks) / 100 }
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let padding = max(1, (high - low) * 0.1)
        return (low - padding)...(high + padding)
    }

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Дата", point.date), y: .value("Остаток", Double(point.amountKopecks) / 100))
                .foregroundStyle(color)
                .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue((Decimal(point.amountKopecks) / 100).formatted(.currency(code: "RUB")))
        }
        .chartYScale(domain: bounds)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .year ? 6 : 4)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(range == .year ? .dateTime.month(.abbreviated) : .dateTime.day().month(.abbreviated)))
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(height: 200)
    }
}
