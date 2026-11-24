package meditofoundation.medito

import org.junit.Assert.*
import org.junit.Test

class SessionBellScheduleTest {
    @Test fun cuesFollowMediaTimeWithoutDuplicates() {
        val cues = SessionBellSchedule()
        assertFalse(cues.update(0, -1))
        assertTrue(cues.update(0, 600000))
        assertFalse(cues.update(0, 600000))
        assertTrue(cues.update(300000, 600000))
        assertFalse(cues.update(300000, 600000))
        assertFalse(cues.update(600000, 600000))
    }

    @Test fun seeksSkipMissedCuesAndRestartRearms() {
        val cues = SessionBellSchedule()
        assertFalse(cues.update(360000, 600000))
        cues.seek(240000, 600000)
        assertFalse(cues.update(240000, 600000))
        assertTrue(cues.update(300000, 600000))
        cues.seek(360000, 600000)
        assertFalse(cues.update(360000, 600000))
        cues.seek(0, 600000)
        assertTrue(cues.update(0, 600000))
        assertTrue(cues.update(300000, 600000))
    }

    @Test fun finalCueFinishesBeforeSessionAtDifferentSpeeds() {
        for (speed in listOf(0.5, 1.0, 2.0)) {
            val cues = SessionBellSchedule()
            cues.update(0, 600000, speed)
            cues.update(300000, 600000, speed)
            val cue = 600000 - (6000 * speed).toLong()
            assertFalse(cues.update(cue - 1, 600000, speed))
            assertTrue(cues.update(cue, 600000, speed))
            assertFalse(cues.update(cue + 1, 600000, speed))
            assertFalse(cues.update(600000, 600000, speed))
        }
    }

    @Test fun seekingPastFinalCueSkipsIt() {
        val cues = SessionBellSchedule()
        cues.seek(598000, 600000)
        assertFalse(cues.update(598000, 600000))
        cues.seek(590000, 600000)
        assertTrue(cues.update(594000, 600000))
    }

    // ---- Fila de campanas del temporizador: una campana nunca corta a otra ----

    /** Reproductor falso: cada campana suena hasta que la prueba la termina. */
    private class FakeBells : TimerBellRinger {
        val started = mutableListOf<meditofoundation.medito.pigeon.BellCue>()
        var playing: meditofoundation.medito.pigeon.BellCue? = null
        val instant = mutableSetOf<String>()
        override fun ring(cue: meditofoundation.medito.pigeon.BellCue): Boolean {
            assertNull("una campana cortó a otra", playing)
            started.add(cue)
            if (cue.kind in instant) return false
            playing = cue
            return true
        }
        fun finish(queue: TimerBellQueue) {
            playing = null
            queue.finished()
        }
    }

    private fun cue(offset: Long, kind: String) = meditofoundation.medito.pigeon.BellCue(offset, kind, "assets/audio/bells/campana.mp3")

    @Test fun oneUpdateCrossingTwoEndRepeatsRingsBothInFullOneAfterTheOther() {
        val bells = FakeBells()
        val queue = TimerBellQueue(bells)
        val end1 = cue(16_000, "end")
        val end2 = cue(31_500, "end")
        val schedule = TimerBellSchedule(listOf(end1, end2))
        queue.offer(schedule.update(40_000, true))
        assertEquals(listOf(end1), bells.started)
        assertTrue(queue.busy)
        bells.finish(queue)
        assertEquals(listOf(end1, end2), bells.started)
        bells.finish(queue)
        assertFalse(queue.busy)
    }

    @Test fun aCueDueWhileABellPlaysRingsAfterIt() {
        val bells = FakeBells()
        val queue = TimerBellQueue(bells)
        val stage = cue(60_000, "stage")
        val interval = cue(61_000, "interval")
        queue.offer(listOf(stage))
        queue.offer(listOf(interval))
        assertEquals(listOf(stage), bells.started)
        bells.finish(queue)
        assertEquals(listOf(stage, interval), bells.started)
    }

    @Test fun eachKindGoesThroughTheQueue() {
        for (kind in listOf("start", "end", "stage", "interval", "random", "spoken")) {
            val bells = FakeBells().apply { instant.add("spoken") }
            val queue = TimerBellQueue(bells)
            val first = cue(0, "start")
            val next = cue(1_000, kind)
            queue.offer(listOf(first, next))
            assertEquals(listOf(first), bells.started)
            bells.finish(queue)
            assertEquals(listOf(first, next), bells.started)
            if (kind == "spoken") assertFalse(queue.busy) else assertTrue(queue.busy)
        }
    }

    @Test fun clearingTheQueueDropsWaitingBells() {
        val bells = FakeBells()
        val queue = TimerBellQueue(bells)
        queue.offer(listOf(cue(0, "end"), cue(1, "end")))
        queue.clear()
        bells.playing = null
        assertFalse(queue.busy)
        queue.finished()
        assertEquals(1, bells.started.size)
    }

    @Test fun completionWaitsWhileABellIsDueOrPlayingAndGivesUpAfterSixtySeconds() {
        val drain = TimerBellDrain()
        drain.begin(1_000)
        assertTrue(drain.ready(1_000, busy = false))
        assertFalse(drain.ready(1_000, busy = true))
        assertFalse(drain.ready(60_999, busy = true))
        assertTrue(drain.ready(61_000, busy = true))
    }

    @Test fun completionRunsAsSoonAsTheQueueEmpties() {
        val bells = FakeBells()
        val queue = TimerBellQueue(bells)
        val drain = TimerBellDrain().apply { begin(0) }
        queue.offer(listOf(cue(0, "end"), cue(15_500, "end")))
        assertFalse(drain.ready(20_000, queue.busy))
        bells.finish(queue)
        assertFalse(drain.ready(30_000, queue.busy))
        bells.finish(queue)
        assertTrue(drain.ready(31_000, queue.busy))
    }
}
