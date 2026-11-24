package meditofoundation.medito

import meditofoundation.medito.pigeon.CompletionData
import meditofoundation.medito.pigeon.TimerEndedData
import org.json.JSONObject

internal object NativeCompletionRecord {
    /**
     * Cierre de un temporizador con la regla del tiempo meditado ([TimerElapsed]).
     * Sin [plannedMs] conserva el cálculo anterior (posición cruda), para datos viejos.
     */
    fun timerClose(
        fileId: String,
        positionMs: Long,
        timestamp: Long,
        prepMs: Long = 0L,
        plannedMs: Long? = null,
        isCountdownWithoutExtra: Boolean = false
    ): CompletionData {
        val isStopwatch = fileId.startsWith("timer-stopwatch-")
        val elapsedMs = if (plannedMs == null) positionMs.coerceAtLeast(0L) else TimerElapsed.elapsedMs(
            positionMs = positionMs,
            prepMs = prepMs,
            plannedMs = plannedMs,
            extraTime = !isStopwatch && !isCountdownWithoutExtra,
            isStopwatch = isStopwatch
        )
        val elapsedSeconds = elapsedMs / 1000L
        return CompletionData(
            trackId = "timer-$elapsedSeconds",
            duration = elapsedSeconds * 1000L,
            fileId = fileId,
            guideId = "",
            timestamp = timestamp,
            timerEnded = TimerEndedData(
                positionMs = positionMs,
                mode = if (isStopwatch) "stopwatch" else "countdown",
                elapsedSeconds = elapsedSeconds,
                recorded = elapsedSeconds >= 60L
            )
        )
    }

    fun encode(completion: CompletionData): String = JSONObject().apply {
        put("trackId", completion.trackId)
        put("duration", completion.duration)
        put("fileId", completion.fileId)
        put("guideId", completion.guideId)
        put("timestamp", completion.timestamp)
        completion.timerEnded?.let { ended ->
            put("timerEnded", JSONObject().apply {
                put("positionMs", ended.positionMs)
                put("mode", ended.mode)
                put("elapsedSeconds", ended.elapsedSeconds)
                put("recorded", ended.recorded)
            })
        }
    }.toString()

    fun decode(raw: String): CompletionData {
        val json = JSONObject(raw)
        return CompletionData(
            trackId = json.getString("trackId"),
            duration = json.getLong("duration"),
            fileId = json.getString("fileId"),
            guideId = json.optString("guideId"),
            timestamp = json.getLong("timestamp"),
            timerEnded = json.optJSONObject("timerEnded")?.let { ended ->
                TimerEndedData(
                    positionMs = ended.getLong("positionMs"),
                    mode = ended.getString("mode"),
                    elapsedSeconds = ended.getLong("elapsedSeconds"),
                    recorded = ended.getBoolean("recorded")
                )
            }
        )
    }
}
