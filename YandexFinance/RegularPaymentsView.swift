import SwiftUI

struct RegularPaymentsView: View {
    @ObservedObject var browser: BankBrowser
    let presentation: FinancePresentationCache

    private struct PaymentRow: Identifiable {
        let id: Int
        let pattern: FinancialEngine.RecurringPattern
        let nextDate: Date
        let monthlyKopecks: Int64
    }

    var body: some View {
        let _ = presentation.prepare(browser.history)
        let now = Date()
        let calendar = Calendar.current
        let rows: [PaymentRow] = presentation.value("regular:\(calendar.startOfDay(for: now))") {
            FinancialEngine.recurringPatterns(presentation.inputs(browser.history), now: now, calendar: calendar)
                .enumerated().map { index, pattern in
                    PaymentRow(id: index, pattern: pattern,
                               nextDate: RegularPayments.nextDate(of: pattern, now: now, calendar: calendar),
                               monthlyKopecks: RegularPayments.monthlyKopecks(of: pattern))
                }
                .sorted { $0.nextDate == $1.nextDate ? $0.pattern.title < $1.pattern.title : $0.nextDate < $1.nextDate }
        }
        List {
            if rows.isEmpty {
                ContentUnavailableView("Регулярных платежей пока нет", systemImage: "arrow.triangle.2.circlepath",
                                       description: Text("Платежи появляются, когда в истории три повтора с похожей суммой и постоянным интервалом."))
            } else {
                paymentsSection("Расходы", rows: rows.filter { !$0.pattern.isIncome })
                paymentsSection("Доходы", rows: rows.filter { $0.pattern.isIncome })
            }
        }
        .appSurface()
        .navigationTitle("Регулярные платежи")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func paymentsSection(_ title: String, rows: [PaymentRow]) -> some View {
        Section {
            if rows.isEmpty {
                Text("Не найдены").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.pattern.title).lineLimit(2)
                        Text(RegularPayments.periodTitle(intervalDays: row.pattern.intervalDays) + " · " + rubles(row.pattern.typicalAmountKopecks))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(row.nextDate.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize()
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text("≈ " + rubles(rows.reduce(Int64(0)) { $0 + $1.monthlyKopecks }) + " в месяц")
        }
        .glassRows()
    }

    private func rubles(_ kopecks: Int64) -> String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB").precision(.fractionLength(0...2)))
    }
}
