package meditofoundation.medito

import meditofoundation.medito.pigeon.BellCue

/** Consume las campanas cruzadas, incluso cuando están apagadas o llegan tarde. */
internal class TimerBellSchedule(cues: List<BellCue>) {
    private val cues = cues.toList()
    private var next = 0

    fun reset() {
        next = 0
    }

    fun seek(positionMs: Long) {
        reset()
        while (next < cues.size && cues[next].offsetMs <= positionMs) next++
    }

    fun update(positionMs: Long, enabled: Boolean): BellCue? {
        var ring: BellCue? = null
        while (next < cues.size && cues[next].offsetMs <= positionMs) {
            val cue = cues[next++]
            if (enabled && positionMs - cue.offsetMs < 2000) ring = cue
        }
        return ring
    }
}
