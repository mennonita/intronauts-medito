package meditofoundation.medito.widget

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

object StreakCalculator {
    // Usa el mismo inicio de día que la app, incluso cuando cambia la hora local.
    fun dayOf(
        millis: Long,
        offsetHours: Int,
        zone: ZoneId = ZoneId.systemDefault(),
    ): LocalDate = Instant.ofEpochMilli(millis)
        .minusSeconds(offsetHours * 3600L)
        .atZone(zone)
        .toLocalDate()

    fun practiceDays(
        timestamps: List<Long>,
        offsetHours: Int,
        today: LocalDate,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Set<LocalDate> = timestamps
        .map { dayOf(it, offsetHours, zone) }
        .filter { !it.isAfter(today) }
        .toSet()
}
