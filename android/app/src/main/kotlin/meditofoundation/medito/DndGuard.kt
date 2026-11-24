package meditofoundation.medito

import android.app.AutomaticZenRule
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.service.notification.Condition
import android.util.Log

/** Acceso a «No molestar» (NotificationManager real o uno falso en pruebas). */
internal interface ZenBackend {
    fun hasAccess(): Boolean
    fun currentFilter(): Int
    fun setFilter(filter: Int)
    fun ruleExists(id: String): Boolean
    /** Crea la regla propia y devuelve su id, o null si no se pudo. */
    fun createRule(name: String): String?
    fun setRuleActive(id: String, name: String, active: Boolean)
}

/** Registro de lo que hizo la app, para deshacerlo aunque el proceso muera. */
internal data class DndRecord(
    val active: Boolean = false,
    val previous: Int = FILTER_UNKNOWN,
    val applied: Int = FILTER_UNKNOWN,
    val runId: String? = null,
    val ruleId: String? = null,
    val ruleName: String? = null
) {
    companion object {
        const val FILTER_UNKNOWN = 0 // NotificationManager.INTERRUPTION_FILTER_UNKNOWN
    }
}

internal interface DndRecordStore {
    fun read(): DndRecord
    fun write(record: DndRecord): Boolean
}

/**
 * Pone y quita «No molestar» durante una sesión y siempre lo deja como estaba (§4.5).
 * Android 15+ (API 35) combina reglas: la app tiene UNA regla automática propia y
 * sólo la enciende o apaga por su id. Antes de 35 se usa el filtro global y sólo
 * se restaura si la persona no lo cambió mientras tanto.
 */
internal class DndGuard(
    private val backend: ZenBackend,
    private val store: DndRecordStore,
    private val sdkInt: Int
) {
    companion object {
        private const val TAG = "DndGuard"
        const val PREFS_NAME = "intronauts_dnd_guard"
        const val RULES_API = 35 // Build.VERSION_CODES.VANILLA_ICE_CREAM
        const val FILTER_ALL = NotificationManager.INTERRUPTION_FILTER_ALL
        const val FILTER_ALARMS = NotificationManager.INTERRUPTION_FILTER_ALARMS
        const val CONDITION_URI = "condition://meditofoundation.medito/timer"

        private fun forContext(context: Context): DndGuard {
            val app = context.applicationContext
            return DndGuard(AndroidZenBackend(app), PrefsDndRecordStore(app), Build.VERSION.SDK_INT)
        }

        /** Enciende «No molestar» para la sesión [runId] (timer o guiada). */
        fun apply(context: Context, runId: String, ruleName: String?): Boolean = safely(false) {
            forContext(context).apply(runId, ruleName)
        }

        fun restore(context: Context): Boolean = safely(false) {
            forContext(context).restore()
        }

        /**
         * Restaura si el registro pertenece a una sesión que ya no está viva:
         * su dueño no es [currentRunId] ni la sesión en curso del servicio.
         */
        fun restoreIfStale(context: Context, currentRunId: String?): Boolean = safely(false) {
            val live = if (AudioPlayerService.isActive) {
                setOfNotNull(currentRunId, AudioPlayerService.dndOwnerId)
            } else setOfNotNull(currentRunId)
            forContext(context).restoreIfStale(live)
        }

        /** Dueño del registro actual, o null si no hay nada aplicado. */
        fun activeOwner(context: Context): String? = safely(null) {
            PrefsDndRecordStore(context.applicationContext).read().takeIf { it.active }?.runId
        }

        private inline fun <T> safely(fallback: T, block: () -> T): T = try {
            block()
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo cambiar «No molestar»", error)
            fallback
        }
    }

    fun apply(runId: String, ruleName: String?): Boolean {
        if (!backend.hasAccess()) return false
        return if (sdkInt >= RULES_API) applyRule(runId, ruleName) else applyFilter(runId)
    }

    fun restore(): Boolean {
        val record = store.read()
        return if (sdkInt >= RULES_API) restoreRule(record) else restoreFilter(record)
    }

    /** Restaura el registro si su dueño no está entre [liveOwners]. */
    fun restoreIfStale(liveOwners: Set<String>): Boolean {
        val record = store.read()
        if (!record.active) return false
        if (record.runId != null && record.runId in liveOwners) return false
        return restore()
    }

    private fun applyRule(runId: String, ruleName: String?): Boolean {
        val record = store.read()
        val name = ruleName ?: record.ruleName ?: return false
        var id = record.ruleId
        if (id == null || !backend.ruleExists(id)) {
            id = backend.createRule(name) ?: return false
        }
        // Primero el registro: si el proceso muere, se puede apagar la regla.
        if (!store.write(record.copy(active = true, runId = runId, ruleId = id, ruleName = name))) return false
        backend.setRuleActive(id, name, true)
        return true
    }

    private fun restoreRule(record: DndRecord): Boolean {
        val id = record.ruleId ?: return false
        if (!backend.hasAccess()) return false
        // Siempre se apaga por id, sin importar lo que la persona haya encendido.
        if (backend.ruleExists(id)) backend.setRuleActive(id, record.ruleName ?: "", false)
        store.write(record.copy(active = false, runId = null))
        return true
    }

    private fun applyFilter(runId: String): Boolean {
        val record = store.read()
        val current = backend.currentFilter()
        if (record.active && current == record.applied) {
            // Ya lo puso la app: la nueva sesión se vuelve dueña.
            return store.write(record.copy(runId = runId))
        }
        // La persona ya tenía «No molestar»: no se toca.
        if (current != FILTER_ALL) return false
        val next = record.copy(active = true, previous = FILTER_ALL, applied = FILTER_ALARMS, runId = runId)
        if (!store.write(next)) return false
        backend.setFilter(FILTER_ALARMS)
        return true
    }

    private fun restoreFilter(record: DndRecord): Boolean {
        if (!record.active) return false
        if (!backend.hasAccess()) return false
        val restored = backend.currentFilter() == record.applied
        if (restored) backend.setFilter(record.previous)
        // Si la persona lo cambió mientras tanto, se respeta su elección.
        store.write(DndRecord(ruleId = record.ruleId, ruleName = record.ruleName))
        return restored
    }
}

private class PrefsDndRecordStore(context: Context) : DndRecordStore {
    private val prefs = context.getSharedPreferences(DndGuard.PREFS_NAME, Context.MODE_PRIVATE)

    override fun read(): DndRecord = DndRecord(
        active = prefs.getBoolean("active", false),
        previous = prefs.getInt("previous", DndRecord.FILTER_UNKNOWN),
        applied = prefs.getInt("applied", DndRecord.FILTER_UNKNOWN),
        runId = prefs.getString("runId", null),
        ruleId = prefs.getString("ruleId", null),
        ruleName = prefs.getString("ruleName", null)
    )

    override fun write(record: DndRecord): Boolean = prefs.edit()
        .putBoolean("active", record.active)
        .putInt("previous", record.previous)
        .putInt("applied", record.applied)
        .putString("runId", record.runId)
        .putString("ruleId", record.ruleId)
        .putString("ruleName", record.ruleName)
        .commit()
}

private class AndroidZenBackend(private val context: Context) : ZenBackend {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val conditionId: Uri get() = Uri.parse(DndGuard.CONDITION_URI)

    override fun hasAccess(): Boolean = manager?.isNotificationPolicyAccessGranted == true

    override fun currentFilter(): Int = manager?.currentInterruptionFilter ?: DndRecord.FILTER_UNKNOWN

    override fun setFilter(filter: Int) {
        manager?.setInterruptionFilter(filter)
    }

    override fun ruleExists(id: String): Boolean = manager?.getAutomaticZenRule(id) != null

    override fun createRule(name: String): String? {
        val manager = manager ?: return null
        if (Build.VERSION.SDK_INT < DndGuard.RULES_API) return null
        val rule = AutomaticZenRule.Builder(name, conditionId)
            .setConfigurationActivity(ComponentName(context, MainActivity::class.java))
            .setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALARMS)
            .setType(AutomaticZenRule.TYPE_OTHER)
            .build()
        return manager.addAutomaticZenRule(rule)
    }

    override fun setRuleActive(id: String, name: String, active: Boolean) {
        val state = if (active) Condition.STATE_TRUE else Condition.STATE_FALSE
        manager?.setAutomaticZenRuleState(id, Condition(conditionId, name, state))
    }
}
