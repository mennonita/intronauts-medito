package meditofoundation.medito.widget

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

class ReturnsCalculatorTest {
    @Test
    fun `counts distinct practice days using the selected boundary`() {
        val timestamps = listOf(
            "2026-11-15T12:00:00Z",
            "2026-11-18T23:00:00Z",
            "2026-11-19T02:00:00Z",
            "2026-11-22T12:00:00Z",
        ).map { Instant.parse(it).toEpochMilli() }
        val today = LocalDate.parse("2026-11-21")

        assertEquals(
            setOf(LocalDate.parse("2026-11-15"), LocalDate.parse("2026-11-18")),
            StreakCalculator.practiceDays(timestamps, 4, today, ZoneOffset.UTC),
        )
        assertEquals(3, StreakCalculator.practiceDays(timestamps, 0, today, ZoneOffset.UTC).size)
    }
}
