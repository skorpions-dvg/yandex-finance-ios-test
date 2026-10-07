import SwiftUI
import Charts

struct TrendChart: View {
    let periods: [ReportSeries.Period]
    let unit: ReportUnit
    let onSelect: (Date) -> Void

    private var component: Calendar.Component { unit == .day ? .day : .month }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(periods) { period in
                BarMark(x: .value("Период", period.id, unit: component),
                        y: .value("Сумма", Double(period.report.incomeKopecks) / 100))
                    .foregroundStyle(by: .value("Вид", "Доходы"))
                    .position(by: .value("Вид", "Доходы"))
                    .accessibilityLabel(label(period.id) + ", доходы")
                    .accessibilityValue(money(period.report.incomeKopecks))
                BarMark(x: .value("Период", period.id, unit: component),
                        y: .value("Сумма", Double(period.report.netExpenseKopecks) / 100))
                    .foregroundStyle(by: .value("Вид", "Расходы"))
                    .position(by: .value("Вид", "Расходы"))
                    .accessibilityLabel(label(period.id) + ", расходы")
                    .accessibilityValue(money(period.report.netExpenseKopecks))
            }
            .chartForegroundStyleScale(["Доходы": Color.green, "Расходы": Color.primary.opacity(0.7)])
            .chartLegend(position: .bottom)
            .chartXAxis {
                AxisMarks(values: .stride(by: component, count: unit == .day ? 2 : 1)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(label(date)).font(.caption2) }
                    }
                }
            }
            .chartOverlay { proxy in
                PeriodChartTapOverlay(proxy: proxy, intervals: periods.map(\.interval), onSelect: onSelect)
            }
            .frame(height: 220)

            let average = ReportSeries.average(periods)
            Text("В среднем за \(unit == .day ? "день" : "месяц"): расходы \(money(average.expenseKopecks)), доходы \(money(average.incomeKopecks))")
                .font(.caption).foregroundStyle(.secondary)
            if average.activePeriods == 0 {
                Text("Операций за эти периоды нет").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ date: Date) -> String {
        date.formatted(unit == .day ? .dateTime.day() : .dateTime.month(.abbreviated))
    }

    private func money(_ amount: Int64) -> String {
        (Decimal(amount) / 100).formatted(.currency(code: "RUB"))
    }
}

struct CategoryTrendChart: View {
    let points: [ReportSeries.CategoryPoint]
    let group: String
    let unit: ReportUnit
    let intervals: [DateInterval]
    let onSelect: (Date) -> Void

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("Период", point.date, unit: unit == .day ? .day : .month),
                     y: .value("Расходы", Double(point.amountKopecks) / 100))
                .foregroundStyle(OperationRow.expenseGroupIcon(group).color)
            PointMark(x: .value("Период", point.date, unit: unit == .day ? .day : .month),
                      y: .value("Расходы", Double(point.amountKopecks) / 100))
                .foregroundStyle(OperationRow.expenseGroupIcon(group).color)
                .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted) + ", " + group)
                .accessibilityValue((Decimal(point.amountKopecks) / 100).formatted(.currency(code: "RUB")))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: unit == .day ? .day : .month, count: unit == .day ? 2 : 1)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(unit == .day ? .dateTime.day() : .dateTime.month(.abbreviated)))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            PeriodChartTapOverlay(proxy: proxy, intervals: intervals, onSelect: onSelect)
        }
        .frame(height: 180)
    }
}

/// A tap only: vertical scrolling and the application's existing swipes keep their recognizers.
struct PeriodChartTapOverlay: View {
    let proxy: ChartProxy
    let intervals: [DateInterval]
    let onSelect: (Date) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear.contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    guard let frame = proxy.plotFrame else { return }
                    let plot = geometry[frame]
                    guard plot.contains(tap.location),
                          let date = proxy.value(atX: tap.location.x - plot.minX, as: Date.self),
                          let period = intervals.first(where: { date >= $0.start && date < $0.end }) else { return }
                    onSelect(period.start)
                })
        }
    }
}
