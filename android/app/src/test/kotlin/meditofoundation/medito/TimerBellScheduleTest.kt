package meditofoundation.medito

import meditofoundation.medito.pigeon.BellCue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TimerBellScheduleTest {
    private val start = BellCue(0, "start", "assets/audio/session_bell_v2.wav")
    private val interval = BellCue(8000, "interval", "assets/audio/bells/g1-cuenco-tibetano.mp3")
    private val end = BellCue(16000, "end", "assets/audio/bells/p8-kalimba.mp3")
    private val none = emptyList<BellCue>()

    @Test fun ringsOnceWhenCrossingEachCue() {
        val schedule = TimerBellSchedule(listOf(start, interval, end))
        assertEquals(listOf(start), schedule.update(0, true))
        assertEquals(none, schedule.update(0, true))
        assertEquals(none, schedule.update(7999, true))
        assertEquals(listOf(interval), schedule.update(8001, true))
        assertEquals(none, schedule.update(8100, true))
        assertEquals(none, schedule.update(7999, true))
        assertEquals(none, schedule.update(8001, true))
        assertEquals(listOf(end), schedule.update(16000, true))
    }

    @Test fun mandatoryCuesRingHoweverLateOptionalOnlyUnderTwoSeconds() {
        val schedule = TimerBellSchedule(listOf(start, interval, end))
        // El inicio llega 2 s tarde: igual suena.
        assertEquals(listOf(start), schedule.update(2000, true))
        assertEquals(listOf(interval), schedule.update(9999, true))
        // El fin llega 2 s tarde: igual suena.
        assertEquals(listOf(end), schedule.update(18000, true))
        assertEquals(none, schedule.update(18001, true))
    }

    @Test fun lateOptionalCuesAreDroppedAtTwoSeconds() {
        for (kind in listOf("interval", "random", "spoken")) {
            val cue = BellCue(8000, kind, "x")
            val late = TimerBellSchedule(listOf(cue))
            assertEquals(none, late.update(10_000, true))
            val onTime = TimerBellSchedule(listOf(cue))
            assertEquals(listOf(cue), onTime.update(9_999, true))
        }
    }

    @Test fun stageCuesAreNeverDropped() {
        val stage = BellCue(60_000, "stage", "assets/audio/bells/g1-cuenco-tibetano.mp3")
        val schedule = TimerBellSchedule(listOf(stage))
        assertEquals(listOf(stage), schedule.update(600_000, true))
    }

    @Test fun oneStallReturnsEveryMandatoryCueOldestFirstPlusNewestFreshOptional() {
        val stage = BellCue(4000, "stage", "a")
        val oldInterval = BellCue(5000, "interval", "b")
        val endRepeat1 = BellCue(16000, "end", "c")
        val endRepeat2 = BellCue(18000, "end", "c")
        val freshInterval = BellCue(19000, "interval", "b")
        val schedule = TimerBellSchedule(listOf(start, stage, oldInterval, endRepeat1, endRepeat2, freshInterval))
        assertEquals(
            listOf(start, stage, endRepeat1, endRepeat2, freshInterval),
            schedule.update(20_000, true)
        )
    }

    @Test fun onlyTheNewestOptionalCueRings() {
        val a = BellCue(1000, "interval", "a")
        val b = BellCue(1500, "random", "b")
        val schedule = TimerBellSchedule(listOf(a, b))
        assertEquals(listOf(b), schedule.update(2000, true))
    }

    @Test fun seeksConsumeSkippedCuesAndRearmLaterCues() {
        val schedule = TimerBellSchedule(listOf(start, interval, end))
        schedule.seek(8000)
        assertEquals(none, schedule.update(8000, true))
        assertEquals(listOf(end), schedule.update(16001, true))
        schedule.seek(7999)
        assertEquals(none, schedule.update(7999, true))
        assertEquals(listOf(interval), schedule.update(8000, true))
        schedule.seek(0)
        assertEquals(none, schedule.update(100, true))
    }

    @Test fun mutedCuesAreConsumedWithoutResettingProgress() {
        val schedule = TimerBellSchedule(listOf(start, interval, end))
        assertEquals(none, schedule.update(0, false))
        assertEquals(none, schedule.update(1, true))
        assertEquals(none, schedule.update(8000, false))
        assertEquals(none, schedule.update(8001, true))
        assertEquals(listOf(end), schedule.update(16000, true))
        schedule.reset()
        assertEquals(listOf(start), schedule.update(0, true))
    }

    @Test fun emptyScheduleIsSilent() {
        val schedule = TimerBellSchedule(emptyList())
        assertTrue(schedule.update(0, true).isEmpty())
        assertTrue(schedule.update(7200000, true).isEmpty())
    }

    @Test fun returnsTypedEndCueAtTheProvidedLeadTime() {
        val end = BellCue(53500, "end", start.assetKey)
        val schedule = TimerBellSchedule(listOf(start, end))
        assertEquals(listOf(start), schedule.update(0, true))
        assertEquals(none, schedule.update(53499, true))
        assertEquals(listOf(end), schedule.update(53500, true))
    }
}
