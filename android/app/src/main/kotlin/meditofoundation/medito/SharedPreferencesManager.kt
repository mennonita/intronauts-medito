package meditofoundation.medito

import meditofoundation.medito.pigeon.CompletionData
import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

object SharedPreferencesManager {
    private const val PREFS_NAME = "MeditoAudioPrefs"
    private const val KEY_LAST_COMPLETED_TRACK = "lastCompletedTrack"
    private const val KEY_PENDING_REPEATS = "pendingRepeatPlaythroughs"
    private const val KEY_CLIENT_ID = "completionClientId"
    private const val KEY_USER_ID = "completionUserId"
    private var activeClientId: String? = null
    private var verified = false
    private var generation = 0L
    private const val TAG = "SharedPreferencesManager"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // Ambas colas comparten la identidad de la cuenta que grabó el audio.
    @Synchronized
    fun bindAccount(context: Context, clientId: String, userId: String?): Boolean {
        val preferences = prefs(context)
        val previousClient = preferences.getString(KEY_CLIENT_ID, null)
        val previousUser = preferences.getString(KEY_USER_ID, null)
        val changed = previousClient != clientId ||
            (userId != null && previousUser != null && previousUser != userId)
        if (changed) clearAccount(context)
        if (activeClientId != clientId) generation++
        activeClientId = clientId
        verified = userId != null
        preferences.edit().putString(KEY_CLIENT_ID, clientId).apply {
            if (userId != null) putString(KEY_USER_ID, userId)
        }.apply()
        return changed
    }

    @Synchronized
    fun clearAccount(context: Context) {
        generation++
        activeClientId = null
        verified = false
        check(prefs(context).edit().clear().commit()) {
            "No se pudieron borrar las colas de audio"
        }
        // La generación ya subió: ningún evento pendiente puede volver a escribir
        // las sesiones de temporizador de la cuenta anterior.
        check(
            context.getSharedPreferences(TimerRunStore.PREFS_NAME, Context.MODE_PRIVATE)
                .edit().clear().commit()
        ) {
            "No se pudieron borrar las sesiones del temporizador"
        }
    }

    @Synchronized
    fun currentGeneration(): Long = generation

    @Synchronized
    fun isCurrent(value: Long, requireVerified: Boolean = false): Boolean =
        value == generation && activeClientId != null && (!requireVerified || verified)

    /** Revisa la generación y ejecuta [block] bajo el mismo candado (registro de temporizador). */
    @Synchronized
    fun <T> ifCurrent(value: Long, block: () -> T): T? =
        if (isCurrent(value)) block() else null

    @Synchronized
    fun saveCompletionData(context: Context, completionData: CompletionData, generation: Long): Boolean {
        if (!isCurrent(generation)) return false
        return try {
            val write = prefs(context).edit()
                .putString(KEY_LAST_COMPLETED_TRACK, NativeCompletionRecord.encode(completionData))
            if (completionData.timerEnded != null) {
                val saved = write.commit()
                if (!saved) Log.e(TAG, "No se pudo guardar el cierre del temporizador")
                saved
            } else {
                write.apply()
                true
            }
        } catch (e: JSONException) {
            Log.e(TAG, "Error saving completion data: ${e.message}")
            false
        }
    }

    fun getCompletionData(context: Context): CompletionData? {
        val completionString = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_LAST_COMPLETED_TRACK, null)

        return try {
            completionString?.let(NativeCompletionRecord::decode)
        } catch (e: JSONException) {
            Log.e(TAG, "Error parsing completion data: ${e.message}")
            null
        }
    }

    @Synchronized
    fun clearCompletionData(context: Context, completionData: CompletionData, generation: Long) {
        if (!isCurrent(generation)) return
        val stored = getCompletionData(context) ?: return
        if (stored.timestamp != completionData.timestamp ||
            stored.trackId != completionData.trackId ||
            stored.fileId != completionData.fileId
        ) return
        val write = prefs(context).edit().remove(KEY_LAST_COMPLETED_TRACK)
        if (completionData.timerEnded != null) write.commit() else write.apply()
    }

    // Repeat play-throughs not yet acknowledged by Dart. A list (not a single
    // slot like the completion) because repeat forever can finish several
    // loops while the engine is unavailable. Keyed by timestamp.
    @Synchronized
    fun addPendingRepeat(context: Context, completionData: CompletionData, generation: Long): Boolean {
        if (!isCurrent(generation)) return false
        val pending = readPendingRepeats(context)
        pending.put(JSONObject().apply {
            put("trackId", completionData.trackId)
            put("duration", completionData.duration)
            put("fileId", completionData.fileId)
            put("guideId", completionData.guideId)
            put("timestamp", completionData.timestamp)
        })
        writePendingRepeats(context, pending)
        return true
    }

    @Synchronized
    fun getPendingRepeats(context: Context): List<CompletionData> {
        val pending = readPendingRepeats(context)
        return (0 until pending.length()).mapNotNull { i ->
            try {
                val json = pending.getJSONObject(i)
                CompletionData(
                    trackId = json.getString("trackId"),
                    duration = json.getLong("duration"),
                    fileId = json.getString("fileId"),
                    guideId = json.optString("guideId", "None"),
                    timestamp = json.getLong("timestamp")
                )
            } catch (e: JSONException) {
                Log.e(TAG, "Error parsing pending repeat: ${e.message}")
                null
            }
        }
    }

    @Synchronized
    fun removePendingRepeat(context: Context, completionData: CompletionData, generation: Long) {
        if (!isCurrent(generation)) return
        val pending = readPendingRepeats(context)
        val remaining = JSONArray()
        for (i in 0 until pending.length()) {
            val json = pending.optJSONObject(i) ?: continue
            if (json.optLong("timestamp") != completionData.timestamp) remaining.put(json)
        }
        writePendingRepeats(context, remaining)
    }

    private fun readPendingRepeats(context: Context): JSONArray {
        val raw = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_PENDING_REPEATS, null) ?: return JSONArray()
        return try {
            JSONArray(raw)
        } catch (e: JSONException) {
            Log.e(TAG, "Error parsing pending repeats: ${e.message}")
            JSONArray()
        }
    }

    private fun writePendingRepeats(context: Context, pending: JSONArray) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PENDING_REPEATS, pending.toString())
            .apply()
    }
}