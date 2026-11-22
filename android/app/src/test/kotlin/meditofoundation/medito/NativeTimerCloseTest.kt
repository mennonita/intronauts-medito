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
}
