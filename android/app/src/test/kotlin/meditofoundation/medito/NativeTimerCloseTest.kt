package meditofoundation.medito

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeTimerCloseTest {
    @Test fun roundTripsTheStopPositionStatsIdentityAndEvent() {
        val completion = NativeCompletionRecord.timerClose("timer-countdown-60000", 98_742, 123_456)
        val recovered = NativeCompletionRecord.decode(NativeCompletionRecord.encode(completion))

        assertEquals(completion, recovered)
        assertEquals("timer-98", recovered.trackId)
        assertEquals(98_000L, recovered.duration)
        assertEquals(123_456L, recovered.timestamp)
        assertEquals(98_742L, recovered.timerEnded!!.positionMs)
        assertEquals("countdown", recovered.timerEnded.mode)
        assertEquals(98L, recovered.timerEnded.elapsedSeconds)
        assertTrue(recovered.timerEnded.recorded)
    }

    @Test fun preservesShortStopwatchEventsAndTheRecordingThreshold() {
        val short = NativeCompletionRecord.timerClose("timer-stopwatch-0", 59_999, 1)
        val recovered = NativeCompletionRecord.decode(NativeCompletionRecord.encode(short))
        assertEquals("stopwatch", recovered.timerEnded!!.mode)
        assertEquals(59L, recovered.timerEnded.elapsedSeconds)
        assertFalse(recovered.timerEnded.recorded)

        val atThreshold = NativeCompletionRecord.timerClose("timer-stopwatch-0", 60_000, 2)
        assertTrue(atThreshold.timerEnded!!.recorded)
    }

    @Test fun stillReadsOlderTrackCompletions() {
        val old = """{"trackId":"track","fileId":"file","duration":123000,"timestamp":42}"""
        val record = NativeCompletionRecord.decode(old)
        assertEquals("track", record.trackId)
        assertEquals(123_000L, record.duration)
        assertNull(record.timerEnded)
    }

    @Test fun closeUsesTheElapsedRuleWithoutPreparationAndCaps() {
        // Cuenta regresiva de 10 min con 30 s de preparación: la preparación no cuenta
        // y el tiempo se corta en lo planeado aunque el archivo siga (cola final).
        val countdown = NativeCompletionRecord.timerClose(
            "timer-countdown-600000", 30_000 + 700_000, 1,
            prepMs = 30_000, plannedMs = 600_000, isCountdownWithoutExtra = true
        )
        assertEquals("timer-600", countdown.trackId)
        assertEquals(600_000L, countdown.duration)

        val inPrep = NativeCompletionRecord.timerClose(
            "timer-countdown-600000", 20_000, 1,
            prepMs = 30_000, plannedMs = 600_000, isCountdownWithoutExtra = true
        )
        assertEquals(0L, inPrep.duration)
        assertFalse(inPrep.timerEnded!!.recorded)

        // Tiempo extra: cuenta pasado lo planeado.
        val extra = NativeCompletionRecord.timerClose(
            "timer-countdown-600000", 30_000 + 900_000, 1,
            prepMs = 30_000, plannedMs = 600_000, isCountdownWithoutExtra = false
        )
        assertEquals(900_000L, extra.duration)

        // Cronómetro: la cola final después de 5 h nunca cuenta.
        val stopwatch = NativeCompletionRecord.timerClose(
            "timer-stopwatch-0", 10_000 + TimerElapsed.STOPWATCH_CAP_MS + 20_000, 1,
            prepMs = 10_000, plannedMs = TimerElapsed.STOPWATCH_CAP_MS, isCountdownWithoutExtra = false
        )
        assertEquals(TimerElapsed.STOPWATCH_CAP_MS, stopwatch.duration)
    }

    @Test fun elapsedRuleMatchesTheDartTimeline() {
        val planned = 600_000L
        assertEquals(0L, TimerElapsed.elapsedMs(5_000, 10_000, planned, false, false))
        assertEquals(planned, TimerElapsed.elapsedMs(10_000 + planned + 3_000, 10_000, planned, false, false))
        assertEquals(planned + 3_000, TimerElapsed.elapsedMs(10_000 + planned + 3_000, 10_000, planned, true, false))
        assertEquals(
            planned + TimerElapsed.STOPWATCH_CAP_MS,
            TimerElapsed.elapsedMs(planned + TimerElapsed.STOPWATCH_CAP_MS + 99_000, 0, planned, true, false)
        )
        assertEquals(
            TimerElapsed.STOPWATCH_CAP_MS,
            TimerElapsed.elapsedMs(TimerElapsed.STOPWATCH_CAP_MS + 9_000, 0, TimerElapsed.STOPWATCH_CAP_MS, false, true)
        )
        assertEquals("timer-61", TimerElapsed.trackId(61_999))
    }
}
