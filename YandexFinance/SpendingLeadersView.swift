import SwiftUI

private func leaderRubles(_ kopecks: Int64) -> String {
    (Decimal(kopecks) / 100).formatted(.currency(code: "RUB").precision(.fractionLength(0...2)))
}

/// «Куда уходят деньги»: the three biggest groups of the month's spending, each against the same days of the month before, the
/// shops inside, and the subscriptions. Only facts: no advice.
@MainActor
struct SpendingLeadersView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache
    let month: Date

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let now = Date()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let result: SpendingLeaders = presentation.value("leaders:\(BudgetEngine.monthKey(month)):\(day)") {
            ReportEngine.spendingLeaders(presentation.inputs(browser.history), month: month, now: now, taxonomy: browser.history.expenseTaxonomy)
        }
        List {
            Section {
                Text(periodTitle(result.periods))
                    .font(.headline)
                Text(result.periods.isPartial
                     ? "Каждая группа сравнивается с теми же днями прошлого месяца: иначе неполный месяц всегда выглядел бы дешевле."
                     : "Каждая группа сравнивается с прошлым месяцем целиком.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.glassRows()
            if result.leaders.isEmpty {
                Section {
                    ContentUnavailableView("Расходов пока нет", systemImage: "tray",
                                           description: Text("Когда за этот период появятся траты, здесь будут три главные группы."))
                }.glassRows()
            } else {
                ForEach(result.leaders) { leader in
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(ReportPalette.color(leader.group)).frame(width: 10, height: 10)
                                Text(leader.group).font(.headline)
                                Spacer(minLength: 8)
                                Text(leaderRubles(leader.amountKopecks)).font(.headline).monospacedDigit()
                            }
                            Text("\(leader.sharePercent) % расходов периода").font(.caption).foregroundStyle(.secondary)
                            Text(changeText(leader, partial: result.periods.isPartial))
                                .font(.caption).foregroundStyle(changeColor(leader))
                        }
                        ForEach(leader.shops) { shop in
                            HStack {
                                Text(shop.title).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(leaderRubles(shop.amountKopecks)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    } header: {
                        Text(leader.shops.isEmpty ? "" : "Где потрачено")
                    }.glassRows()
                }
            }
            subscriptionsSections(now: now, calendar: calendar)
        }
        .appSurface()
        .navigationTitle("Куда уходят деньги")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func periodTitle(_ periods: MonthComparisonPeriods) -> String {
        let calendar = Calendar.current
        let name = periods.current.start.formatted(.dateTime.month(.wide).year()).capitalized
        guard periods.isPartial else { return name }
        let last = calendar.date(byAdding: .second, value: -1, to: periods.current.end) ?? periods.current.end
        return name + ": с 1 по \(calendar.component(.day, from: last))"
    }

    private func changeText(_ leader: SpendingLeader, partial: Bool) -> String {
        let than = partial ? "чем в прошлом месяце за тот же срок" : "чем в прошлом месяце"
        guard leader.previousKopecks > 0 else { return partial ? "в прошлом месяце за тот же срок трат не было" : "в прошлом месяце трат не было" }
        let change = leader.changeKopecks
        if change == 0 { return "столько же, \(than)" }
        let percent = abs(change) * 100 / leader.previousKopecks
        let amount = change > 0 ? "на \(leaderRubles(change)) больше" : "на \(leaderRubles(-change)) меньше"
        return "\(amount) (\(percent) %), \(than)"
    }

    private func changeColor(_ leader: SpendingLeader) -> Color {
        guard leader.previousKopecks > 0, leader.changeKopecks != 0 else { return .secondary }
        return leader.changeKopecks > 0 ? .orange : .green
    }

    // MARK: Subscriptions

    @ViewBuilder
    private func subscriptionsSections(now: Date, calendar: Calendar) -> some View {
        let added = browser.history.subscriptions ?? []
        let hidden = Set(browser.history.notSubscriptionKeys ?? [])
        let addedKeys = Set(added.map { FinancialEngine.counterpartyKey($0.name) })
        let found: [FinancialEngine.RecurringPattern] = presentation.value("subs-found:\(calendar.startOfDay(for: now))") {
            FinancialEngine.recurringPatterns(presentation.inputs(browser.history), now: now, calendar: calendar)
                .filter { !$0.isIncome && ($0.intervalDays == 30 || $0.intervalDays == 365) }
        }
        let shown = found.filter { !hidden.contains(FinancialEngine.counterpartyKey($0.title)) && !addedKeys.contains(FinancialEngine.counterpartyKey($0.title)) }
        Section {
            if added.isEmpty {
                Text("Здесь будут подписки, которые вы добавили сами.").foregroundStyle(.secondary)
            }
            ForEach(added) { subscription in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subscription.name).lineLimit(1)
                        Text(commitmentSchedule(day: subscription.day, month: subscription.month)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(leaderRubles(subscription.amountKopecks)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            NavigationLink {
                SubscriptionsView(browser: browser)
            } label: {
                Label("Добавить или изменить подписки", systemImage: "repeat")
            }
        } header: {
            Text("Подписки, которые вы добавили")
        } footer: {
            if !added.isEmpty {
                Text("≈ " + leaderRubles(added.reduce(Int64(0)) { $0 + ($1.month == nil ? $1.amountKopecks : $1.amountKopecks / 12) }) + " в месяц")
            }
        }.glassRows()
        if !shown.isEmpty || !hidden.isEmpty {
            Section {
                ForEach(shown.indices, id: \.self) { index in
                    let pattern = shown[index]
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pattern.title).lineLimit(1)
                            Text(RegularPayments.periodTitle(intervalDays: pattern.intervalDays)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(leaderRubles(pattern.typicalAmountKopecks)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .swipeActions {
                        Button("Это не подписка") { hide(pattern.title) }.tint(.gray)
                    }
                    .contextMenu {
                        Button("Это не подписка", systemImage: "eye.slash") { hide(pattern.title) }
                    }
                }
                if !hidden.isEmpty {
                    Button("Показать скрытые (\(hidden.count))") {
                        _ = browser.updateUserData { $0.notSubscriptionKeys = nil }
                    }
                    .font(.footnote)
                }
            } header: {
                Text("Найдено в операциях")
            } footer: {
                if !shown.isEmpty {
                    Text("≈ " + leaderRubles(shown.reduce(Int64(0)) { $0 + RegularPayments.monthlyKopecks(of: $1) }) + " в месяц. Платёж, который не подписка, смахните влево или удерживайте.")
                }
            }.glassRows()
        }
    }

    private func hide(_ title: String) {
        let key = FinancialEngine.counterpartyKey(title)
        _ = browser.updateUserData { history in
            var keys = history.notSubscriptionKeys ?? []
            if !keys.contains(key) { keys.append(key) }
            history.notSubscriptionKeys = keys
        }
    }
}
