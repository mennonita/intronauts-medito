package meditofoundation.medito

import meditofoundation.medito.pigeon.BellCue

/**
 * Consume las campanas cruzadas, incluso cuando están apagadas o llegan tarde.
 * Las obligatorias (inicio, fin, etapa) suenan aunque lleguen tarde; de las
 * opcionales (intervalo, aleatoria, hablada) sólo la más nueva con menos de 2 s.
 */
internal class TimerBellSchedule(cues: List<BellCue>) {
    companion object {
        const val LATE_LIMIT_MS = 2000L
        private val mandatoryKinds = setOf("start", "end", "stage")

        fun isMandatory(cue: BellCue): Boolean = cue.kind in mandatoryKinds
    }

    private val cues = cues.sortedBy { it.offsetMs }
    private var next = 0

    fun reset() {
        next = 0
    }

    fun seek(positionMs: Long) {
        reset()
        while (next < cues.size && cues[next].offsetMs <= positionMs) next++
    }

    /** Devuelve las campanas que tocan ahora, de la más vieja a la más nueva. */
    fun update(positionMs: Long, enabled: Boolean): List<BellCue> {
        val ring = mutableListOf<BellCue>()
        var optional: BellCue? = null
        while (next < cues.size && cues[next].offsetMs <= positionMs) {
            val cue = cues[next++]
            if (!enabled) continue
            if (isMandatory(cue)) {
                ring.add(cue)
            } else if (positionMs - cue.offsetMs < LATE_LIMIT_MS) {
                optional = cue
            }
        }
        optional?.let(ring::add)
        return ring.sortedBy { it.offsetMs }
    }
}
