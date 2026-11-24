package meditofoundation.medito

/** Tipo de sesión dueña del foco de audio. */
internal enum class FocusKind { GUIDED, TIMER }

/** Acceso al sistema de foco (AudioManager real o uno falso en pruebas). */
internal interface FocusBackend<R : Any> {
    fun build(kind: FocusKind): R
    fun request(request: R): Boolean
    fun abandon(request: R)
}

/**
 * Único dueño del foco de audio de la sesión actual. Guarda la MISMA solicitud
 * que pidió y la entrega al soltar el foco (antes se armaba una nueva y la
 * original nunca se liberaba). En modo mezcla no pide ni guarda nada.
 */
internal class TimerAudioFocus<R : Any>(private val backend: FocusBackend<R>) {
    private var held: R? = null
    private var heldKind: FocusKind? = null

    var granted = false
        private set

    val isHeld: Boolean get() = held != null

    /** Pide el foco para [kind]; devuelve true si el sistema lo concedió. */
    fun ensure(kind: FocusKind, mixWithOthers: Boolean): Boolean {
        if (held != null && (heldKind != kind || mixWithOthers)) abandon()
        if (mixWithOthers) return false
        val request = held ?: backend.build(kind).also {
            held = it
            heldKind = kind
            granted = false
        }
        if (!granted) granted = backend.request(request)
        return granted
    }

    /** Suelta la solicitud guardada (el mismo objeto que se pidió). */
    fun abandon() {
        val request = held ?: return
        held = null
        heldKind = null
        granted = false
        backend.abandon(request)
    }

    /** El sistema avisó un cambio: ganado o perdido (temporal o definitivo). */
    fun onFocusChange(gained: Boolean) {
        if (held != null) granted = gained
    }
}
