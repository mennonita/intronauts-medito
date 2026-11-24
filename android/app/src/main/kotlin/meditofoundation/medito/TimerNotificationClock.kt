package meditofoundation.medito

/**
 * Regla del tiempo meditado (gemela de `TimerTimeline` en Dart): la preparación
 * nunca cuenta, la cuenta regresiva simple se corta en lo planeado, el tiempo
 * extra en lo planeado + 5 h y el cronómetro en 5 h (su cola final no cuenta).
 */
internal object TimerElapsed {
    const val STOPWATCH_CAP_MS = 5L * 60L * 60L * 1000L
    const val MIN_RECORDED_MS = 60_000L

    fun sessionPositionMs(positionMs: Long, prepMs: Long): Long =
        (positionMs - prepMs).coerceAtLeast(0L)

    fun elapsedMs(
        positionMs: Long,
        prepMs: Long,
        plannedMs: Long,
        extraTime: Boolean,
        isStopwatch: Boolean
    ): Long {
        val session = sessionPositionMs(positionMs, prepMs)
        val cap = when {
            isStopwatch -> STOPWATCH_CAP_MS
            extraTime -> plannedMs + STOPWATCH_CAP_MS
            else -> plannedMs
        }
        return session.coerceAtMost(cap.coerceAtLeast(0L))
    }

    /** Id de la sesión igual que `timerSessionId` de Dart: `timer-<segundos>`. */
    fun trackId(durationMs: Long): String = "timer-${durationMs.coerceAtLeast(0L) / 1000L}"
}

/** Lo que muestra el cronómetro de la notificación del temporizador. */
internal data class TimerClock(
    val usesChronometer: Boolean,
    val countDown: Boolean,
    val whenMs: Long,
    val subText: TimerClock.Kind?
) {
    enum class Kind { PREP, EXTRA_TIME }
}

internal object TimerNotificationClock {
    /** Fases que obligan a reconstruir la notificación cuando cambian. */
    fun phase(positionMs: Long, prepMs: Long, plannedMs: Long): Int = when {
        positionMs < prepMs -> 0
        positionMs < prepMs + plannedMs -> 1
        else -> 2
    }

    fun clock(
        nowMs: Long,
        positionMs: Long,
        isPlaying: Boolean,
        prepMs: Long,
        plannedMs: Long,
        extraTime: Boolean,
        isStopwatch: Boolean
    ): TimerClock {
        // En pausa no corre ningún cronómetro; el texto «En pausa» lo pone el servicio.
        if (!isPlaying) return TimerClock(false, false, nowMs, null)

        if (positionMs < prepMs) {
            return TimerClock(true, true, nowMs + (prepMs - positionMs), TimerClock.Kind.PREP)
        }
        val session = TimerElapsed.sessionPositionMs(positionMs, prepMs)
        if (isStopwatch) {
            // Al llegar al tope de 5 h el cronómetro se detiene (la cola final no cuenta).
            if (session >= TimerElapsed.STOPWATCH_CAP_MS) return TimerClock(false, false, nowMs, null)
            return TimerClock(true, false, nowMs - session, null)
        }
        if (session >= plannedMs) {
            if (extraTime) {
                return TimerClock(true, false, nowMs - (session - plannedMs), TimerClock.Kind.EXTRA_TIME)
            }
            // Cuenta regresiva terminada: sin cronómetro para no mostrar números negativos.
            return TimerClock(false, false, nowMs, null)
        }
        return TimerClock(true, true, nowMs + (plannedMs - session), null)
    }
}
