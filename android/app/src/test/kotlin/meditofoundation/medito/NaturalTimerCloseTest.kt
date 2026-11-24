package meditofoundation.medito

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NaturalTimerCloseTest {
    @Test fun aSavedNaturalCloseIsDeliveredBeforeTheEndIsPublished() {
        assertTrue(NaturalTimerClose.deliverBeforeEnd(TimerCloseResult.SAVED))
    }

    @Test fun aFailedOrEmptyNaturalCloseIsNotDelivered() {
        // Fallido: queda en `active` para la recuperación; la pantalla no dice
        // «Guardamos tu sesión» porque el historial no lo confirma.
        assertFalse(NaturalTimerClose.deliverBeforeEnd(TimerCloseResult.FAILED))
        assertFalse(NaturalTimerClose.deliverBeforeEnd(TimerCloseResult.SHORT))
        assertFalse(NaturalTimerClose.deliverBeforeEnd(null))
    }
}
