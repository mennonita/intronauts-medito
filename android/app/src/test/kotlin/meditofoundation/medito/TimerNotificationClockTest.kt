package meditofoundation.medito

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TimerNotificationClockTest {
    private val now = 1_000_000L
    private val prep = 30_000L
    private val planned = 600_000L

    private fun clock(position: Long, playing: Boolean = true, extra: Boolean = false, stopwatch: Boolean = false) =
        TimerNotificationClock.clock(now, position, playing, prep, planned, extra, stopwatch)

    @Test fun prepCountsDownToTheSessionStart() {
        val c = clock(10_000)
        assertTrue(c.usesChronometer)
        assertTrue(c.countDown)
        assertEquals(now + 20_000, c.whenMs)
        assertEquals(TimerClock.Kind.PREP, c.subText)
    }

    @Test fun countdownShowsWhatIsLeft() {
        val c = clock(prep + 100_000)
        assertTrue(c.usesChronometer)
        assertTrue(c.countDown)
        assertEquals(now + 500_000, c.whenMs)
        assertNull(c.subText)
    }

    @Test fun plainCountdownStopsTheChronometerAtTheEnd() {
        val c = clock(prep + planned + 1_000)
        assertFalse(c.usesChronometer)
    }

    @Test fun extraTimeCountsUpFromThePlannedEnd() {
        val c = clock(prep + planned + 45_000, extra = true)
        assertTrue(c.usesChronometer)
        assertFalse(c.countDown)
        assertEquals(now - 45_000, c.whenMs)
        assertEquals(TimerClock.Kind.EXTRA_TIME, c.subText)
        // Antes del final, el tiempo extra es una cuenta regresiva normal.
        assertTrue(clock(prep + 1_000, extra = true).countDown)
    }

    @Test fun stopwatchCountsUpWithoutPreparation() {
        val c = clock(prep + 70_000, stopwatch = true)
        assertTrue(c.usesChronometer)
        assertFalse(c.countDown)
        assertEquals(now - 70_000, c.whenMs)
        assertNull(c.subText)
        assertFalse(clock(prep + TimerElapsed.STOPWATCH_CAP_MS + 1, stopwatch = true).usesChronometer)
    }

    @Test fun pausedHasNoChronometer() {
        for (position in listOf(1_000L, prep + 1_000, prep + planned + 1_000)) {
            val c = clock(position, playing = false, extra = true)
            assertFalse(c.usesChronometer)
            assertNull(c.subText)
        }
    }

    @Test fun phasesChangeAtPrepEndAndPlannedEnd() {
        assertEquals(0, TimerNotificationClock.phase(prep - 1, prep, planned))
        assertEquals(1, TimerNotificationClock.phase(prep, prep, planned))
        assertEquals(1, TimerNotificationClock.phase(prep + planned - 1, prep, planned))
        assertEquals(2, TimerNotificationClock.phase(prep + planned, prep, planned))
    }
}
