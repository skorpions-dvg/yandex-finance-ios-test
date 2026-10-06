import SwiftUI
import Charts

/// Compact donut chart of one month's spending by expense group,
/// plus a list of the groups. All UI text is in Russian.
struct CategoryExpenseChart: View {
    let groups: [FinancialEngine.CategoryAmount]
    let refundsKopecks: Int64

    // MARK: - Body

    var body: some View {
        if groups.isEmpty {
            Text("Расходов за период нет")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 12) {
                // Donut chart
                Chart(groups) { group in
                    SectorMark(
                        angle: .value("Сумма", Double(group.amountKopecks)),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(by: .value("Категория", group.title))
                }
                .chartForegroundStyleScale(
                    domain: groups.map(\.title),
                    range: groups.map { color(for: $0.title) }
                )
                .chartLegend(.hidden)
                .frame(height: 180)
                .chartBackground { proxy in
                    GeometryReader { geometry in
                        if let frame = proxy.plotFrame {
                            let rect = geometry[frame]
                            VStack(spacing: 2) {
                                Text("Всего")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(rubles(total))
                                    .font(.headline)
                            }
                            .position(x: rect.midX, y: rect.midY)
                        }
                    }
                }

                // List of groups
                ForEach(groups) { group in
                    HStack {
                        Circle()
                            .fill(color(for: group.title))
                            .frame(width: 10, height: 10)
                        Text(group.title)
                        Spacer()
                        Text(rubles(group.amountKopecks))
                        Text(
                            (Double(group.amountKopecks) / Double(total))
                                .formatted(.percent.precision(.fractionLength(0)))
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                // Refunds row
                if refundsKopecks > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Возвраты")
                            Spacer()
                            Text("−" + rubles(refundsKopecks))
                                .foregroundStyle(.secondary)
                        }
                        Text("Возвраты уменьшают итог расходов месяца.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Total amount of all groups in kopecks.
    private var total: Int64 {
        groups.reduce(0) { $0 + $1.amountKopecks }
    }

    /// Convert kopecks to a formatted ruble string.
    private func rubles(_ kopecks: Int64) -> String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }

    /// Map a category title to the same color used in the chart.
    private func color(for title: String) -> Color {
        switch title {
        case "Еда": return .orange
        case "Транспорт": return .blue
        case "Покупки": return .purple
        case "Обязательные": return .teal
        case "Другое": return .gray
        default: return .gray
        }
    }
}

// MARK: - Preview

#Preview {
    List {
        CategoryExpenseChart(
            groups: [
                FinancialEngine.CategoryAmount(title: "Еда", amountKopecks: 1_200_000),
                FinancialEngine.CategoryAmount(title: "Транспорт", amountKopecks: 300_000),
                FinancialEngine.CategoryAmount(title: "Покупки", amountKopecks: 500_000),
                FinancialEngine.CategoryAmount(title: "Обязательные", amountKopecks: 2_000_000),
                FinancialEngine.CategoryAmount(title: "Другое", amountKopecks: 150_000)
            ],
            refundsKopecks: 188_600
        )
    }
}
