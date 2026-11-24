package meditofoundation.medito.widget

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * Inicio de día con desfase en los dos cambios de horario de Nueva York (2026):
 * adelanto el 8 de marzo (02:00 → 03:00) y atraso el 1 de noviembre
 * (02:00 → 01:00). Mismos casos que test/utils/day_boundary_test.dart.
 */
class StreakCalculatorDayBoundaryTest {

    private val zone: ZoneId = ZoneId.of("America/New_York")

    private fun millis(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0): Long =
        LocalDateTime.of(year, month, day, hour, minute).atZone(zone).toInstant().toEpochMilli()

    @Test
    fun `adelanto - 04 30 con inicio a las 04 00 es de ese dia`() {
        assertEquals(LocalDate.of(2026, 3, 8), StreakCalculator.dayOf(millis(2026, 3, 8, 4, 30), 4, zone))
        assertEquals(LocalDate.of(2026, 3, 8), StreakCalculator.dayOf(millis(2026, 3, 8, 4), 4, zone))
        assertEquals(LocalDate.of(2026, 3, 7), StreakCalculator.dayOf(millis(2026, 3, 8, 3, 59), 4, zone))
    }

    @Test
    fun `atraso - 03 30 con inicio a las 04 00 es del dia anterior`() {
        assertEquals(LocalDate.of(2026, 10, 31), StreakCalculator.dayOf(millis(2026, 11, 1, 3, 30), 4, zone))
        assertEquals(LocalDate.of(2026, 11, 1), StreakCalculator.dayOf(millis(2026, 11, 1, 4), 4, zone))
    }

    @Test
    fun `desfase negativo en ambos cambios`() {
        assertEquals(LocalDate.of(2026, 3, 8), StreakCalculator.dayOf(millis(2026, 3, 7, 22), -2, zone))
        assertEquals(LocalDate.of(2026, 3, 7), StreakCalculator.dayOf(millis(2026, 3, 7, 21, 59), -2, zone))
        assertEquals(LocalDate.of(2026, 11, 1), StreakCalculator.dayOf(millis(2026, 10, 31, 22), -2, zone))
        assertEquals(LocalDate.of(2026, 10, 31), StreakCalculator.dayOf(millis(2026, 10, 31, 21, 59), -2, zone))
    }

    @Test
    fun `practiceDays agrupa igual en el adelanto`() {
        val today = StreakCalculator.dayOf(millis(2026, 3, 8, 12), 4, zone)
        val days = StreakCalculator.practiceDays(
            listOf(millis(2026, 3, 8, 4, 30), millis(2026, 3, 8, 3, 30)),
            4,
            today,
            zone,
        )
        assertEquals(setOf(LocalDate.of(2026, 3, 8), LocalDate.of(2026, 3, 7)), days)
    }

    @Test
    fun `el puntaje usa el mismo dia que la racha en el adelanto`() {
        // Una sola sesión a las 04:30 del día del adelanto cuenta para hoy: con
        // la resta de horas transcurridas caía en el día anterior.
        val today = LocalDate.of(2026, 3, 8)
        val withSession = ConsistencyScoreCalculator.calculate(
            listOf(millis(2026, 3, 8, 4, 30)),
            emptyList(),
            today = today,
            zone = zone,
            dayBoundaryOffsetHours = 4,
        )
        val sameDayReference = ConsistencyScoreCalculator.calculate(
            listOf(millis(2026, 3, 8, 12)),
            emptyList(),
            today = today,
            zone = zone,
            dayBoundaryOffsetHours = 4,
        )
        assertEquals(sameDayReference, withSession)
    }
}
