import SwiftUI

struct ForecastDetailView: View {
    let forecast: FinancialEngine.MonthForecast
    let balanceKopecks: Int64?
    let bufferKopecks: Int64
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Запас до конца месяца").font(.headline)
                    if let balance = balanceKopecks {
                        let reserve = FinancialEngine.monthReserve(balanceKopecks: balance, forecast: forecast)
                        Text(signedRubles(reserve))
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(reserveColor(reserve))
                        Text("Остаток \(rubles(balance)) минус ещё ожидаемые расходы \(rubles(forecast.projectedExpenseKopecks - forecast.spentKopecks)) до конца месяца, без будущих поступлений.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Добавьте счета, чтобы считать запас из остатка")
                            .foregroundStyle(.secondary)
                    }
                }.listRowBackground(GlassRowBackground())
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

    private var forecastSection: some View {
        Section(header: Text("Прогноз на месяц")) {
            let f = forecast
            LabeledContent("Потрачено за \(f.elapsedDays) из \(f.daysInMonth) дн.", value: rubles(f.spentKopecks))
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Расходы к концу месяца", value: "≈ " + rubles(f.projectedExpenseKopecks))
                Text("обычно от \(rubles(f.projectedExpenseLowKopecks)) до \(rubles(f.projectedExpenseHighKopecks))")
                    .font(.caption).foregroundStyle(.secondary)
                if f.oneOffKopecks > 0 {
                    Text("Разовые покупки \(rubles(f.oneOffKopecks)) учтены как потраченные, но не в темпе")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Доход за месяц", value: "≈ " + rubles(f.projectedIncomeKopecks))
                Text("пришло пока \(rubles(f.incomeKopecks)) + ожидаемая зарплата · в прошлом месяце \(rubles(f.previousMonthIncomeKopecks))")
                    .font(.caption).foregroundStyle(.secondary)
                if f.typicalIrregularIncomeKopecks > 0 {
                    Text("Нерегулярные поступления обычно ≈ \(rubles(f.typicalIrregularIncomeKopecks)) в месяц")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            balanceLine(f.projectedBalanceKopecks, scenario: "Без новых поступлений")
            if f.balanceWithTypicalIncomeKopecks != f.projectedBalanceKopecks {
                balanceLine(f.balanceWithTypicalIncomeKopecks, scenario: "С обычными поступлениями")
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
            if !f.baselineMonths.isEmpty {
                DisclosureGroup("Как посчитано") {
                    ForEach(f.baselineMonths) { month in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(month.month.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(rubles(month.netExpenseKopecks)).font(.subheadline)
                            }
                            Text("переменные \(rubles(month.variableKopecks)) · регулярные \(rubles(month.recurringKopecks)) · разовые \(rubles(month.oneOffKopecks))")
                                .font(.caption).foregroundStyle(.secondary)
                            if !month.largestOneOffs.isEmpty {
                                Text("разовые: " + month.largestOneOffs.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Расходы к концу месяца = потрачено + ещё ожидаемые регулярные + переменные траты до конца месяца по медиане этих месяцев с поправкой на темп. Вилка — по нижней и верхней четверти этих месяцев.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if f.historyMonths < 3 {
                Text("Истории пока мало (\(f.historyMonths) мес.), прогноз приблизительный.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.listRowBackground(GlassRowBackground())
    }
    
    private func balanceLine(_ balance: Int64, scenario: String) -> some View {
        Label(balance >= 0
              ? "\(scenario): останется ≈ \(rubles(balance))"
              : "\(scenario): не хватит ≈ \(rubles(-balance))",
              systemImage: balance >= 0 ? "checkmark.circle" : "exclamationmark.triangle")
            .foregroundStyle(balance >= 0 ? .green : .orange)
            .font(.subheadline)
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
