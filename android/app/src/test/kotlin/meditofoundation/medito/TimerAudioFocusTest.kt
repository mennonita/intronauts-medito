package meditofoundation.medito

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class TimerAudioFocusTest {
    private class Request(val kind: FocusKind)

    private class FakeBackend(var grant: Boolean = true) : FocusBackend<Request> {
        val built = mutableListOf<Request>()
        val requested = mutableListOf<Request>()
        val abandoned = mutableListOf<Request>()
        override fun build(kind: FocusKind) = Request(kind).also { built.add(it) }
        override fun request(request: Request): Boolean {
            requested.add(request)
            return grant
        }
        override fun abandon(request: Request) {
            abandoned.add(request)
        }
    }

    @Test fun abandonReleasesTheSameObjectThatWasRequested() {
        val backend = FakeBackend()
        val focus = TimerAudioFocus(backend)
        assertTrue(focus.ensure(FocusKind.TIMER, mixWithOthers = false))
        focus.abandon()
        assertEquals(1, backend.abandoned.size)
        assertSame(backend.requested.single(), backend.abandoned.single())
        assertFalse(focus.isHeld)
        focus.abandon()
        assertEquals(1, backend.abandoned.size)
    }

    @Test fun guidedToTimerWithMixAbandonsGuidedAndRequestsNothing() {
        val backend = FakeBackend()
        val focus = TimerAudioFocus(backend)
        focus.ensure(FocusKind.GUIDED, mixWithOthers = false)
        val guided = backend.requested.single()
        assertFalse(focus.ensure(FocusKind.TIMER, mixWithOthers = true))
        assertSame(guided, backend.abandoned.single())
        assertEquals(1, backend.requested.size)
        assertEquals(1, backend.built.size)
        assertFalse(focus.isHeld)
    }

    @Test fun repeatedEnsureWithTheSameModeRequestsOnce() {
        val backend = FakeBackend()
        val focus = TimerAudioFocus(backend)
        repeat(3) { focus.ensure(FocusKind.TIMER, mixWithOthers = false) }
        assertEquals(1, backend.requested.size)
        assertEquals(1, backend.built.size)
    }

    @Test fun changingKindAbandonsFirst() {
        val backend = FakeBackend()
        val focus = TimerAudioFocus(backend)
        focus.ensure(FocusKind.GUIDED, false)
        focus.ensure(FocusKind.TIMER, false)
        assertEquals(FocusKind.GUIDED, backend.abandoned.single().kind)
        assertEquals(FocusKind.TIMER, backend.requested.last().kind)
    }

    @Test fun deniedOrLostFocusIsRequestedAgainWithTheSameObject() {
        val backend = FakeBackend(grant = false)
        val focus = TimerAudioFocus(backend)
        assertFalse(focus.ensure(FocusKind.TIMER, false))
        backend.grant = true
        assertTrue(focus.ensure(FocusKind.TIMER, false))
        assertEquals(1, backend.built.size)
        assertSame(backend.requested[0], backend.requested[1])
        focus.onFocusChange(gained = false)
        focus.ensure(FocusKind.TIMER, false)
        assertEquals(3, backend.requested.size)
        assertEquals(1, backend.built.size)
    }
}
