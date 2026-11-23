package meditofoundation.medito

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TimerStartGateTest {
    @Test fun systemPlayDuringPreloadWaitsAndStartsOnce() {
        val gate = TimerStartGate()
        var starts = 0
        gate.reset()
        gate.play { starts++ }
        gate.primaryReady()
        gate.play { starts++ }
        assertEquals(0, starts)
        gate.bellsReady()
        assertEquals(1, starts)
        gate.play { starts++ }
        assertEquals(2, starts)
    }

    @Test fun stopAndRetryDiscardPendingPlay() {
        val gate = TimerStartGate()
        var starts = 0
        gate.reset()
        gate.play { starts++ }
        gate.primaryReady()
        gate.cancel()
        gate.bellsReady()
        assertEquals(0, starts)

        gate.reset()
        gate.play { starts++ }
        gate.reset()
        gate.primaryReady()
        gate.bellsReady()
        assertEquals(0, starts)
    }

    @Test fun pauseClearsPendingPlayWithoutDroppingReadiness() {
        val gate = TimerStartGate()
        var starts = 0
        gate.reset()
        gate.play { starts++ }
        gate.pause()
        gate.primaryReady()
        gate.bellsReady()
        assertEquals(0, starts)
        gate.play { starts++ }
        assertEquals(1, starts)
    }

    @Test fun selectedFailureWaitsForFallbackReadyOrFailed() {
        for (fallbackWorks in listOf(true, false)) {
            val preload = TimerBellPreload(setOf("kalimba.mp3", "gong.mp3"), "current.wav")
            assertEquals("current.wav", preload.failed("kalimba.mp3"))
            assertNull(preload.failed("gong.mp3"))
            assertFalse(preload.settled)
            if (fallbackWorks) {
                preload.ready("current.wav")
            } else {
                assertNull(preload.failed("current.wav"))
            }
            assertTrue(preload.settled)
        }
    }

    @Test fun doesNotRetryTheFallbackWhenItWasAlreadySelected() {
        val preload = TimerBellPreload(setOf("kalimba.mp3", "current.wav"), "current.wav")
        assertNull(preload.failed("current.wav"))
        assertFalse(preload.settled)
        assertNull(preload.failed("kalimba.mp3"))
        assertTrue(preload.settled)
    }
}
