import SwiftUI
import WidgetKit

struct StreakEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct StreakProvider: TimelineProvider {
    func placeholder(in context: Context) -> StreakEntry {
        StreakEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (StreakEntry) -> Void) {
        completion(StreakEntry(date: Date(), data: .load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StreakEntry>) -> Void) {
        let data = WidgetData.load()
        let now = Date()
        let entries = data.timelineDates(from: now).map { StreakEntry(date: $0, data: data) }
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: now)!
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }
}

struct StreakWidgetView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.widgetFamily) var family
    let entry: StreakEntry

    private var effectiveDark: Bool {
        switch entry.data.themePreference {
        case "dark": return true
        case "light": return false
        default: return colorScheme == .dark
        }
    }

    private var colors: WidgetColors { effectiveDark ? .dark : .light }
    private var isMedium: Bool { family == .systemMedium }

    private var today: Date {
        logicalDayStart(entry.date, offsetHours: entry.data.returnsOffsetHours)
    }

    var body: some View {
        let practiceDays = entry.data.practiceDates.filter { $0 <= today }
        let returns = max(entry.data.minimumReturns, practiceDays.count)
        StatWidgetBody(
            value: "\(returns)",
            unit: NSLocalizedString("Returns", comment: "Nombre del total de días de práctica."),
            doneToday: practiceDays.contains(today),
            allActivityDates: practiceDays,
            today: today,
            colors: colors,
            isMedium: isMedium
        )
    }
}

struct StreakWidget: Widget {
    let kind = "StreakWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StreakProvider()) { entry in
            StreakWidgetView(entry: entry)
                // Source params let DeepLinkService attribute the tap for analytics.
                .widgetURL(URL(string: "org.meditofoundation://medito/?source=home_widget&widget=streak"))
        }
        .configurationDisplayName("Returns")
        .description("Practice returns and calendar")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
