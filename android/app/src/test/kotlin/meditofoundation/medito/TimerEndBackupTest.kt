package meditofoundation.medito

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TimerEndBackupTest {
    private class FakeAlarm(var exact: Boolean = true) : AlarmBackend {
        var scheduledAt: Long? = null
        var wasExact: Boolean? = null
        var lastRequest: TimerBackupRequest? = null
        var cancels = 0
        override fun canScheduleExact() = exact
        override fun setExact(triggerAtElapsedMs: Long, request: TimerBackupRequest) {
            scheduledAt = triggerAtElapsedMs
            wasExact = true
            lastRequest = request
        }
        override fun setInexact(triggerAtElapsedMs: Long, request: TimerBackupRequest) {
            scheduledAt = triggerAtElapsedMs
            wasExact = false
            lastRequest = request
        }
        override fun cancel() {
            cancels++
            scheduledAt = null
        }
    }

    /** Reloj falso: el reloj de pared puede saltar; el de arranque no. */
    private class FakeClocks : ElapsedClock {
        var elapsed = 50_000L
        var wall = 1_700_000_000_000L
        override fun elapsedRealtime() = elapsed
    }

    private val request = TimerBackupRequest("run-1", "Terminó tu meditación", "Se cumplieron tus 10 min.", "sound", "Fin", "Fin (vibración)")
    private val prep = 30_000L
    private val planned = 600_000L

    private fun countdown(scheduler: TimerEndBackupScheduler, position: Long, endPassed: Boolean = false, extra: Boolean = false, stopwatch: Boolean = false) =
        scheduler.schedule(request, prep, planned, extra, stopwatch, position, endPassed)

    @Test fun schedulesOnStartAtElapsedRealtimePlusRemainingPlusTenSeconds() {
        val alarm = FakeAlarm()
        val clocks = FakeClocks()
        val scheduler = TimerEndBackupScheduler(alarm, clocks)
        assertEquals(50_000L + prep + planned + 10_000L, countdown(scheduler, 0))
        assertEquals(true, alarm.wasExact)
        assertEquals("run-1", alarm.lastRequest?.runId)
    }

    @Test fun resumeSchedulesFromTheRemainingTimeIncludingPreparation() {
        val alarm = FakeAlarm()
        val clocks = FakeClocks()
        val scheduler = TimerEndBackupScheduler(alarm, clocks)
        clocks.elapsed = 900_000L
        assertEquals(900_000L + (prep + planned - 200_000L) + 10_000L, countdown(scheduler, 200_000))
    }

    @Test fun withoutExactPermissionUsesTheInexactAlarm() {
        val alarm = FakeAlarm(exact = false)
        val scheduler = TimerEndBackupScheduler(alarm, FakeClocks())
        countdown(scheduler, 0)
        assertEquals(false, alarm.wasExact)
    }

    @Test fun aWallClockJumpDoesNotMoveTheTrigger() {
        val alarm = FakeAlarm()
        val clocks = FakeClocks()
        val scheduler = TimerEndBackupScheduler(alarm, clocks)
        val before = countdown(scheduler, 100_000)
        clocks.wall += 3_600_000L // la persona cambió la hora del teléfono
        val after = countdown(scheduler, 100_000)
        assertEquals(before, after)
    }

    @Test fun stopwatchSchedulesNothing() {
        val alarm = FakeAlarm()
        val scheduler = TimerEndBackupScheduler(alarm, FakeClocks())
        assertNull(countdown(scheduler, 0, stopwatch = true))
        assertNull(alarm.scheduledAt)
    }

    @Test fun extraTimeSchedulesUntilThePlannedEndLikeAPlainCountdown() {
        val alarm = FakeAlarm()
        val clocks = FakeClocks()
        val scheduler = TimerEndBackupScheduler(alarm, clocks)
        // Antes del fin planeado: mismo aviso que la cuenta regresiva simple (R105).
        assertEquals(50_000L + prep + planned + 10_000L, countdown(scheduler, 0, extra = true))
        assertEquals(countdown(scheduler, 0), countdown(scheduler, 0, extra = true))
        assertEquals(50_000L + 1_000L + 10_000L, countdown(scheduler, prep + planned - 1_000, extra = true))
    }

    @Test fun resumeInExtraTimeSchedulesNothingWithTheEndBellOnAndOff() {
        val alarm = FakeAlarm()
        val scheduler = TimerEndBackupScheduler(alarm, FakeClocks())
        // Justo en el fin planeado o después: ya no hay aviso pendiente.
        assertNull(countdown(scheduler, prep + planned, extra = true))
        // Campana final encendida: endPassed se puso cuando empezó a sonar.
        assertNull(countdown(scheduler, prep + planned + 30_000, endPassed = true, extra = true))
        // Campana final apagada: endPassed se puso al llegar la posición.
        assertNull(countdown(scheduler, prep + planned + 30_000, endPassed = true, extra = true))
        // Aunque fuera cuenta regresiva simple, después del final nunca se reprograma (R79).
        assertNull(countdown(scheduler, prep + planned - 5_000, endPassed = true))
        assertNull(countdown(scheduler, prep + planned))
        assertNull(alarm.scheduledAt)
    }

    @Test fun cancelOnEndCuePauseStopAndCompletion() {
        val alarm = FakeAlarm()
        val scheduler = TimerEndBackupScheduler(alarm, FakeClocks())
        for (event in listOf("end cue", "pause", "stop", "completion")) {
            countdown(scheduler, 0)
            assertTrue(event, alarm.scheduledAt != null)
            scheduler.cancel()
            assertNull(event, alarm.scheduledAt)
        }
        assertEquals(4, alarm.cancels)
    }

    @Test fun receiverSkipsAnEndedOrDifferentRun() {
        assertEquals(
            TimerBackupAction.IGNORE,
            TimerEndBackupDecision.decide("run-1", false, null, "run-1", storedEnded = true, canNotify = true)
        )
        assertEquals(
            TimerBackupAction.IGNORE,
            TimerEndBackupDecision.decide("run-1", false, null, "run-2", storedEnded = false, canNotify = true)
        )
        assertEquals(
            TimerBackupAction.POST,
            TimerEndBackupDecision.decide("run-1", false, null, "run-1", storedEnded = false, canNotify = true)
        )
    }

    @Test fun receiverWhileTheSameRunIsAlivePostsNothingAndDoesNotRestoreDnd() {
        val action = TimerEndBackupDecision.decide("run-1", true, "run-1", "run-1", storedEnded = false, canNotify = true)
        assertEquals(TimerBackupAction.RESCHEDULE_LIVE, action)
        // Servicio vivo con otra sesión: la de la alarma está muerta y se avisa.
        assertEquals(
            TimerBackupAction.POST,
            TimerEndBackupDecision.decide("run-1", true, "run-2", "run-1", storedEnded = false, canNotify = true)
        )
    }

    @Test fun withoutNotificationPermissionOnlyRestoresDnd() {
        assertEquals(
            TimerBackupAction.RESTORE_ONLY,
            TimerEndBackupDecision.decide("run-1", false, null, "run-1", storedEnded = false, canNotify = false)
        )
        assertTrue(TimerEndBackupDecision.shouldRestoreDnd("run-1", "run-1"))
        assertFalse(TimerEndBackupDecision.shouldRestoreDnd("run-2", "run-1"))
        assertFalse(TimerEndBackupDecision.shouldRestoreDnd(null, "run-1"))
    }

    @Test fun eachOutputHasItsOwnChannel() {
        assertEquals(TimerEndBackup.SILENT_CHANNEL_ID, TimerEndBackupDecision.channelId("vibration"))
        assertEquals(TimerEndBackup.CHANNEL_ID, TimerEndBackupDecision.channelId("sound"))
        assertEquals(TimerEndBackup.SOUND_VIBRATION_CHANNEL_ID, TimerEndBackupDecision.channelId("soundAndVibration"))
        assertEquals(TimerEndBackup.CHANNEL_ID, TimerEndBackupDecision.channelId(null))
        assertFalse(TimerEndBackupDecision.vibrates("sound"))
        assertTrue(TimerEndBackupDecision.vibrates("vibration"))
        assertTrue(TimerEndBackupDecision.vibrates("soundAndVibration"))
    }

    // ---- REV-08: borrar o cambiar de cuenta invalida la alarma ----

    private class MemoryRunState : TimerRunStateStorage {
        var runId: String? = null
        var ended = true
        var failClear = false
        override fun runId() = runId
        override fun ended() = ended
        override fun write(runId: String?, ended: Boolean): Boolean {
            this.runId = runId
            this.ended = ended
            return true
        }
        override fun clear(): Boolean {
            if (failClear) return false
            runId = null
            ended = true
            return true
        }
    }

    @Test fun anInvalidatedRunNeverPostsAfterTheAccountChanged() {
        val storage = MemoryRunState()
        val state = TimerRunState(storage)
        state.write("run-1", ended = false)
        val (beforeId, beforeEnded) = state.read()
        assertEquals(
            TimerBackupAction.POST,
            TimerEndBackupDecision.decide("run-1", false, null, beforeId, beforeEnded, canNotify = true)
        )

        assertTrue(state.invalidate())
        val (storedId, storedEnded) = state.read()
        assertNull(storedId)
        assertTrue(storedEnded)
        // El proceso anterior murió: la alarma de la cuenta vieja ya no avisa ni restaura.
        assertEquals(
            TimerBackupAction.IGNORE,
            TimerEndBackupDecision.decide("run-1", false, null, storedId, storedEnded, canNotify = true)
        )
        assertEquals(
            TimerBackupAction.IGNORE,
            TimerEndBackupDecision.decide("run-1", false, null, storedId, storedEnded, canNotify = false)
        )
        // Marcar terminada la sesión vieja no la revive.
        assertTrue(state.markEnded("run-1"))
        assertNull(state.read().first)
    }

    @Test fun aFailedInvalidationIsReported() {
        val storage = MemoryRunState()
        val state = TimerRunState(storage)
        state.write("run-1", ended = false)
        storage.failClear = true
        assertFalse(state.invalidate())
        assertEquals("run-1", state.read().first)
    }
}
