import Foundation

// La puntuación usa las mismas fechas de actividad que el cálculo en Flutter.
enum StatCalculator {
    static func consistencyScore(activityDays: Set<Date>, today: Date, calendar: Calendar = .current) -> Int {
        let days = activityDays.filter { $0 <= today }
        guard let firstSessionDate = days.min() else { return 0 }
        let daysSinceFirstSession =
            (calendar.dateComponents([.day], from: firstSessionDate, to: today).day ?? 0) + 1

        if daysSinceFirstSession == 1 {
            return days.contains(today) ? 100 : 0
        }

        // Bootstrap phase: simple ratio for the first 30 days
        if daysSinceFirstSession < 30 {
            return percent(Double(days.count) / Double(daysSinceFirstSession))
        }

        // EMA phase: replay history day by day starting from day 30,
        // seeding with the ratio at day 29.
        let alpha = 0.1
        let gracePenalty = 0.5 // value used for a single isolated missed day

        let day29 = addDays(28, to: firstSessionDate, calendar)
        var ema = Double(days.filter { $0 <= day29 }.count) / 29

        var currentDay = addDays(29, to: firstSessionDate, calendar)
        while currentDay <= today {
            let dayValue: Double
            if days.contains(currentDay) {
                dayValue = 1
            } else {
                let nextDay = addDays(1, to: currentDay, calendar)
                let prevActive = days.contains(addDays(-1, to: currentDay, calendar))
                let nextActive = nextDay > today ? false : days.contains(nextDay)
                // Single isolated miss gets half penalty; consecutive misses get full penalty
                dayValue = prevActive || nextActive ? gracePenalty : 0
            }
            ema = alpha * dayValue + (1 - alpha) * ema
            currentDay = addDays(1, to: currentDay, calendar)
        }

        return percent(ema)
    }

    private static func percent(_ ratio: Double) -> Int {
        Int((min(max(ratio, 0), 1) * 100).rounded())
    }

    /// Re-normalised to the start of day so days stay comparable across DST changes.
    private static func addDays(_ n: Int, to day: Date, _ calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: n, to: day)!)
    }
}
