import SwiftUI
import Charts

/// Compact bar chart of daily net expenses for one month.
struct DailyExpenseChart: View {
    /// One entry per day, already in order.
    let days: [FinancialEngine.DailyAmount]

    private func rubles(_ kopecks: Int64) -> String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Итого")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(rubles(total))
                        .font(.headline)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("В среднем в день")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(rubles(average))
                        .font(.headline)
                }
            }

            if allZero {
                Text("Расходов за период нет")
                    .foregroundStyle(.secondary)
            } else {
                Chart(days) { day in
                    BarMark(
                        x: .value("День", day.day, unit: .day),
                        y: .value("Расход", Double(day.amountKopecks) / 100)
                    )
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) {
                        AxisValueLabel(format: .dateTime.day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) {
                        AxisGridLine()
                        AxisValueLabel(format: .currency(code: "RUB").precision(.fractionLength(0)))
                    }
                }
                .frame(height: 160)
            }
        }
    }

    private var total: Int64 {
        days.reduce(0) { $0 + $1.amountKopecks }
    }

    /// Integer division rounds toward zero.
    private var average: Int64 {
        days.isEmpty ? 0 : total / Int64(days.count)
    }

    private var allZero: Bool {
        days.allSatisfy { $0.amountKopecks == 0 }
    }
}

#Preview {
    let calendar = Calendar.current
    let start = calendar.date(byAdding: .day, value: -9, to: calendar.startOfDay(for: Date()))!
    let days = (0..<10).map { offset in
        FinancialEngine.DailyAmount(day: calendar.date(byAdding: .day, value: offset, to: start)!,
                                    amountKopecks: Int64.random(in: 0...300_000))
    }
    return List { DailyExpenseChart(days: days) }
}
