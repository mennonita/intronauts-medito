package meditofoundation.medito

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TimerBellScheduleTest {
    @Test fun ringsOnceWhenCrossingEachCue() {
        val schedule = TimerBellSchedule(listOf(0, 8000, 16000))
        assertEquals(0L, schedule.update(0, true))
        assertNull(schedule.update(0, true))
        assertNull(schedule.update(7999, true))
        assertEquals(8000L, schedule.update(8001, true))
        assertNull(schedule.update(8100, true))
        assertNull(schedule.update(7999, true))
        assertNull(schedule.update(8001, true))
        assertEquals(16000L, schedule.update(16000, true))
    }

    @Test fun consumesCuesAtTwoSecondsLateButRingsAt1999Ms() {
        val schedule = TimerBellSchedule(listOf(0, 8000, 16000))
        assertNull(schedule.update(2000, true))
        assertEquals(8000L, schedule.update(9999, true))
        assertNull(schedule.update(18000, true))
        assertNull(schedule.update(18001, true))
    }

    @Test fun seeksConsumeSkippedCuesAndRearmLaterCues() {
        val schedule = TimerBellSchedule(listOf(0, 8000, 16000))
        schedule.seek(8000)
        assertNull(schedule.update(8000, true))
        assertEquals(16000L, schedule.update(16001, true))
        schedule.seek(7999)
        assertNull(schedule.update(7999, true))
        assertEquals(8000L, schedule.update(8000, true))
        schedule.seek(0)
        assertEquals(0L, schedule.update(100, true))
    }

    @Test fun mutedCuesAreConsumedWithoutResettingProgress() {
        val schedule = TimerBellSchedule(listOf(0, 8000, 16000))
        assertNull(schedule.update(0, false))
        assertNull(schedule.update(1, true))
        assertNull(schedule.update(8000, false))
        assertNull(schedule.update(8001, true))
        assertEquals(16000L, schedule.update(16000, true))
        schedule.reset()
        assertEquals(0L, schedule.update(0, true))
    }

    @Test fun emptyScheduleIsSilent() {
        val schedule = TimerBellSchedule(emptyList())
        assertNull(schedule.update(0, true))
        assertNull(schedule.update(7200000, true))
    }

    @Test fun playsAllThreeFiveHourStopwatchCues() {
        val schedule = TimerBellSchedule(listOf(0, 9000000, 17994000))
        assertEquals(0L, schedule.update(0, true))
        assertEquals(9000000L, schedule.update(9000000, true))
        assertEquals(17994000L, schedule.update(17994000, true))
        assertNull(schedule.update(18000000, true))
    }
}
