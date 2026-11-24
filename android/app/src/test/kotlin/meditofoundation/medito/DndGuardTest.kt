package meditofoundation.medito

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DndGuardTest {
    private val all = DndGuard.FILTER_ALL
    private val alarms = DndGuard.FILTER_ALARMS
    private val priority = 2 // NotificationManager.INTERRUPTION_FILTER_PRIORITY
    private val none = 3 // NotificationManager.INTERRUPTION_FILTER_NONE

    private class FakeZen(var access: Boolean = true, var zenFilter: Int = DndGuard.FILTER_ALL) : ZenBackend {
        val rules = mutableMapOf<String, Boolean>()
        var created = 0
        override fun hasAccess() = access
        override fun currentFilter() = zenFilter
        override fun setFilter(filter: Int) {
            zenFilter = filter
        }
        override fun ruleExists(id: String) = id in rules
        override fun createRule(name: String): String = "rule-${++created}".also { rules[it] = false }
        override fun setRuleActive(id: String, name: String, active: Boolean) {
            rules[id] = active
        }
    }

    private class MemoryStore : DndRecordStore {
        var record = DndRecord()
        override fun read() = record
        override fun write(record: DndRecord): Boolean {
            this.record = record
            return true
        }
    }

    // ---- API < 35: filtro global ----

    @Test fun legacyDoesNothingWhenTheUserAlreadyHasDnd() {
        val zen = FakeZen(zenFilter = priority)
        val store = MemoryStore()
        val guard = DndGuard(zen, store, sdkInt = 34)
        assertFalse(guard.apply("run-1", "Temporizador"))
        assertEquals(priority, zen.zenFilter)
        assertFalse(store.record.active)
        assertFalse(guard.restore())
        assertEquals(priority, zen.zenFilter)
    }

    @Test fun legacyRestoresAlarmsToAll() {
        val zen = FakeZen()
        val store = MemoryStore()
        val guard = DndGuard(zen, store, sdkInt = 34)
        assertTrue(guard.apply("run-1", null))
        assertEquals(alarms, zen.zenFilter)
        assertEquals("run-1", store.record.runId)
        assertTrue(guard.restore())
        assertEquals(all, zen.zenFilter)
        assertFalse(store.record.active)
    }

    @Test fun legacyLeavesAUserChangedFilterAloneAndClearsTheRecord() {
        val zen = FakeZen()
        val store = MemoryStore()
        val guard = DndGuard(zen, store, sdkInt = 34)
        guard.apply("run-1", null)
        zen.zenFilter = none
        assertFalse(guard.restore())
        assertEquals(none, zen.zenFilter)
        assertFalse(store.record.active)
    }

    @Test fun legacyNewSessionTakesOverOurFilter() {
        val zen = FakeZen()
        val store = MemoryStore()
        val guard = DndGuard(zen, store, sdkInt = 34)
        guard.apply("run-1", null)
        assertTrue(guard.apply("run-2", null))
        assertEquals("run-2", store.record.runId)
        assertEquals(all, store.record.previous)
    }

    // ---- API >= 35: regla propia ----

    @Test fun rulesApplyAndRestoreToggleOnlyOurRuleById() {
        val zen = FakeZen()
        val store = MemoryStore()
        zen.rules["user-rule"] = true
        val guard = DndGuard(zen, store, sdkInt = 35)
        assertTrue(guard.apply("run-1", "Temporizador de meditación"))
        val id = store.record.ruleId
        assertNotNull(id)
        assertEquals(true, zen.rules[id])
        assertEquals(all, zen.zenFilter)
        assertTrue(guard.restore())
        assertEquals(false, zen.rules[id])
        assertEquals(true, zen.rules["user-rule"])
        assertFalse(store.record.active)
        // La siguiente sesión reutiliza la misma regla.
        guard.apply("run-2", "Temporizador de meditación")
        assertEquals(id, store.record.ruleId)
        assertEquals(1, zen.created)
    }

    @Test fun rulesRestoreEvenWhenAStricterUserFilterIsActive() {
        val zen = FakeZen()
        val store = MemoryStore()
        val guard = DndGuard(zen, store, sdkInt = 36)
        guard.apply("run-1", "Regla")
        zen.zenFilter = none
        zen.rules["user-rule"] = true
        assertTrue(guard.restore())
        assertEquals(false, zen.rules[store.record.ruleId])
        assertEquals(none, zen.zenFilter)
    }

    @Test fun missingRuleIsCreatedAgain() {
        val zen = FakeZen()
        val store = MemoryStore()
        val guard = DndGuard(zen, store, sdkInt = 35)
        guard.apply("run-1", "Regla")
        guard.restore()
        zen.rules.clear()
        assertTrue(guard.apply("run-2", "Regla"))
        assertEquals(2, zen.created)
        assertEquals(true, zen.rules[store.record.ruleId])
    }

    @Test fun rulesWithoutANameDoNothing() {
        val zen = FakeZen()
        val guard = DndGuard(zen, MemoryStore(), sdkInt = 35)
        assertFalse(guard.apply("run-1", null))
        assertEquals(0, zen.created)
    }

    // ---- Ambos caminos ----

    @Test fun staleRecordIsRestoredWhenTheOwnerIsNotLive() {
        for (sdk in listOf(34, 35)) {
            val zen = FakeZen()
            val store = MemoryStore()
            val guard = DndGuard(zen, store, sdk)
            guard.apply("run-1", "Regla")
            // El dueño sigue vivo: no se toca.
            assertFalse(guard.restoreIfStale(setOf("run-1")))
            assertTrue(store.record.active)
            // Servicio inactivo (nadie vivo): se restaura.
            assertTrue(guard.restoreIfStale(emptySet()))
            assertFalse(store.record.active)
            if (sdk >= 35) assertEquals(false, zen.rules[store.record.ruleId]) else assertEquals(all, zen.zenFilter)
            // Sin registro activo no hay nada que hacer.
            assertFalse(guard.restoreIfStale(emptySet()))
        }
    }

    @Test fun staleRecordOfAnotherRunIsRestored() {
        val zen = FakeZen()
        val store = MemoryStore()
        val guard = DndGuard(zen, store, 34)
        guard.apply("run-old", null)
        assertTrue(guard.restoreIfStale(setOf("run-new")))
        assertEquals(all, zen.zenFilter)
        assertNull(store.record.runId)
    }

    @Test fun withoutAccessEverythingIsANoOp() {
        for (sdk in listOf(34, 35)) {
            val zen = FakeZen(access = false)
            val store = MemoryStore()
            val guard = DndGuard(zen, store, sdk)
            assertFalse(guard.apply("run-1", "Regla"))
            assertEquals(all, zen.zenFilter)
            assertEquals(0, zen.created)
            assertFalse(store.record.active)
            assertFalse(guard.restore())
        }
    }
}
