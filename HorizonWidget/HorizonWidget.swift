import SwiftUI
import WidgetKit

/// The Home Screen widget in three sizes: it only shows the summary file the app wrote (WidgetSummary.swift).
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
        let calendar = Calendar.current
        // The next day by the calendar: on the day the clocks go back it has 25 hours (GPT stage 63, W63-5).
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        // The file is read again every 30 minutes (about 48 times a day, within the system's budget): the app's request to
        // redraw, sent as it goes to the background, may be put off by the system for a long time.
        let next = min(now.addingTimeInterval(30 * 60), midnight)
        completion(Timeline(entries: [SummaryEntry(date: now, state: state), SummaryEntry(date: midnight, state: state)],
                            policy: .after(next)))
    }
}

/// The colours of the widget: the dark blue of the Horizon icon.
private enum Palette {
    static let top = Color(red: 0.07, green: 0.15, blue: 0.27)
    static let bottom = Color(red: 0.03, green: 0.07, blue: 0.14)
    static let text = Color.white
    static let secondary = Color(red: 0.55, green: 0.73, blue: 0.93)
    static let tile = Color.white.opacity(0.08)
    static let track = Color.white.opacity(0.14)
    static let bar = Color(red: 0.22, green: 0.54, blue: 0.87)
    static let category = Color(red: 0.36, green: 0.79, blue: 0.65)
}

/// What one summary shows today: the sums of another day or month are dashes, not stale numbers.
private struct Shown {
    let summary: WidgetSummary
    let today: Bool
    let month: Bool

    init(_ summary: WidgetSummary, at date: Date) {
        self.summary = summary
        // Taken in another time zone, the day and the month had other bounds: dashes until the app writes a new summary
        // (GPT stage 63, W63-3).
        let sameZone = summary.timeZoneIdentifier == TimeZone.current.identifier
        today = sameZone && summary.dayKey == WidgetShared.dayKey(date)
        month = sameZone && summary.monthKey == WidgetShared.monthKey(date)
    }

    var reserve: Int64? { month ? summary.reserveEndOfMonthKopecks : nil }
    var spentToday: Int64? { today ? summary.spentTodayKopecks : nil }
    var spentMonth: Int64? { month ? summary.spentMonthKopecks : nil }
    var budget: (limit: Int64, spent: Int64)? {
        guard month, let limit = summary.budgetLimitKopecks, let spent = summary.budgetSpentKopecks, limit > 0 else { return nil }
        return (limit, spent)
    }
    var categories: [WidgetCategory] { month ? summary.topCategories ?? [] : [] }

    /// As the reserve card of the home screen.
    var reserveColor: Color {
        guard let reserve else { return Palette.text }
        switch summary.reserveStatus {
        case "fine": return .green
        case "tight": return .yellow
        case "short": return .red
        default: return reserve < 0 ? .red : Palette.text
        }
    }

    var reserveCaption: String? {
        guard reserve != nil else { return nil }
        switch summary.reserveStatus {
        case "fine": return "с запасом"
        case "tight": return "впритык"
        case "short": return "не хватает"
        default: return nil
        }
    }

    var updated: String {
        "обновлено " + summary.updatedAt.formatted(date: today ? .omitted : .numeric, time: .shortened)
    }
}

struct SummaryWidgetView: View {
    let entry: SummaryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(Palette.text)
            .containerBackground(for: .widget) {
                LinearGradient(colors: [Palette.top, Palette.bottom], startPoint: .top, endPoint: .bottom)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .summary(let summary) where summary.sumsHidden == true:
            notice("Суммы скрыты", "Включаются в настройках")
        case .summary(let summary):
            let shown = Shown(summary, at: entry.date)
            switch family {
            case .systemMedium: medium(shown)
            case .systemLarge: large(shown)
            default: small(shown)
            }
        case .empty:
            notice("Откройте Horizon", "Сводки ещё нет")
        case .noGroup:
            notice("Нет общей папки", "Виджет не видит приложение")
        case .unreadable:
            notice("Сводка закрыта", "Разблокируйте телефон")
        }
    }

    // MARK: Sizes

    private func small(_ shown: Shown) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            caption("Запас", systemImage: "gauge.with.dots.needle.33percent")
            reserveText(shown, font: .title2)
            if let words = shown.reserveCaption {
                Text(words).font(.caption2).foregroundStyle(shown.reserveColor)
            }
            Spacer(minLength: 4)
            line("Сегодня", shown.spentToday)
            line("Месяц", shown.spentMonth)
        }
    }

    private func medium(_ shown: Shown) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                caption("Запас до конца месяца", systemImage: "gauge.with.dots.needle.33percent")
                reserveText(shown, font: .title)
                if let words = shown.reserveCaption {
                    Text(words).font(.caption).foregroundStyle(shown.reserveColor)
                }
                Spacer(minLength: 4)
                Text(shown.updated).font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(Palette.track).frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                figure("Сегодня", systemImage: "calendar", shown.spentToday)
                figure("Месяц", systemImage: "calendar.badge.clock", shown.spentMonth)
                Spacer(minLength: 2)
                if let budget = shown.budget { budgetBlock(budget, short: true) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func large(_ shown: Shown) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                caption("Запас до конца месяца", systemImage: "gauge.with.dots.needle.33percent")
                reserveText(shown, font: .largeTitle)
                if let words = shown.reserveCaption {
                    Text(words).font(.caption).foregroundStyle(shown.reserveColor)
                }
            }
            HStack(spacing: 10) {
                tile("Сегодня", shown.spentToday)
                tile("Месяц", shown.spentMonth)
            }
            if let budget = shown.budget { budgetBlock(budget, short: false) }
            if !shown.categories.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    caption("Больше всего за месяц", systemImage: "chart.pie")
                    ForEach(Array(shown.categories.enumerated()), id: \.offset) { _, category in
                        categoryRow(category, total: max(shown.spentMonth ?? 0, shown.categories.map(\.kopecks).reduce(0, +)))
                    }
                }
            }
            Spacer(minLength: 0)
            Text(shown.updated).font(.caption2).foregroundStyle(Palette.secondary)
        }
    }

    // MARK: Parts

    private func caption(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1)
    }

    private func reserveText(_ shown: Shown, font: Font) -> some View {
        Text(shown.reserve.map { signedRubles($0) } ?? "—")
            .font(font.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.5)
            .foregroundStyle(shown.reserveColor)
            .privacySensitive()
    }

    private func line(_ title: String, _ kopecks: Int64?) -> some View {
        HStack {
            Text(title).foregroundStyle(Palette.secondary)
            Spacer(minLength: 4)
            Text(rubles(kopecks)).privacySensitive()
        }
        .font(.caption).lineLimit(1).minimumScaleFactor(0.7)
    }

    private func figure(_ title: String, systemImage: String, _ kopecks: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            caption(title, systemImage: systemImage)
            Text(rubles(kopecks)).font(.headline).lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
        }
    }

    private func tile(_ title: String, _ kopecks: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Palette.secondary)
            Text(rubles(kopecks)).font(.headline).lineLimit(1).minimumScaleFactor(0.6).privacySensitive()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Palette.tile, in: RoundedRectangle(cornerRadius: 12))
    }

    private func budgetBlock(_ budget: (limit: Int64, spent: Int64), short: Bool) -> some View {
        let level = WidgetShared.budgetLevel(spent: budget.spent, limit: budget.limit)
        let color: Color = level == .exceeded ? .red : level == .warning ? .orange : Palette.bar
        let left = budget.limit - budget.spent  // both within a trillion rubles (`WidgetSummary.isSane`)
        let percent = Int(min(9_999, Double(max(0, budget.spent)) * 100 / Double(budget.limit)))
        let words = left >= 0 ? "осталось " + rubles(left) : "превышен на " + rubles(-left)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(short ? "Бюджет" : "Бюджет месяца").foregroundStyle(Palette.secondary)
                Spacer(minLength: 4)
                Text(short ? "\(percent) %" : words).foregroundStyle(level == .calm ? Palette.secondary : color).privacySensitive()
            }
            .font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            bar(Double(budget.spent) / Double(budget.limit), color: color)
        }
    }

    private func categoryRow(_ category: WidgetCategory, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(category.name).lineLimit(1)
                Spacer(minLength: 4)
                Text(rubles(category.kopecks)).privacySensitive()
            }
            .font(.caption)
            bar(total > 0 ? Double(category.kopecks) / Double(total) : 0, color: Palette.category)
        }
        .privacySensitive()
    }

    /// The bar of the app's budgets (BudgetBar), in the widget's colours.
    private func bar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                if fraction > 0 {
                    Capsule().fill(color).frame(width: max(4, geometry.size.width * min(1, fraction)))
                }
            }
        }
        .frame(height: 5)
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Horizon").font(.caption2).foregroundStyle(Palette.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(Palette.secondary)
        }
    }

    // MARK: Money

    /// As on the reserve card of the home screen, in whole rubles: «+1 234 ₽», «−12 953 ₽».
    private func signedRubles(_ kopecks: Int64) -> String {
        let whole = WidgetShared.wholeRubles(kopecks)
        return (whole >= 0 ? "+" : "−") + grouped(whole >= 0 ? whole : -whole)
    }

    private func rubles(_ kopecks: Int64?) -> String {
        guard let kopecks else { return "—" }
        let whole = WidgetShared.wholeRubles(kopecks)
        return (whole < 0 ? "−" : "") + grouped(whole < 0 ? -whole : whole)
    }

    private func grouped(_ rubles: Int64) -> String {
        rubles.formatted(.number.locale(Locale(identifier: "ru_RU"))) + " ₽"
    }
}

@main
struct HorizonSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.widgetKind, provider: SummaryProvider()) { entry in
            SummaryWidgetView(entry: entry)
        }
        .configurationDisplayName("Horizon")
        .description("Запас до конца месяца, траты за сегодня и за месяц, бюджет и главные категории.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
