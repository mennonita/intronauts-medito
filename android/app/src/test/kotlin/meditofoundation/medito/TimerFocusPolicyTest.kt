package meditofoundation.medito

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TimerFocusPolicyTest {
    private val none = listOf(FocusAction.None)

    @Test fun transientLossPausesAndGainResumes() {
        val policy = TimerFocusPolicy(mixWithOthers = false)
        assertEquals(listOf(FocusAction.Pause(resumeLater = true)), policy.onFocusChange(FocusChange.LOSS_TRANSIENT, true))
        assertTrue(policy.resumeLater)
        assertEquals(listOf(FocusAction.Resume), policy.onFocusChange(FocusChange.GAIN, false))
        assertFalse(policy.resumeLater)
        assertEquals(none, policy.onFocusChange(FocusChange.GAIN, true))
    }

    @Test fun transientLossWhilePausedDoesNotResumeLater() {
        val policy = TimerFocusPolicy(mixWithOthers = false)
        assertEquals(none, policy.onFocusChange(FocusChange.LOSS_TRANSIENT, false))
        assertEquals(none, policy.onFocusChange(FocusChange.GAIN, false))
    }

    @Test fun userPauseClearsResumeLater() {
        val policy = TimerFocusPolicy(mixWithOthers = false)
        policy.onFocusChange(FocusChange.LOSS_TRANSIENT, true)
        policy.onUserPause()
        assertEquals(none, policy.onFocusChange(FocusChange.GAIN, false))
    }

    @Test fun duckAndUnduck() {
        val policy = TimerFocusPolicy(mixWithOthers = false)
        assertEquals(listOf(FocusAction.Duck), policy.onFocusChange(FocusChange.LOSS_TRANSIENT_CAN_DUCK, true))
        assertEquals(none, policy.onFocusChange(FocusChange.LOSS_TRANSIENT_CAN_DUCK, true))
        assertEquals(listOf(FocusAction.Unduck), policy.onFocusChange(FocusChange.GAIN, true))
    }

    @Test fun permanentLossPausesWithoutResumeAndNotifies() {
        val policy = TimerFocusPolicy(mixWithOthers = false)
        assertEquals(
            listOf(FocusAction.Pause(resumeLater = false), FocusAction.NotifyOtherAudio),
            policy.onFocusChange(FocusChange.LOSS, true)
        )
        assertEquals(none, policy.onFocusChange(FocusChange.GAIN, false))
        assertEquals(none, policy.onFocusChange(FocusChange.LOSS, false))
    }

    @Test fun mixModeIgnoresFocusAndFollowsCalls() {
        val policy = TimerFocusPolicy(mixWithOthers = true)
        assertEquals(none, policy.onFocusChange(FocusChange.LOSS, true))
        assertEquals(none, policy.onFocusChange(FocusChange.LOSS_TRANSIENT, true))
        assertEquals(none, policy.onCallState(false, true))
        assertEquals(listOf(FocusAction.Pause(resumeLater = true)), policy.onCallState(true, true))
        assertEquals(none, policy.onCallState(true, false))
        assertEquals(listOf(FocusAction.Resume), policy.onCallState(false, false))
        assertEquals(none, policy.onCallState(false, true))
    }

    @Test fun mixModeCallWhilePausedOrUserPausedDoesNotResume() {
        val policy = TimerFocusPolicy(mixWithOthers = true)
        assertEquals(none, policy.onCallState(true, false))
        assertEquals(none, policy.onCallState(false, false))
        policy.onCallState(true, true)
        policy.onUserPause()
        assertEquals(none, policy.onCallState(false, false))
    }

    @Test fun defaultModeIgnoresTheAudioMode() {
        val policy = TimerFocusPolicy(mixWithOthers = false)
        assertEquals(none, policy.onCallState(true, true))
    }

    @Test fun callModesAndAndroidFocusCodes() {
        assertFalse(TimerFocusPolicy.isCallMode(0))
        assertTrue(TimerFocusPolicy.isCallMode(1))
        assertTrue(TimerFocusPolicy.isCallMode(2))
        assertTrue(TimerFocusPolicy.isCallMode(3))
        assertEquals(FocusChange.GAIN, TimerFocusPolicy.fromAndroid(1))
        assertEquals(FocusChange.LOSS, TimerFocusPolicy.fromAndroid(-1))
        assertEquals(FocusChange.LOSS_TRANSIENT, TimerFocusPolicy.fromAndroid(-2))
        assertEquals(FocusChange.LOSS_TRANSIENT_CAN_DUCK, TimerFocusPolicy.fromAndroid(-3))
    }

    @Test fun normalModeWaitsForFocusAndResumesOnGain() {
        val policy = TimerFocusPolicy(mixWithOthers = false)
        assertFalse(policy.onStartAttempt(callActive = false, focusGranted = false))
        assertEquals(listOf(FocusAction.Resume), policy.onFocusChange(FocusChange.GAIN, isPlaying = false))
        assertTrue(policy.onStartAttempt(callActive = false, focusGranted = true))
    }

    @Test fun mixModeChecksTheCallOnEveryStartAndResumesWhenItEnds() {
        val policy = TimerFocusPolicy(mixWithOthers = true)
        assertTrue(policy.onStartAttempt(callActive = false, focusGranted = false))
        // La persona reanuda durante la misma llamada: el reloj no corre.
        assertEquals(none, policy.onCallState(callActive = true, isPlaying = false))
        assertFalse(policy.onStartAttempt(callActive = true, focusGranted = false))
        assertEquals(none, policy.onCallState(callActive = true, isPlaying = false))
        assertEquals(listOf(FocusAction.Resume), policy.onCallState(callActive = false, isPlaying = false))
    }

    @Test fun aUserPauseWhileWaitingCancelsTheAutomaticStart() {
        val policy = TimerFocusPolicy(mixWithOthers = true)
        assertFalse(policy.onStartAttempt(callActive = true, focusGranted = false))
        policy.onUserPause()
        assertEquals(none, policy.onCallState(callActive = false, isPlaying = false))
    }
}
