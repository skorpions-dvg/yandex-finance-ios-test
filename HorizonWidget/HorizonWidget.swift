import SwiftUI
import WidgetKit

/// The small Home Screen widget: it only shows the summary file the app wrote (WidgetSummary.swift).
struct SummaryEntry: TimelineEntry {
    let date: Date
    let state: WidgetShared.ReadResult
}

struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: Date(), state: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        // The gallery preview never shows the user's sums.
        completion(SummaryEntry(date: Date(), state: context.isPreview ? .empty : WidgetShared.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        let now = Date()
        let state = WidgetShared.read()
        // A second entry at midnight marks the day's sums as old; the widget does not recount anything itself.
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        completion(Timeline(entries: [SummaryEntry(date: now, state: state), SummaryEntry(date: midnight, state: state)],
                            policy: .after(midnight)))
    }
}

struct SummaryWidgetView: View {
    let entry: SummaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch entry.state {
            case .summary(let summary) where summary.sumsHidden == true:
                notice("Суммы скрыты", "Включаются в настройках")
            case .summary(let summary):
                let today = summary.dayKey == WidgetShared.dayKey(entry.date)
                let month = summary.monthKey == WidgetShared.monthKey(entry.date)
                let reserve = month ? summary.reserveEndOfMonthKopecks : nil
                Text("Запас").font(.caption2).foregroundStyle(.secondary)
                Text(reserve.map { signedRubles($0) } ?? "—")
                    .font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle((reserve ?? 0) < 0 ? Color.red : Color.primary)
                    .privacySensitive()
                Text("Сегодня " + (today ? rubles(summary.spentTodayKopecks) : "—"))
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                    .privacySensitive()
                Text("Месяц " + (month ? rubles(summary.spentMonthKopecks) : "—"))
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                    .privacySensitive()
                Spacer(minLength: 0)
                Text((summary.label.map { "\($0) · " } ?? "обновлено ") + summary.updatedAt.formatted(date: today ? .omitted : .numeric, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            case .empty:
                notice("Откройте Horizon", "Сводки ещё нет")
            case .noGroup:
                notice("Нет общей папки", "Виджет не видит приложение")
            case .unreadable:
                notice("Сводка закрыта", "Разблокируйте телефон")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Horizon").font(.caption2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// As on the reserve card of the home screen: «+1 234 ₽», «−12 978 ₽».
    private func signedRubles(_ kopecks: Int64) -> String {
        (kopecks >= 0 ? "+" : "−") + rubles(kopecks >= 0 ? kopecks : -kopecks)
    }

    private func rubles(_ kopecks: Int64?) -> String {
        guard let kopecks else { return "—" }
        // Whole rubles without kopecks, otherwise always two digits: «21 000,50 ₽», not «21 000,5 ₽».
        let value = Double(kopecks) / 100
        let digits = kopecks % 100 == 0 ? 0 : 2
        return value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "ru_RU"))) + " ₽"
    }
}

@main
struct HorizonSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.widgetKind, provider: SummaryProvider()) { entry in
            SummaryWidgetView(entry: entry)
        }
        .configurationDisplayName("Horizon")
        .description("Запас до конца месяца, траты за сегодня и за месяц.")
        .supportedFamilies([.systemSmall])
    }
}
