package meditofoundation.medito

/** Cambios de foco de audio que el temporizador entiende. */
internal enum class FocusChange { GAIN, LOSS, LOSS_TRANSIENT, LOSS_TRANSIENT_CAN_DUCK }

/** Lo que el servicio debe hacer ante un cambio de foco o una llamada. */
internal sealed class FocusAction {
    data class Pause(val resumeLater: Boolean) : FocusAction()
    object Resume : FocusAction()
    object Duck : FocusAction()
    object Unduck : FocusAction()
    object NotifyOtherAudio : FocusAction()
    object None : FocusAction()
}

/**
 * Política de foco del temporizador (§4.4), sin dependencias de Android.
 * Modo normal: llamadas e interrupciones pausan y reanudan; otra app que se
 * queda con el audio pausa y avisa. Modo mezcla: nunca pide foco; sólo las
 * llamadas (vistas en `AudioManager.mode`) pausan y reanudan.
 */
internal class TimerFocusPolicy(val mixWithOthers: Boolean) {
    companion object {
        // Valores de AudioManager.MODE_*; se copian para probar sin Android.
        const val MODE_NORMAL = 0
        private val callModes = setOf(
            1, // MODE_RINGTONE
            2, // MODE_IN_CALL
            3, // MODE_IN_COMMUNICATION
            4, // MODE_CALL_SCREENING
            5, // MODE_CALL_REDIRECT
            6  // MODE_COMMUNICATION_REDIRECT
        )

        fun isCallMode(mode: Int): Boolean = mode in callModes

        fun fromAndroid(focusChange: Int): FocusChange? = when (focusChange) {
            1 -> FocusChange.GAIN // AUDIOFOCUS_GAIN
            -1 -> FocusChange.LOSS // AUDIOFOCUS_LOSS
            -2 -> FocusChange.LOSS_TRANSIENT // AUDIOFOCUS_LOSS_TRANSIENT
            -3 -> FocusChange.LOSS_TRANSIENT_CAN_DUCK // AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK
            else -> null
        }
    }

    var resumeLater = false
        private set
    var ducked = false
        private set
    private var inCall = false

    fun onFocusChange(change: FocusChange, isPlaying: Boolean): List<FocusAction> {
        // En modo mezcla nunca se pide foco; cualquier aviso es ajeno.
        if (mixWithOthers) return listOf(FocusAction.None)
        return when (change) {
            FocusChange.LOSS_TRANSIENT -> {
                if (isPlaying) {
                    resumeLater = true
                    listOf(FocusAction.Pause(resumeLater = true))
                } else listOf(FocusAction.None)
            }
            FocusChange.LOSS_TRANSIENT_CAN_DUCK -> {
                if (ducked) listOf(FocusAction.None) else {
                    ducked = true
                    listOf(FocusAction.Duck)
                }
            }
            FocusChange.LOSS -> {
                val wasWaiting = resumeLater
                resumeLater = false
                if (isPlaying || wasWaiting) {
                    listOf(FocusAction.Pause(resumeLater = false), FocusAction.NotifyOtherAudio)
                } else listOf(FocusAction.None)
            }
            FocusChange.GAIN -> {
                val actions = mutableListOf<FocusAction>()
                if (ducked) {
                    ducked = false
                    actions.add(FocusAction.Unduck)
                }
                if (resumeLater) {
                    resumeLater = false
                    actions.add(FocusAction.Resume)
                }
                if (actions.isEmpty()) listOf(FocusAction.None) else actions
            }
        }
    }

    /** Sólo en modo mezcla: llamadas detectadas por el modo de audio. */
    fun onCallState(callActive: Boolean, isPlaying: Boolean): List<FocusAction> {
        if (!mixWithOthers) return listOf(FocusAction.None)
        val was = inCall
        inCall = callActive
        if (callActive && !was) {
            if (isPlaying) {
                resumeLater = true
                return listOf(FocusAction.Pause(resumeLater = true))
            }
            return listOf(FocusAction.None)
        }
        if (!callActive && was && resumeLater) {
            resumeLater = false
            return listOf(FocusAction.Resume)
        }
        return listOf(FocusAction.None)
    }

    /**
     * Antes de arrancar o reanudar el reloj (R103). Modo normal: sin foco
     * concedido se espera el GAIN. Modo mezcla: durante una llamada se espera
     * a que termine. Devuelve true si puede sonar ya.
     */
    fun onStartAttempt(callActive: Boolean, focusGranted: Boolean): Boolean {
        if (mixWithOthers) {
            inCall = callActive
            if (callActive) {
                resumeLater = true
                return false
            }
            return true
        }
        if (!focusGranted) {
            resumeLater = true
            return false
        }
        return true
    }

    /** Una pausa de la persona cancela la reanudación automática. */
    fun onUserPause() {
        resumeLater = false
    }

    /** La persona reanudó por su cuenta: ya no hay nada pendiente. */
    fun onUserResume() {
        resumeLater = false
    }
}
