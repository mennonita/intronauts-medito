package meditofoundation.medito

import android.content.Context
import android.util.Log
import meditofoundation.medito.pigeon.CompletionData
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** La sesión de temporizador que está corriendo (sólo una a la vez). */
internal data class TimerActiveRun(
    val runId: String,
    val ownerId: String,
    val fileId: String,
    val trackId: String,
    val guideId: String?,
    val startEpochMs: Long,
    val prepMs: Long,
    val plannedMs: Long,
    val extraTime: Boolean,
    val isStopwatch: Boolean,
    val lastPositionMs: Long,
    val updatedAtMs: Long,
    val endPassed: Boolean,
    /** Número de la última foto guardada; una foto más vieja nunca la reemplaza (R108). */
    val seq: Long = 0L
) {
    fun elapsedMs(positionMs: Long = lastPositionMs): Long =
        TimerElapsed.elapsedMs(positionMs, prepMs, plannedMs, extraTime, isStopwatch)

    fun toJson(): JSONObject = JSONObject().apply {
        put("runId", runId)
        put("ownerId", ownerId)
        put("fileId", fileId)
        put("trackId", trackId)
        put("guideId", guideId ?: JSONObject.NULL)
        put("startEpochMs", startEpochMs)
        put("prepMs", prepMs)
        put("plannedMs", plannedMs)
        put("extraTime", extraTime)
        put("isStopwatch", isStopwatch)
        put("lastPositionMs", lastPositionMs)
        put("updatedAtMs", updatedAtMs)
        put("endPassed", endPassed)
        put("seq", seq)
    }

    companion object {
        fun fromJson(json: JSONObject) = TimerActiveRun(
            runId = json.getString("runId"),
            ownerId = json.optString("ownerId", ""),
            fileId = json.optString("fileId", ""),
            trackId = json.optString("trackId", ""),
            guideId = if (json.isNull("guideId")) null else json.optString("guideId"),
            startEpochMs = json.optLong("startEpochMs"),
            prepMs = json.optLong("prepMs"),
            plannedMs = json.optLong("plannedMs"),
            extraTime = json.optBoolean("extraTime"),
            isStopwatch = json.optBoolean("isStopwatch"),
            lastPositionMs = json.optLong("lastPositionMs"),
            updatedAtMs = json.optLong("updatedAtMs"),
            endPassed = json.optBoolean("endPassed"),
            seq = json.optLong("seq")
        )
    }
}

/** Un cierre que espera a que Dart lo guarde en las estadísticas. */
internal data class TimerFinishedRun(
    val runId: String,
    val ownerId: String,
    val trackId: String,
    val fileId: String,
    val guideId: String?,
    val durationMs: Long,
    val timestamp: Long,
    val recovered: Boolean
) {
    fun toCompletion(): CompletionData = CompletionData(
        trackId = trackId,
        duration = durationMs,
        fileId = fileId,
        guideId = guideId,
        timestamp = timestamp,
        runId = runId,
        ownerId = ownerId,
        recovered = recovered
    )

    fun toJson(): JSONObject = JSONObject().apply {
        put("runId", runId)
        put("ownerId", ownerId)
        put("trackId", trackId)
        put("fileId", fileId)
        put("guideId", guideId ?: JSONObject.NULL)
        put("durationMs", durationMs)
        put("timestamp", timestamp)
        put("recovered", recovered)
    }

    companion object {
        fun fromJson(json: JSONObject) = TimerFinishedRun(
            runId = json.getString("runId"),
            ownerId = json.optString("ownerId", ""),
            trackId = json.getString("trackId"),
            fileId = json.optString("fileId", ""),
            guideId = if (json.isNull("guideId")) null else json.optString("guideId"),
            durationMs = json.getLong("durationMs"),
            timestamp = json.getLong("timestamp"),
            recovered = json.optBoolean("recovered")
        )

        /** Cierre de [run] con la duración ya calculada; null si no llega a 60 s. */
        fun close(run: TimerActiveRun, durationMs: Long, trackId: String, timestamp: Long, recovered: Boolean): TimerFinishedRun? {
            if (durationMs < TimerElapsed.MIN_RECORDED_MS) return null
            return TimerFinishedRun(
                runId = run.runId,
                ownerId = run.ownerId,
                trackId = trackId,
                fileId = run.fileId,
                guideId = run.guideId,
                durationMs = durationMs,
                timestamp = timestamp,
                recovered = recovered
            )
        }

        /** Cierre recuperado de una sesión que murió con el proceso. */
        fun recovered(run: TimerActiveRun): TimerFinishedRun? {
            val elapsed = run.elapsedMs()
            val seconds = elapsed / 1000L
            return close(run, seconds * 1000L, TimerElapsed.trackId(elapsed), run.updatedAtMs, recovered = true)
        }
    }
}

/** Resultado de un cierre con guardado (R100). */
internal enum class TimerCloseResult {
    /** Hay un cierre confirmado en disco para la sesión. */
    SAVED,
    /** Confirmado sin cierre: duró menos de 60 s (o no había nada que guardar). */
    SHORT,
    /** No se pudo escribir (o la cuenta ya no es la vigente): nada cambió. */
    FAILED
}

/** Guardado crudo: un solo texto que se escribe con `commit()`. */
internal interface TimerRunStorage {
    fun read(): String?
    fun commit(value: String?): Boolean
}

/** Candado y generación de la cuenta (los de [SharedPreferencesManager]). */
internal interface TimerRunGate {
    fun currentGeneration(): Long
    /** Ejecuta [block] bajo el candado sólo si [generation] sigue vigente. */
    fun <T> ifCurrent(generation: Long, block: () -> T): T?
}

/**
 * Registro nativo de sesiones de temporizador (§4.6): la ÚNICA fuente del
 * registro de estadísticas de un temporizador en Android. `active` es la sesión
 * que corre; `finished` es la lista (sin tope, sin duplicados por `runId`) de
 * cierres que esperan a que Dart confirme que los guardó.
 */
internal class TimerRunStore(
    private val storage: TimerRunStorage,
    private val gate: TimerRunGate
) {
    private data class State(val active: TimerActiveRun?, val finished: List<TimerFinishedRun>)

    companion object {
        private const val TAG = "TimerRunStore"
        const val PREFS_NAME = "intronauts_timer_runs"
        private const val KEY_STATE = "state"
        private const val DELIVERY_STALE_MS = 60_000L

        @Volatile
        private var shared: TimerRunStore? = null

        /** Una sola instancia por proceso, para que la entrega nunca vaya doble. */
        fun forContext(context: Context): TimerRunStore = shared ?: synchronized(this) {
            shared ?: TimerRunStore(PrefsTimerRunStorage(context.applicationContext), AccountGate)
                .also { shared = it }
        }

        /**
         * Recupera una sesión que murió con el proceso. Se llama al empezar
         * `MainActivity.checkAndSendCompletionData` (después de ligar la cuenta).
         */
        fun recoverStale(context: Context, liveRunId: String?): Boolean =
            forContext(context).recoverStale(liveRunId, SharedPreferencesManager.currentGeneration())
    }

    @Volatile
    private var deliveryStartedAt: Long? = null

    // Último estado CONFIRMADO en disco. `SharedPreferences.commit()` cambia la memoria
    // aunque falle el disco, así que nunca se vuelve a leer tras un fallo (R101).
    @Volatile
    private var confirmed: State? = null

    @Volatile
    private var confirmedGeneration: Long = Long.MIN_VALUE

    // Sesiones que se pidieron descartar sin poder confirmarlo: jamás se recuperan.
    private val discarded = mutableSetOf<String>()

    // En pruebas unitarias `Log` de Android no existe; el registro nunca debe tumbar una escritura.
    private fun logError(message: String, error: Throwable? = null) {
        try {
            Log.e(TAG, message, error)
        } catch (_: RuntimeException) {
            println("$TAG: $message")
        }
    }

    // ---- Lectura ----

    private fun readState(): State {
        val generation = gate.currentGeneration()
        val cached = confirmed
        if (cached != null && confirmedGeneration == generation) return cached
        return decode(storage.read()).also {
            confirmed = it
            confirmedGeneration = generation
        }
    }

    private fun decode(raw: String?): State {
        if (raw == null) return State(null, emptyList())
        return try {
            val json = JSONObject(raw)
            val active = json.optJSONObject("active")?.let(TimerActiveRun::fromJson)
            val list = json.optJSONArray("finished") ?: JSONArray()
            val finished = (0 until list.length()).mapNotNull { i ->
                try {
                    TimerFinishedRun.fromJson(list.getJSONObject(i))
                } catch (e: JSONException) {
                    logError("Cierre ilegible, se omite: ${e.message}")
                    null
                }
            }
            State(active, finished)
        } catch (e: JSONException) {
            logError("Registro de sesiones ilegible: ${e.message}")
            State(null, emptyList())
        }
    }

    private fun encode(state: State): String? {
        if (state.active == null && state.finished.isEmpty()) return null
        return JSONObject().apply {
            put("active", state.active?.toJson() ?: JSONObject.NULL)
            put("finished", JSONArray().apply { state.finished.forEach { put(it.toJson()) } })
        }.toString()
    }

    private fun commit(state: State): Boolean {
        val saved = storage.commit(encode(state))
        if (saved) {
            confirmed = state
            confirmedGeneration = gate.currentGeneration()
            return true
        }
        logError("No se pudo guardar el registro de sesiones")
        // Se intenta devolver la memoria al último estado confirmado.
        confirmed?.let { storage.commit(encode(it)) }
        return false
    }

    private fun State.withFinished(item: TimerFinishedRun?): State {
        if (item == null || finished.any { it.runId == item.runId }) return this
        return copy(finished = finished + item)
    }

    /** Una sesión que quedó en `active` y no es la viva pasa a `finished` como recuperada. */
    private fun State.recovering(liveRunId: String?): State {
        val stale = active ?: return this
        if (stale.runId == liveRunId) return this
        if (stale.runId in discarded) return copy(active = null)
        return copy(active = null).withFinished(TimerFinishedRun.recovered(stale))
    }

    fun active(): TimerActiveRun? = readState().active

    fun pending(): List<TimerFinishedRun> = readState().finished

    // ---- Escrituras (cada una: candado + generación + UN commit) ----

    /** Inicio: si `active` guarda otra sesión, primero la recupera en el MISMO commit. */
    fun start(run: TimerActiveRun, generation: Long): Boolean = gate.ifCurrent(generation) {
        val state = readState()
        if (state.active?.runId == run.runId) return@ifCurrent commit(state.copy(active = run))
        commit(state.recovering(run.runId).copy(active = run))
    } ?: false

    /** Foto de la sesión; [seq] se toma en el evento y una foto vieja se rechaza (R108). */
    fun update(runId: String, positionMs: Long, endPassed: Boolean, nowMs: Long, generation: Long, seq: Long): Boolean =
        gate.ifCurrent(generation) {
            val state = readState()
            val active = state.active ?: return@ifCurrent false
            if (active.runId != runId || seq <= active.seq) return@ifCurrent false
            commit(state.copy(active = active.copy(
                lastPositionMs = positionMs,
                updatedAtMs = nowMs,
                endPassed = active.endPassed || endPassed,
                seq = seq
            )))
        } ?: false

    /**
     * Cierre con guardado (fin natural, «Guardar y salir», cierre del sistema):
     * agrega el cierre si dura 60 s o más y limpia `active`, en UN commit.
     */
    fun finish(
        runId: String,
        durationMs: Long,
        trackId: String,
        timestamp: Long,
        generation: Long,
        fallback: TimerActiveRun? = null
    ): TimerCloseResult = gate.ifCurrent(generation) {
        val state = readState()
        val run = state.active?.takeIf { it.runId == runId } ?: fallback?.takeIf { it.runId == runId }
        val already = state.finished.any { it.runId == runId }
        val item = if (already || run == null || runId in discarded) null
        else TimerFinishedRun.close(run, durationMs, trackId, timestamp, recovered = false)
        val next = state.copy(active = state.active?.takeIf { it.runId != runId }).withFinished(item)
        val outcome = if (already || item != null) TimerCloseResult.SAVED else TimerCloseResult.SHORT
        if (next == state) return@ifCurrent outcome
        // Ya estaba guardado: aunque falle quitar `active`, el cierre sigue confirmado.
        if (commit(next) || already) outcome else TimerCloseResult.FAILED
    } ?: TimerCloseResult.FAILED

    /**
     * «Salir sin guardar»: limpia `active` sin agregar nada. Con [rememberOnFailure]
     * (el audio se detiene de todos modos), un fallo deja la sesión marcada en
     * memoria para que nunca se recupere ni se guarde.
     */
    fun discard(runId: String, generation: Long, rememberOnFailure: Boolean = false): Boolean =
        gate.ifCurrent(generation) {
            val state = readState()
            if (state.active?.runId != runId) return@ifCurrent true
            if (commit(state.copy(active = null))) {
                discarded.remove(runId)
                true
            } else {
                if (rememberOnFailure) discarded.add(runId)
                false
            }
        } ?: false // Otra cuenta: el registro ya se borró al cambiarla.

    /** Devuelve true si agregó un cierre recuperado. */
    fun recoverStale(liveRunId: String?, generation: Long): Boolean = gate.ifCurrent(generation) {
        val state = readState()
        val next = state.recovering(liveRunId)
        if (next == state) return@ifCurrent false
        commit(next) && next.finished.size > state.finished.size
    } ?: false

    fun remove(runId: String, generation: Long): Boolean = gate.ifCurrent(generation) {
        val state = readState()
        val next = state.copy(finished = state.finished.filterNot { it.runId == runId })
        if (next == state) return@ifCurrent true
        commit(next)
    } ?: false

    // ---- Entrega a Dart ----

    /**
     * Entrega los cierres EN ORDEN, uno a la vez. `true` quita ESE `runId`;
     * `false` o error detiene hasta el siguiente intento. Nunca hay dos entregas
     * en vuelo; una entrega sin respuesta por más de 60 s se da por perdida.
     */
    fun deliverPending(
        nowMs: () -> Long = System::currentTimeMillis,
        send: (CompletionData, (Boolean) -> Unit) -> Unit
    ) {
        val generation = gate.currentGeneration()
        val item: TimerFinishedRun
        val token: Long
        synchronized(this) {
            val started = deliveryStartedAt
            if (started != null && nowMs() - started < DELIVERY_STALE_MS) return
            item = gate.ifCurrent(generation) { readState().finished.firstOrNull() } ?: run {
                deliveryStartedAt = null
                return
            }
            token = nowMs()
            deliveryStartedAt = token
        }
        try {
            send(item.toCompletion()) { ok ->
                synchronized(this) {
                    if (deliveryStartedAt != token) return@send
                    deliveryStartedAt = null
                }
                if (ok && remove(item.runId, generation)) deliverPending(nowMs, send)
            }
        } catch (error: Exception) {
            logError("No se pudo entregar el cierre", error)
            synchronized(this) { if (deliveryStartedAt == token) deliveryStartedAt = null }
        }
    }
}

private object AccountGate : TimerRunGate {
    override fun currentGeneration(): Long = SharedPreferencesManager.currentGeneration()
    override fun <T> ifCurrent(generation: Long, block: () -> T): T? =
        SharedPreferencesManager.ifCurrent(generation, block)
}

private class PrefsTimerRunStorage(context: Context) : TimerRunStorage {
    private val prefs = context.getSharedPreferences(TimerRunStore.PREFS_NAME, Context.MODE_PRIVATE)

    override fun read(): String? = prefs.getString("state", null)

    override fun commit(value: String?): Boolean {
        val edit = prefs.edit()
        if (value == null) edit.remove("state") else edit.putString("state", value)
        return edit.commit()
    }
}
