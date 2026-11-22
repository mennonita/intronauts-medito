package meditofoundation.medito

/** Consume las campanas cruzadas, incluso cuando están apagadas o llegan tarde. */
internal class TimerBellSchedule(offsetsMs: List<Long>) {
    private val offsets = offsetsMs.toList()
    private var next = 0

    fun reset() {
        next = 0
    }

    fun seek(positionMs: Long) {
        reset()
        if (positionMs == 0L) return
        while (next < offsets.size && offsets[next] <= positionMs) next++
    }

    fun update(positionMs: Long, enabled: Boolean): Long? {
        var ring: Long? = null
        while (next < offsets.size && offsets[next] <= positionMs) {
            val cue = offsets[next++]
            if (enabled && positionMs - cue < 2000) ring = cue
        }
        return ring
    }
}
