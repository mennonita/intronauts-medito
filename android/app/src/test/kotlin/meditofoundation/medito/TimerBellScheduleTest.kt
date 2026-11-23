package meditofoundation.medito

import meditofoundation.medito.pigeon.BellCue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TimerBellScheduleTest {
    private val start = BellCue(0, "start", "assets/audio/session_bell_v2.wav")
    private val interval = BellCue(8000, "interval", "assets/audio/bells/g1-cuenco-tibetano.mp3")
    private val end = BellCue(16000, "end", "assets/audio/bells/p8-kalimba.mp3")
    @Test fun ringsOnceWhenCrossingEachCue() {
        val schedule = TimerBellSchedule(listOf(start, interval, end))
        assertEquals(start, schedule.update(0, true))
        assertNull(schedule.update(0, true))
        assertNull(schedule.update(7999, true))
        assertEquals(interval, schedule.update(8001, true))
        assertNull(schedule.update(8100, true))
        assertNull(schedule.update(7999, true))
        assertNull(schedule.update(8001, true))
        assertEquals(end, schedule.update(16000, true))
    }

    @Test fun consumesCuesAtTwoSecondsLateButRingsAt1999Ms() {
        val schedule = TimerBellSchedule(listOf(start, interval, end))
        assertNull(schedule.update(2000, true))
        assertEquals(interval, schedule.update(9999, true))
        assertNull(schedule.update(18000, true))
        assertNull(schedule.update(18001, true))
    }

    @Test fun seeksConsumeSkippedCuesAndRearmLaterCues() {
        val schedule = TimerBellSchedule(listOf(start, interval, end))
        schedule.seek(8000)
        assertNull(schedule.update(8000, true))
        assertEquals(end, schedule.update(16001, true))
        schedule.seek(7999)
        assertNull(schedule.update(7999, true))
        assertEquals(interval, schedule.update(8000, true))
        schedule.seek(0)
        assertNull(schedule.update(100, true))
    }

    @Test fun mutedCuesAreConsumedWithoutResettingProgress() {
        val schedule = TimerBellSchedule(listOf(start, interval, end))
        assertNull(schedule.update(0, false))
        assertNull(schedule.update(1, true))
        assertNull(schedule.update(8000, false))
        assertNull(schedule.update(8001, true))
        assertEquals(end, schedule.update(16000, true))
        schedule.reset()
        assertEquals(start, schedule.update(0, true))
    }

    @Test fun emptyScheduleIsSilent() {
        val schedule = TimerBellSchedule(emptyList())
        assertNull(schedule.update(0, true))
        assertNull(schedule.update(7200000, true))
    }

    @Test fun returnsTypedEndCueAtTheProvidedLeadTime() {
        val end = BellCue(53500, "end", start.assetKey)
        val schedule = TimerBellSchedule(listOf(start, end))
        assertEquals(start, schedule.update(0, true))
        assertNull(schedule.update(53499, true))
        assertEquals(end, schedule.update(53500, true))
    }
}
