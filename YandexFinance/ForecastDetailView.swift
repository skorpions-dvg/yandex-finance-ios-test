import SwiftUI

struct ForecastDetailView: View {
    let forecast: FinancialEngine.MonthForecast
    /// Balance of the accounts the reserve counts; nil when there are none.
    let balanceKopecks: Int64?
    let accountNames: [String]
    let browser: BankBrowser
    let presentation: FinancePresentationCache
    /// The same setting the main screen reads: below this balance the end-of-month reserve turns yellow.
    @AppStorage("reserveBufferRubles") private var reserveBufferRubles = 25_000
    /// The cautious part of the irregular income goes into the reserve (decision C); the main screen reads the same setting.
    @AppStorage("reserveCountsIrregular") private var countsIrregular = true
    @FocusState private var bufferFocused: Bool
    /// The late payment whose new day is being chosen.
    @State private var moving: FinancialEngine.UpcomingPayment?
    @State private var moveDate = Date()
    @Environment(\.dismiss) private var dismiss

    private var bufferKopecks: Int64 { Int64(reserveBufferRubles) * 100 }

    var body: some View {
        NavigationStack {
            List {
                reserveSection
                forecastSection
            }
            .appSurface()
            .sheet(item: $moving) { payment in
                NavigationStack {
                    Form {
                        DatePicker("Новая дата", selection: $moveDate, in: Date()..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                        Text("«\(payment.title)» будет ожидаться в этот день; до него в вопросах не появится.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .navigationTitle("Перенести платёж")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Отмена") { moving = nil } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Готово") {
                                answer(payment, .moved, movedTo: Calendar.current.startOfDay(for: moveDate))
                                moving = nil
                            }
                        }
                    }
                }
                .presentationDetents([.large])
            }
            .navigationTitle("Прогноз на месяц")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть", systemImage: "xmark") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { bufferFocused = false }
                }
            }
        }
    }

    /// One main number: what is expected to be left at the end of the month.
    private var reserveSection: some View {
        Section {
            Text("Останется к концу месяца").font(.headline)
            if let balance = balanceKopecks {
                let reserve = FinancialEngine.monthReserve(balanceKopecks: balance, forecast: forecast, includeIrregular: countsIrregular)
                let range = FinancialEngine.monthReserveRange(balanceKopecks: balance, forecast: forecast, includeIrregular: countsIrregular)
                let irregularLeft = countsIrregular ? forecast.cautiousIrregularLeftKopecks : 0
                Text(signedRubles(reserve))
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(reserveColor(reserve))
                if forecast.hasEnoughHistory {
                    Text("обычно от \(signedRubles(range.low)) до \(signedRubles(range.high))")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Мало данных: прогноз станет точнее после двух полных месяцев истории (сейчас \(forecast.historyMonths)).")
                        .font(.subheadline).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Остаток \(rubles(balance)) − ещё расходы \(rubles(max(0, forecast.futureExpenseKopecks))) + ещё регулярные поступления \(rubles(forecast.expectedIncomeLeftKopecks))"
                         + (irregularLeft > 0 ? " + нерегулярные (осторожно) \(rubles(irregularLeft))" : ""))
                    Text("Счета: " + (accountNames.isEmpty ? "не выбраны" : accountNames.joined(separator: ", ")) + ". Отложенные деньги исключаются в настройках.")
                }
                .font(.caption).foregroundStyle(.secondary)
                let withIncome = FinancialEngine.monthReserveWithTypicalIncome(balanceKopecks: balance, forecast: forecast)
                if withIncome > reserve {
                    Label("Если придут обычные нерегулярные поступления: ≈ \(signedRubles(withIncome))", systemImage: "arrow.down.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("Выберите счета, из которых считать запас: Настройки → «Запас до конца месяца»")
                    .foregroundStyle(.secondary)
            }
            bufferRow
            if forecast.cautiousIrregularIncomeKopecks > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Учитывать нерегулярные поступления", isOn: $countsIrregular)
                    Text("Самый маленький приход за последние полные месяцы"
                         + (forecast.cautiousIrregularMonth.map { " (\($0.formatted(.dateTime.month(.wide))))" } ?? "")
                         + ": \(rubles(forecast.cautiousIrregularIncomeKopecks)); в этом месяце уже пришло \(rubles(forecast.irregularIncomeSoFarKopecks)), в запас добавляется \(rubles(forecast.cautiousIrregularLeftKopecks)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.glassRows()
    }

    /// The threshold of the yellow colour: a number to type or to step with «−» and «+».
    private var bufferRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Остаток ниже")
                TextField("0", value: $reserveBufferRubles, format: .number.grouping(.automatic))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($bufferFocused)
                    .frame(maxWidth: 110)
                Text("₽").foregroundStyle(.secondary)
                Spacer()
                Stepper("", value: $reserveBufferRubles, in: 0...500_000, step: 5_000).labelsHidden()
            }
            .onChange(of: reserveBufferRubles) { _, value in
                if value < 0 { reserveBufferRubles = 0 } else if value > 500_000 { reserveBufferRubles = 500_000 }
            }
            Text("Красный — если до конца месяца не хватает, жёлтый — если остаток ниже этой суммы.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var forecastSection: some View {
        Section(header: Text("Прогноз на месяц")) {
            let f = forecast
            LabeledContent("Потрачено за \(f.elapsedDays) из \(f.daysInMonth) дн.", value: rubles(f.spentKopecks))
            if f.refundsKopecks > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Возвраты уже учтены", value: rubles(f.refundsKopecks))
                    Text("Возвраты уменьшают потраченное, но не ожидаемые расходы до конца месяца")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Расходы к концу месяца", value: "≈ " + rubles(f.projectedExpenseKopecks))
                if f.hasEnoughHistory {
                    Text("обычно от \(rubles(f.projectedExpenseLowKopecks)) до \(rubles(f.projectedExpenseHighKopecks))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("по темпу этого месяца, без опыта прошлых месяцев")
                        .font(.caption).foregroundStyle(.orange)
                }
                if f.oneOffKopecks > 0 {
                    Text("Разовые покупки \(rubles(f.oneOffKopecks)) учтены как потраченные, но не в обычном темпе")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Доход за месяц", value: "≈ " + rubles(f.projectedIncomeKopecks))
                Text(f.expectedIncomeLeftKopecks > 0
                     ? "пришло пока \(rubles(f.incomeKopecks)) + ожидается регулярное \(rubles(f.expectedIncomeLeftKopecks)) · в прошлом месяце \(rubles(f.previousMonthIncomeKopecks))"
                     : "пришло пока \(rubles(f.incomeKopecks)) · в прошлом месяце \(rubles(f.previousMonthIncomeKopecks))")
                    .font(.caption).foregroundStyle(.secondary)
                if f.typicalIrregularIncomeKopecks > 0 {
                    Text("Нерегулярные поступления обычно ≈ \(rubles(f.typicalIrregularIncomeKopecks)) в месяц, в запас не входят")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !f.questions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Не пришли в срок — отметьте").font(.caption).foregroundStyle(.orange)
                    ForEach(f.questions) { payment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(payment.title).lineLimit(1)
                                Spacer()
                                Text((payment.isIncome ? "+" : "−") + rubles(payment.amountKopecks))
                            }
                            .font(.subheadline)
                            Text("ожидался \(payment.date.formatted(.dateTime.day().month())), прошло больше недели; в прогноз не входит")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button("Уже пришло") { answer(payment, .arrived) }
                                Button("Не будет") { answer(payment, .skipped) }
                                Button("Перенести") {
                                    moveDate = Date()
                                    moving = payment
                                }
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }
            }
            let expected = f.upcoming.filter { $0.status != .question }
            if !expected.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ещё ожидается").font(.caption).foregroundStyle(.secondary)
                    ForEach(expected) { payment in
                        HStack {
                            Image(systemName: payment.isIncome ? "arrow.down.circle" : "arrow.up.circle")
                                .foregroundStyle(payment.isIncome ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(payment.title).lineLimit(1)
                                Text(payment.status == .waiting
                                     ? "ожидался \(payment.date.formatted(.dateTime.day().month())), ещё ждём до \((payment.waitUntil ?? payment.date).formatted(.dateTime.day().month()))"
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
                            Text("обычные \(rubles(month.variableKopecks)) · регулярные \(rubles(month.recurringKopecks)) · разовые \(rubles(month.oneOffKopecks))"
                                 + (month.otherRefundsKopecks > 0 ? " · возвраты −\(rubles(month.otherRefundsKopecks))" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                            if !month.largestOneOffs.isEmpty {
                                Text("разовые по категориям: " + month.largestOneOffs.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Расходы к концу месяца = потрачено + ещё ожидаемые регулярные + обычные траты до конца месяца. Обычные траты берутся по медиане этих месяцев; текущий месяц влияет на них постепенно: в начале почти нет, к концу почти полностью. Вилка — по нижней и верхней четверти этих месяцев. Обычные траты считаются по покупкам: покупка, возвращённая в том же месяце, в них не входит, а возврат за старую покупку показан отдельно.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if f.hasEnoughHistory && f.historyMonths < 3 {
                Text("Истории пока мало (\(f.historyMonths) мес.), прогноз приблизительный.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.glassRows()
    }

    /// Stores the owner's answer about a late payment; the forecast is computed again with it.
    private func answer(_ payment: FinancialEngine.UpcomingPayment, _ kind: FinancialEngine.PaymentAnswer.Kind, movedTo: Date? = nil) {
        _ = browser.updateUserData { history in
            var answers = history.paymentAnswers ?? [:]
            answers[payment.key] = FinancialEngine.PaymentAnswer(kind: kind, movedTo: movedTo)
            history.paymentAnswers = answers
        }
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
