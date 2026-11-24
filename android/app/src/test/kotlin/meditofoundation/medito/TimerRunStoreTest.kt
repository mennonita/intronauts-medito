package meditofoundation.medito

import meditofoundation.medito.pigeon.CompletionData
import meditofoundation.medito.pigeon.TimerStopReport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TimerRunStoreTest {
    /** Como SharedPreferences: `commit()` cambia la memoria aunque el disco falle. */
    private class MemoryStorage : TimerRunStorage {
        var value: String? = null
        var disk: String? = null
        var commits = 0
        var failNext = false
        override fun read() = value
        override fun commit(value: String?): Boolean {
            this.value = value
            if (failNext) {
                failNext = false
                return false
            }
            commits++
            disk = value
            return true
        }

        /** Proceso nuevo: la memoria vuelve a lo que hay en disco. */
        fun reopen() {
            value = disk
        }
    }

    /** Igual que SharedPreferencesManager: generación + cuenta ligada; nunca exige verificación. */
    private class FakeGate : TimerRunGate {
        var generation = 1L
        var bound = true
        var verified = false
        override fun currentGeneration() = generation
        override fun <T> ifCurrent(generation: Long, block: () -> T): T? =
            synchronized(this) { if (generation == this.generation && bound) block() else null }

        fun bindAccount() {
            if (!bound) generation++
            bound = true
        }

        fun clearAccount(storage: MemoryStorage) {
            generation++
            bound = false
            storage.value = null
            storage.disk = null
        }
    }

    private val minute = 60_000L
    private var seq = 0L
    private fun nextSeq() = ++seq

    private fun run(id: String, prep: Long = 0, planned: Long = 20 * minute, position: Long = 0, owner: String = "user-1") =
        TimerActiveRun(
            runId = id, ownerId = owner, fileId = "timer-countdown-$planned", trackId = "timer-${planned / 1000}",
            guideId = null, startEpochMs = 1_000, prepMs = prep, plannedMs = planned, extraTime = false,
            isStopwatch = false, lastPositionMs = position, updatedAtMs = 5_000 + position, endPassed = false
        )

    private class Delivery {
        val sent = mutableListOf<CompletionData>()
        val replies = mutableListOf<(Boolean) -> Unit>()
        fun send(completion: CompletionData, reply: (Boolean) -> Unit) {
            sent.add(completion)
            replies.add(reply)
        }
    }

    @Test fun processDeathWithATwelveMinuteRunRecoversOneItem() {
        val storage = MemoryStorage()
        val gate = FakeGate()
        val store = TimerRunStore(storage, gate)
        assertTrue(store.start(run("a", prep = 10_000), gate.generation))
        assertTrue(store.update("a", 10_000 + 12 * minute, false, 99_000, gate.generation, nextSeq()))
        // El proceso murió: nadie vivo.
        assertTrue(store.recoverStale(null, gate.generation))
        val item = store.pending().single()
        assertEquals("a", item.runId)
        assertEquals(12 * minute, item.durationMs)
        assertEquals("timer-720", item.trackId)
        assertTrue(item.recovered)
        assertEquals(99_000L, item.timestamp)
        assertNull(store.active())
        assertFalse(store.recoverStale(null, gate.generation))
        assertEquals(1, store.pending().size)
    }

    @Test fun recoveryUnderSixtySecondsAddsNothing() {
        val storage = MemoryStorage()
        val gate = FakeGate()
        val store = TimerRunStore(storage, gate)
        store.start(run("a"), gate.generation)
        store.update("a", 59_999, false, 1, gate.generation, nextSeq())
        assertFalse(store.recoverStale(null, gate.generation))
        assertTrue(store.pending().isEmpty())
        assertNull(store.active())
    }

    @Test fun theLiveRunIsNeverRecovered() {
        val gate = FakeGate()
        val store = TimerRunStore(MemoryStorage(), gate)
        store.start(run("a", position = 5 * minute), gate.generation)
        assertFalse(store.recoverStale("a", gate.generation))
        assertEquals("a", store.active()?.runId)
    }

    @Test fun coldStartRecoversOnlyAfterTheAccountIsBoundAndDeliversOnce() {
        val storage = MemoryStorage()
        val gate = FakeGate()
        val store = TimerRunStore(storage, gate)
        store.start(run("a", position = 12 * minute), gate.generation)
        // Arranque en frío: la cuenta aún no está ligada.
        gate.bound = false
        val before = storage.value
        assertFalse(store.recoverStale(null, gate.generation))
        assertEquals(before, storage.value)
        val delivery = Delivery()
        store.deliverPending(send = delivery::send)
        assertTrue(delivery.sent.isEmpty())
        // `bind` → checkAndSendCompletionData: recupera una vez y entrega.
        gate.bindAccount()
        assertTrue(store.recoverStale(null, gate.generation))
        assertFalse(store.recoverStale(null, gate.generation))
        store.deliverPending(send = delivery::send)
        assertEquals(1, delivery.sent.size)
        assertEquals(true, delivery.sent.single().recovered)
        delivery.replies.single()(true)
        assertTrue(store.pending().isEmpty())
    }

    @Test fun aNewStartOverAStaleRunRecoversItInTheSameCommit() {
        val storage = MemoryStorage()
        val gate = FakeGate()
        val store = TimerRunStore(storage, gate)
        store.start(run("old"), gate.generation)
        store.update("old", 15 * minute, false, 7_000, gate.generation, nextSeq())
        val commits = storage.commits
        assertTrue(store.start(run("new"), gate.generation))
        assertEquals(commits + 1, storage.commits)
        assertEquals("new", store.active()?.runId)
        val item = store.pending().single()
        assertEquals("old", item.runId)
        assertTrue(item.recovered)
        assertEquals(15 * minute, item.durationMs)
    }

    @Test fun twentyFiveClosesWhileDeliveryFailsAreAllKeptAndLaterDeliveredInOrder() {
        val gate = FakeGate()
        val store = TimerRunStore(MemoryStorage(), gate)
        var clock = 0L
        val failing = Delivery()
        for (i in 1..25) {
            val id = "run-$i"
            store.start(run(id), gate.generation)
            assertEquals(TimerCloseResult.SAVED, store.finish(id, 2 * minute, "timer-120", i.toLong(), gate.generation))
            clock += 61_000 // cada intento viejo ya pasó su límite
            store.deliverPending(nowMs = { clock }, send = failing::send)
            failing.replies.last()(false)
        }
        assertEquals(25, store.pending().size)
        val ok = Delivery()
        store.deliverPending(nowMs = { clock }) { completion, reply ->
            ok.send(completion, reply)
            reply(true)
        }
        assertEquals((1..25).map { "run-$it" }, ok.sent.map { it.runId })
        assertTrue(store.pending().isEmpty())
    }

    @Test fun aWriteCapturedBeforeClearAccountIsSkipped() {
        val storage = MemoryStorage()
        val gate = FakeGate()
        val store = TimerRunStore(storage, gate)
        val captured = gate.generation
        gate.clearAccount(storage)
        gate.bindAccount()
        assertFalse(store.start(run("a"), captured))
        assertEquals(TimerCloseResult.FAILED, store.finish("a", 5 * minute, "timer-300", 1, captured, fallback = run("a")))
        assertFalse(store.update("a", 1, false, 1, captured, nextSeq()))
        assertNull(storage.disk)
        assertTrue(store.pending().isEmpty())
    }

    @Test fun timerItemsAreDeliveredWhileTheAccountIsNotVerified() {
        val gate = FakeGate().apply { verified = false }
        val store = TimerRunStore(MemoryStorage(), gate)
        store.start(run("a", owner = ""), gate.generation)
        store.finish("a", 3 * minute, "timer-180", 1, gate.generation)
        val delivery = Delivery()
        store.deliverPending(send = delivery::send)
        assertEquals("", delivery.sent.single().ownerId)
    }

    @Test fun twoFinishedRunsAreDeliveredInOrderEachRemovedOnlyAfterItsOwnTrue() {
        val gate = FakeGate().apply { verified = false }
        val store = TimerRunStore(MemoryStorage(), gate)
        for (id in listOf("first", "second")) {
            store.start(run(id), gate.generation)
            store.finish(id, 4 * minute, "timer-240", 1, gate.generation)
        }
        val delivery = Delivery()
        store.deliverPending(send = delivery::send)
        // Nunca dos entregas en vuelo.
        store.deliverPending(send = delivery::send)
        assertEquals(listOf("first"), delivery.sent.map { it.runId })
        assertEquals(2, store.pending().size)
        delivery.replies[0](true)
        assertEquals(listOf("second"), store.pending().map { it.runId })
        assertEquals(listOf("first", "second"), delivery.sent.map { it.runId })
        delivery.replies[1](true)
        assertTrue(store.pending().isEmpty())
    }

    @Test fun aFalseReplyKeepsTheItemAndStops() {
        val gate = FakeGate()
        val store = TimerRunStore(MemoryStorage(), gate)
        for (id in listOf("first", "second")) {
            store.start(run(id), gate.generation)
            store.finish(id, 4 * minute, "timer-240", 1, gate.generation)
        }
        val delivery = Delivery()
        store.deliverPending(send = delivery::send)
        delivery.replies[0](false)
        assertEquals(1, delivery.sent.size)
        assertEquals(listOf("first", "second"), store.pending().map { it.runId })
        // Siguiente intento (próximo regreso a la app): empieza otra vez por la primera.
        store.deliverPending(send = delivery::send)
        assertEquals("first", delivery.sent[1].runId)
    }

    @Test fun aDiscardNeverAddsAnItemAndAFailingDiscardReportsFailure() {
        val storage = MemoryStorage()
        val gate = FakeGate()
        val store = TimerRunStore(storage, gate)
        store.start(run("a", position = 10 * minute), gate.generation)
        storage.failNext = true
        assertFalse(store.discard("a", gate.generation))
        // El fallo no se toma como éxito: la sesión sigue y el reintento sí escribe (R101).
        assertEquals("a", store.active()?.runId)
        assertEquals("a", TimerRunStore(storage.also { it.reopen() }, gate).active()?.runId)
        assertTrue(store.discard("a", gate.generation))
        assertNull(store.active())
        storage.reopen()
        assertNull(TimerRunStore(storage, gate).active())
        assertTrue(store.pending().isEmpty())
        assertFalse(store.recoverStale(null, gate.generation))
        assertTrue(store.pending().isEmpty())
    }

    @Test fun naturalCompletionAndASaveStopOfTheSameRunGiveOneItem() {
        val gate = FakeGate()
        val store = TimerRunStore(MemoryStorage(), gate)
        val active = run("a", planned = 10 * minute)
        store.start(active, gate.generation)
        assertEquals(TimerCloseResult.SAVED, store.finish("a", 10 * minute, "timer-600", 1, gate.generation, fallback = active))
        assertEquals(TimerCloseResult.SAVED, store.finish("a", 10 * minute, "timer-600", 2, gate.generation, fallback = active))
        assertEquals(1, store.pending().size)
        assertEquals(1L, store.pending().single().timestamp)
    }

    @Test fun aSaveStopUnderSixtySecondsOnlyClearsTheActiveRun() {
        val gate = FakeGate()
        val store = TimerRunStore(MemoryStorage(), gate)
        store.start(run("a"), gate.generation)
        assertEquals(TimerCloseResult.SHORT, store.finish("a", 59_000, "timer-59", 1, gate.generation))
        assertNull(store.active())
        assertTrue(store.pending().isEmpty())
    }

    @Test fun completionAndStopReportCarryRunAndOwner() {
        val item = TimerFinishedRun("a", "user-9", "timer-600", "timer-countdown-600000", null, 600_000, 3, recovered = true)
        val completion = item.toCompletion()
        assertEquals("a", completion.runId)
        assertEquals("user-9", completion.ownerId)
        assertEquals(true, completion.recovered)
        assertEquals(600_000L, completion.duration)
        assertNull(completion.timerEnded)
        val report = TimerStopReport(1_000, false, true, true, "a")
        assertEquals("a", report.runId)
    }

    @Test fun theGuidedCompletionSlotLivesElsewhere() {
        // Los temporizadores usan su propio archivo; el lugar de las guiadas no cambia.
        assertNotEquals("MeditoAudioPrefs", TimerRunStore.PREFS_NAME)
        assertEquals("intronauts_timer_runs", TimerRunStore.PREFS_NAME)
    }

    @Test fun aFailedSaveIsReportedAsFailureAndNothingChanges() {
        val storage = MemoryStorage()
        val gate = FakeGate()
        val store = TimerRunStore(storage, gate)
        store.start(run("a", position = 10 * minute), gate.generation)
        storage.failNext = true
        assertEquals(TimerCloseResult.FAILED, store.finish("a", 10 * minute, "timer-600", 1, gate.generation))
        assertEquals("a", store.active()?.runId)
        assertTrue(store.pending().isEmpty())
        storage.reopen()
        assertTrue(TimerRunStore(storage, gate).pending().isEmpty())
        // Reintento con el tiempo final: ahora sí queda guardado.
        assertEquals(TimerCloseResult.SAVED, store.finish("a", 10 * minute, "timer-600", 2, gate.generation))
        assertEquals("a", store.pending().single().runId)
    }

    @Test fun aShortCloseIsConfirmedAndAFailedShortCloseIsAFailure() {
        val storage = MemoryStorage()
        val gate = FakeGate()
        val store = TimerRunStore(storage, gate)
        store.start(run("a"), gate.generation)
        storage.failNext = true
        assertEquals(TimerCloseResult.FAILED, store.finish("a", 30_000, "timer-30", 1, gate.generation))
        assertEquals(TimerCloseResult.SHORT, store.finish("a", 30_000, "timer-30", 1, gate.generation))
        assertNull(store.active())
    }

    @Test fun anOlderSnapshotNeverReplacesANewerOne() {
        val gate = FakeGate()
        val store = TimerRunStore(MemoryStorage(), gate)
        store.start(run("a"), gate.generation)
        val periodic = nextSeq() // foto periódica tomada antes de la pausa
        val pause = nextSeq()
        assertTrue(store.update("a", 60_100, false, 2, gate.generation, pause))
        assertFalse(store.update("a", 59_900, false, 1, gate.generation, periodic))
        assertEquals(60_100L, store.active()?.lastPositionMs)
        assertTrue(store.recoverStale(null, gate.generation))
        assertEquals(60_000L, store.pending().single().durationMs)
    }

    @Test fun aDiscardFromStopAudioThatFailsIsNeverRecovered() {
        val storage = MemoryStorage()
        val gate = FakeGate()
        val store = TimerRunStore(storage, gate)
        store.start(run("a", position = 10 * minute), gate.generation)
        storage.failNext = true
        assertFalse(store.discard("a", gate.generation, rememberOnFailure = true))
        assertFalse(store.recoverStale(null, gate.generation))
        assertTrue(store.pending().isEmpty())
        assertNull(store.active())
    }

    @Test fun aManualDiscardFailureDoesNotBlockALaterSave() {
        val storage = MemoryStorage()
        val gate = FakeGate()
        val store = TimerRunStore(storage, gate)
        store.start(run("a", position = 10 * minute), gate.generation)
        storage.failNext = true
        assertFalse(store.discard("a", gate.generation))
        assertEquals(TimerCloseResult.SAVED, store.finish("a", 10 * minute, "timer-600", 1, gate.generation))
    }
}
