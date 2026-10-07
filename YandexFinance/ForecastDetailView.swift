import SwiftUI

struct ForecastDetailView: View {
    let forecast: FinancialEngine.MonthForecast
    /// Balance of the accounts the reserve counts; nil when there are none.
    let balanceKopecks: Int64?
    let accountNames: [String]
    let bufferKopecks: Int64
    let browser: BankBrowser
    let presentation: FinancePresentationCache
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                reserveSection
                forecastSection
            }
            .appSurface()
            .navigationTitle("Прогноз на месяц")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    /// One main number: what is expected to be left at the end of the month.
    private var reserveSection: some View {
        Section {
            Text("Останется к концу месяца").font(.headline)
            if let balance = balanceKopecks {
                let reserve = FinancialEngine.monthReserve(balanceKopecks: balance, forecast: forecast)
                let range = FinancialEngine.monthReserveRange(balanceKopecks: balance, forecast: forecast)
                Text(signedRubles(reserve))
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(reserveColor(reserve))
                Text("обычно от \(signedRubles(range.low)) до \(signedRubles(range.high))")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Остаток \(rubles(balance)) − ещё расходы \(rubles(max(0, forecast.projectedExpenseKopecks - forecast.spentKopecks))) + ещё регулярные поступления \(rubles(forecast.expectedIncomeLeftKopecks))")
                    Text("Счета: " + (accountNames.isEmpty ? "не выбраны" : accountNames.joined(separator: ", ")) + ". Отложенные деньги исключаются в настройках.")
                }
                .font(.caption).foregroundStyle(.secondary)
                let withIncome = FinancialEngine.monthReserveWithTypicalIncome(balanceKopecks: balance, forecast: forecast)
                if withIncome != reserve {
                    Label("Если придут обычные нерегулярные поступления: ≈ \(signedRubles(withIncome))", systemImage: "arrow.down.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("Выберите счета, из которых считать запас: Настройки → «Запас до конца месяца»")
                    .foregroundStyle(.secondary)
            }
        }.glassRows()
    }

    private var forecastSection: some View {
        Section(header: Text("Прогноз на месяц")) {
            let f = forecast
            LabeledContent("Потрачено за \(f.elapsedDays) из \(f.daysInMonth) дн.", value: rubles(f.spentKopecks))
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Расходы к концу месяца", value: "≈ " + rubles(f.projectedExpenseKopecks))
                Text("обычно от \(rubles(f.projectedExpenseLowKopecks)) до \(rubles(f.projectedExpenseHighKopecks))")
                    .font(.caption).foregroundStyle(.secondary)
                if f.oneOffKopecks > 0 {
                    Text("Разовые покупки \(rubles(f.oneOffKopecks)) учтены как потраченные, но не в обычном темпе")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Доход за месяц", value: "≈ " + rubles(f.projectedIncomeKopecks))
                Text("пришло пока \(rubles(f.incomeKopecks)) + ожидаемая зарплата · в прошлом месяце \(rubles(f.previousMonthIncomeKopecks))")
                    .font(.caption).foregroundStyle(.secondary)
                if f.typicalIrregularIncomeKopecks > 0 {
                    Text("Нерегулярные поступления обычно ≈ \(rubles(f.typicalIrregularIncomeKopecks)) в месяц, в запас не входят")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !f.upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ещё ожидается").font(.caption).foregroundStyle(.secondary)
                    ForEach(f.upcoming) { payment in
                        HStack {
                            Image(systemName: payment.isIncome ? "arrow.down.circle" : "arrow.up.circle")
                                .foregroundStyle(payment.isIncome ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(payment.title).lineLimit(1)
                                Text(payment.overdue
                                     ? "ожидался \(payment.date.formatted(.dateTime.day().month())), не пришёл"
                                     : payment.date.formatted(.dateTime.day().month()))
                                    .font(.caption)
                                    .foregroundStyle(payment.overdue ? .orange : .secondary)
                            }
                            Spacer()
                            Text((payment.isIncome ? "+" : "−") + rubles(payment.amountKopecks))
                                .foregroundStyle(payment.isIncome ? .green : .primary)
                        }
                        .font(.subheadline)
                    }
                }
            }
            NavigationLink {
                RegularPaymentsView(browser: browser, presentation: presentation)
            } label: {
                Label("Все регулярные платежи", systemImage: "arrow.triangle.2.circlepath")
            }
            if !f.baselineMonths.isEmpty {
                DisclosureGroup("Как посчитано") {
                    ForEach(f.baselineMonths) { month in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(month.month.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(rubles(month.netExpenseKopecks)).font(.subheadline)
                            }
                            Text("обычные \(rubles(month.variableKopecks)) · регулярные \(rubles(month.recurringKopecks)) · разовые \(rubles(month.oneOffKopecks))")
                                .font(.caption).foregroundStyle(.secondary)
                            if !month.largestOneOffs.isEmpty {
                                Text("разовые по категориям: " + month.largestOneOffs.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Расходы к концу месяца = потрачено + ещё ожидаемые регулярные + обычные траты до конца месяца. Обычные траты берутся по медиане этих месяцев; текущий месяц влияет на них постепенно: в начале почти нет, к концу почти полностью. Вилка — по нижней и верхней четверти этих месяцев.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if f.historyMonths < 3 {
                Text("Истории пока мало (\(f.historyMonths) мес.), прогноз приблизительный.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.glassRows()
    }

    private func reserveColor(_ reserve: Int64) -> Color {
        switch FinancialEngine.reserveStatus(reserve, bufferKopecks: bufferKopecks) {
        case .fine: return .green
        case .tight: return .yellow
        case .short: return .red
        }
    }

    private func signedRubles(_ kopecks: Int64) -> String {
        (kopecks >= 0 ? "+" : "−") + rubles(kopecks >= 0 ? kopecks : -kopecks)
    }

    private func rubles(_ kopecks: Int64) -> String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }
}
