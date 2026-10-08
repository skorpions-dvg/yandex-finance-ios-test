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
    @FocusState private var bufferFocused: Bool
    /// The late payment whose new day is being chosen.
    @State private var moving: FinancialEngine.UpcomingPayment?
    @State private var moveDate = Date()
    /// The range from the errors of the past forecasts (decision 4), computed in the background when the window opens.
    @State private var spread: FinancialEngine.ForecastRange?
    @Environment(\.dismiss) private var dismiss

    private var bufferKopecks: Int64 { Int64(reserveBufferRubles) * 100 }

    var body: some View {
        NavigationStack {
            List {
                reserveSection
                forecastSection
            }
            .appSurface()
            .task { await loadSpread() }
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
                // Only money that is there or regularly comes: an irregular income is never counted in advance (the reserve
                // cannot exceed the balance at the start of a month only because transfers usually come).
                let reserve = FinancialEngine.monthReserve(balanceKopecks: balance, forecast: forecast)
                Text(signedRubles(reserve))
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(reserveColor(reserve))
                if forecast.hasEnoughHistory {
                    // More spending than forecast leaves less: the high error of the spending is the low end of the reserve.
                    spreadLine { spread in
                        "от \(signedRubles(reserve - spread.highErrorKopecks)) до \(signedRubles(reserve - spread.lowErrorKopecks))"
                    }
                    .font(.subheadline)
                } else {
                    Text("Мало данных: прогноз станет точнее после двух полных месяцев истории (сейчас \(forecast.historyMonths)).")
                        .font(.subheadline).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Остаток \(rubles(balance)) − ещё расходы \(rubles(max(0, forecast.futureExpenseKopecks))) + ещё регулярные поступления \(rubles(forecast.expectedIncomeLeftKopecks))")
                    Text("Счета: " + (accountNames.isEmpty ? "не выбраны" : accountNames.joined(separator: ", ")) + ". Отложенные деньги исключаются ниже, в «Счета для запаса».")
                }
                .font(.caption).foregroundStyle(.secondary)
                // A hint, not the reserve: the smallest irregular income of the last full months that has not come yet.
                if forecast.cautiousIrregularLeftKopecks > 0 {
                    let withIncome = FinancialEngine.monthReserve(balanceKopecks: balance, forecast: forecast, includeIrregular: true)
                    let month = forecast.cautiousIrregularMonth.map { " (как в \($0.formatted(.dateTime.month(.wide))))" } ?? ""
                    Label("Если придёт хотя бы минимум обычных поступлений\(month): ≈ \(signedRubles(withIncome))", systemImage: "arrow.down.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("Выберите счета, из которых считать запас: «Счета для запаса» ниже.")
                    .foregroundStyle(.secondary)
            }
            bufferRow
            // The choice of the accounts lives here, next to the reserve it changes (it used to be in Settings).
            NavigationLink {
                ReserveAccountsView(browser: browser)
            } label: {
                Label("Счета для запаса", systemImage: "wallet.pass")
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
                    spreadLine { spread in
                        "от \(rubles(max(0, f.projectedExpenseKopecks + spread.lowErrorKopecks))) до \(rubles(f.projectedExpenseKopecks + spread.highErrorKopecks))"
                    }
                    .font(.caption)
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
                    Text("Расходы к концу месяца = потрачено + ещё ожидаемые регулярные + обычные траты до конца месяца. Обычные траты берутся по медиане этих месяцев; текущий месяц влияет на них постепенно: в начале почти нет, к концу почти полностью. Диапазон — весь разброс ошибок прошлых прогнозов того же числа месяца: прогноз каждого из последних месяцев пересчитан так, как будто сегодня то же число того месяца, и сравнён с тем, сколько на самом деле ушло; от четырёх таких месяцев. Обычные траты считаются по покупкам: покупка, возвращённая в том же месяце, в них не входит, а возврат за старую покупку показан отдельно.")
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

    /// The line of the range: «весь прошлый разброс за N мес.: от … до …», or why there is none yet.
    @ViewBuilder
    private func spreadLine(_ text: @escaping (FinancialEngine.ForecastRange) -> String) -> some View {
        if let spread {
            if spread.isShown {
                Text("весь прошлый разброс за \(spread.months) мес.: " + text(spread)).foregroundStyle(.secondary)
            } else {
                Text("Диапазон появится, когда для сверки наберётся 4 прошлых месяца (сейчас \(spread.months)).").foregroundStyle(.secondary)
            }
        } else {
            Text("Считаю диапазон по прошлым месяцам…").foregroundStyle(.secondary)
        }
    }

    /// The range is a forecast for each of the last months again: in the background, once a day and for the same data.
    private func loadSpread() async {
        if let cached = presentation.cachedForecastRange() { spread = cached; return }
        let inputs = presentation.inputs(browser.history)
        let taxonomy = browser.history.expenseTaxonomy
        let computed = await Task.detached(priority: .userInitiated) {
            FinancialEngine.forecastRange(inputs, taxonomy: taxonomy)
        }.value
        presentation.storeForecastRange(computed)
        spread = computed
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
