package meditofoundation.medito

import meditofoundation.medito.pigeon.CompletionData
import meditofoundation.medito.pigeon.TimerEndedData
import org.json.JSONObject

internal object NativeCompletionRecord {
    fun timerClose(fileId: String, positionMs: Long, timestamp: Long): CompletionData {
        val elapsedSeconds = positionMs.coerceAtLeast(0L) / 1000L
        return CompletionData(
            trackId = "timer-$elapsedSeconds",
            duration = elapsedSeconds * 1000L,
            fileId = fileId,
            guideId = "",
            timestamp = timestamp,
            timerEnded = TimerEndedData(
                positionMs = positionMs,
                mode = if (fileId.startsWith("timer-stopwatch-")) "stopwatch" else "countdown",
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
