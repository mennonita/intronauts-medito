package meditofoundation.medito.widget

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

object StreakCalculator {
    // Usa el mismo inicio de día que la app (`dayOf` de Dart). El desfase se
    // resta a la hora de reloj local, no a las horas transcurridas: el día del
    // cambio de horario las 04:30 con inicio a las 04:00 siguen siendo de ese día.
    fun dayOf(
        millis: Long,
        offsetHours: Int,
        zone: ZoneId = ZoneId.systemDefault(),
    ): LocalDate = Instant.ofEpochMilli(millis)
        .atZone(zone)
        .toLocalDateTime()
        .minusHours(offsetHours.toLong())
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
