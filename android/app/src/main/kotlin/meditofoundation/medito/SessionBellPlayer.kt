@file:androidx.media3.common.util.UnstableApi
package meditofoundation.medito

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import meditofoundation.medito.pigeon.BellCue

/** Programa las campanas aunque la pantalla esté bloqueada. */
internal class SessionBellPlayer(
    private val context: Context,
    private val primary: Player
) : Player.Listener {
    companion object {
        const val URI = "medito://session-bells"
        private const val LEGACY_ASSET = "assets/audio/session_bell_v2.wav"
        const val OUTPUT_SOUND = "sound"
        const val OUTPUT_VIBRATION = "vibration"
        const val OUTPUT_SOUND_AND_VIBRATION = "soundAndVibration"
        private const val KIND_END = "end"
        private const val KIND_SPOKEN = "spoken"
        private const val VIBRATION_PULSE_MS = 400L
        private const val VIBRATION_SLOT_MS = 1000L
    }

    private val handler = Handler(Looper.getMainLooper())
    private val schedule = SessionBellSchedule()
    private val timerPlayers = mutableMapOf<String, ExoPlayer>()
    private var preload: TimerBellPreload? = null
    private var trackBell: ExoPlayer? = null
    private var activeBell: ExoPlayer? = null
    private var timerSchedule: TimerBellSchedule? = null
    private var endStarted = false
    private var pendingEnd = false
    private var timerStopped = false
    private var onPrepared: (() -> Unit)? = null
    private var volume = 1f
    private var duck = 1f
    private var enabled = false
    private var output = OUTPUT_SOUND
    private var vibrationToken = 0
    // Una vibración de la fila quedó a medias por una pausa; se termina al reanudar.
    private var vibrationPaused = false
    private var timerPaused = false
    private var drain: TimerBellDrain? = null
    private var onDrained: (() -> Unit)? = null
    private val speech by lazy { TimerSpeech(context) }
    private var speechCreated = false
    private val queue = TimerBellQueue(object : TimerBellRinger {
        override fun ring(cue: BellCue): Boolean = startCue(cue)
    })

    /** Avisa cuando empieza la campana final (antes de su sonido). */
    var onEndCueStarted: (() -> Unit)? = null

    /** True sólo cuando la campana final de ESTE temporizador de verdad empezó a sonar. */
    val endCueStarted: Boolean get() = endStarted

    private val tick = object : Runnable {
        override fun run() {
            update()
            if (!timerStopped && (enabled || timerSchedule != null)) handler.postDelayed(this, 100)
        }
    }

    init { primary.addListener(this) }

    fun configure(
        cues: List<BellCue>?,
        timerEnabled: Boolean,
        volume: Float,
        output: String? = null,
        languageTag: String? = null
    ) {
        if (cues == null && timerSchedule == null) return
        disable()
        timerSchedule = cues?.let(::TimerBellSchedule)
        endStarted = false
        timerStopped = false
        timerPaused = false
        vibrationPaused = false
        duck = 1f
        this.output = output ?: OUTPUT_SOUND
        if (cues == null) return

        if (cues.any { it.kind == KIND_SPOKEN }) {
            speechCreated = true
            speech.setLanguage(languageTag)
        }
        setVolume(volume)
        // Los avisos hablados no tienen archivo; en «Solo vibración» no se carga audio.
        val assets = if (this.output == OUTPUT_VIBRATION) emptySet()
        else cues.filter { it.kind != KIND_SPOKEN }.map { it.assetKey }.toSet()
        preload = TimerBellPreload(assets, LEGACY_ASSET)
        for (asset in assets) loadTimerAsset(asset)
        enabled = timerEnabled
        handler.post(tick)
    }

    private fun createBell(): ExoPlayer = ExoPlayer.Builder(context).build().apply {
        setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).build(), false)
        setHandleAudioBecomingNoisy(true)
        setWakeMode(C.WAKE_MODE_LOCAL)
        volume = this@SessionBellPlayer.volume * duck
    }

    private fun loadTimerAsset(asset: String) {
        val bell = createBell()
        timerPlayers[asset] = bell
        bell.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying && activeBell === bell) markEndStarted()
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_READY && timerPlayers[asset] === bell) {
                    preload?.ready(asset)
                    notifyPrepared()
                }
                // La campana terminó completa: suena la siguiente de la fila.
                if (playbackState == Player.STATE_ENDED && activeBell === bell) {
                    activeBell = null
                    pendingEnd = false
                    queue.finished()
                    checkDrained()
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                if (timerPlayers[asset] !== bell) return
                Log.e("BELLS", "No se pudo cargar o tocar la campana", error)
                timerPlayers.remove(asset)
                if (activeBell === bell) {
                    activeBell = null
                    pendingEnd = false
                    queue.finished()
                }
                bell.release()
                preload?.failed(asset)?.let(::loadTimerAsset)
                notifyPrepared()
            }
        })
        prepare(bell, asset)
    }

    fun whenPrepared(action: () -> Unit) {
        onPrepared = action
        notifyPrepared()
    }

    private fun notifyPrepared() {
        if (preload?.settled == false) return
        val action = onPrepared
        onPrepared = null
        action?.invoke()
    }

    fun setEnabled(value: Boolean, volume: Float) {
        if (timerSchedule == null) {
            if (value) enableTrack(volume) else disable()
            return
        }
        if (timerStopped || enabled == value) return
        if (value) update()
        enabled = value
        if (value) setVolume(volume) else clearActiveBell()
    }

    fun stopAndReportEnd(): Boolean {
        val started = endStarted
        disable()
        return started
    }

    private fun prepare(bell: ExoPlayer, asset: String) {
        bell.setMediaItem(MediaItem.fromUri("asset:///flutter_assets/$asset"))
        bell.prepare()
    }

    private fun enableTrack(volume: Float) {
        if (enabled) return
        disable()
        enabled = true
        schedule.reset()
        setVolume(volume)
        timerStopped = false
        val bell = trackBell ?: createBell().also { trackBell = it }
        prepare(bell, LEGACY_ASSET)
        handler.post(tick)
    }

    fun setVolume(volume: Float) {
        this.volume = volume
        trackBell?.volume = volume
        for (bell in timerPlayers.values) bell.volume = volume * duck
    }

    /** Baja las campanas del temporizador (1 = volumen normal, 0.2 = agachado). */
    fun setDuck(factor: Float) {
        duck = factor
        for (bell in timerPlayers.values) bell.volume = volume * duck
    }

    fun disable() {
        onPrepared = null
        enabled = false
        timerStopped = true
        handler.removeCallbacks(tick)
        clearActiveBell()
        preload = null
        val players = timerPlayers.values.toList()
        timerPlayers.clear()
        for (bell in players) bell.release()
        trackBell?.stop()
        if (speechCreated) speech.stop()
        // Una espera de fin pendiente se descarta: quien apaga ya cerró la sesión.
        onDrained = null
        drain = null
    }

    fun reset() {
        schedule.reset()
        clearActiveBell()
        trackBell?.pause()
    }

    private fun clearActiveBell() {
        val previous = activeBell
        activeBell = null
        pendingEnd = false
        vibrationToken++
        vibrationPaused = false
        queue.clear()
        previous?.pause()
    }

    private fun markEndStarted() {
        if (!pendingEnd) return
        endStarted = true
        pendingEnd = false
    }

    /**
     * Empieza una campana de la fila. Devuelve true si sigue sonando y avisará
     * al terminar; false si fue instantánea (voz) o no se pudo tocar.
     */
    private fun startCue(cue: BellCue): Boolean {
        val isEnd = cue.kind == KIND_END
        // El respaldo se cancela ANTES del sonido: una campana larga no se encima con el aviso.
        if (isEnd) onEndCueStarted?.invoke()
        if (cue.kind == KIND_SPOKEN) {
            if (output != OUTPUT_VIBRATION) {
                speechCreated = true
                speech.speak(cue.assetKey.removePrefix("spoken:"))
            }
            return false
        }
        val vibrate = output == OUTPUT_VIBRATION || output == OUTPUT_SOUND_AND_VIBRATION
        // El fin «sonó» sólo si la salida elegida de verdad se dio (R109).
        val vibrated = vibrate && vibratePulse()
        if (output == OUTPUT_VIBRATION) {
            if (isEnd && vibrated) endStarted = true
            // Un pulso de 400 ms más 600 ms de pausa antes de la siguiente.
            scheduleVibrationSlot(cue)
            return true
        }
        val bell = timerPlayers[cue.assetKey] ?: timerPlayers[LEGACY_ASSET]
        if (bell == null || bell.playbackState == Player.STATE_IDLE) {
            if (isEnd && vibrated) endStarted = true
            return false
        }
        if (isEnd && vibrated) endStarted = true
        activeBell = bell
        pendingEnd = isEnd
        bell.seekTo(0)
        bell.play()
        if (bell.isPlaying) markEndStarted()
        return true
    }

    private fun scheduleVibrationSlot(cue: BellCue) {
        val token = ++vibrationToken
        handler.postDelayed({
            if (token == vibrationToken && queue.active === cue) {
                queue.finished()
                checkDrained()
            }
        }, VIBRATION_SLOT_MS)
    }

    /** Devuelve true sólo si el teléfono vibró de verdad. */
    private fun vibratePulse(): Boolean {
        try {
            val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                context.getSystemService(Vibrator::class.java)
            }
            if (vibrator == null || !vibrator.hasVibrator()) return false
            val effect = VibrationEffect.createOneShot(VIBRATION_PULSE_MS, VibrationEffect.DEFAULT_AMPLITUDE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                vibrator.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(
                    effect,
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_ALARM)
                        .build()
                )
            }
            return true
        } catch (error: Exception) {
            Log.e("BELLS", "No se pudo vibrar", error)
            return false
        }
    }

    /**
     * Al terminar el archivo: espera a que suene completa cada campana empezada
     * o pendiente (máximo 60 s) y luego ejecuta [action] una sola vez (R53).
     */
    fun drainThen(action: () -> Unit) {
        if (timerSchedule == null || timerStopped) {
            action()
            return
        }
        onDrained = action
        drain = TimerBellDrain().also { it.begin(SystemClock.elapsedRealtime()) }
        update()
    }

    private fun checkDrained() {
        val gate = drain ?: return
        if (!gate.ready(SystemClock.elapsedRealtime(), queue.busy)) return
        val action = onDrained
        onDrained = null
        drain = null
        action?.invoke()
    }

    private fun update() {
        val timer = timerSchedule
        if (timerStopped || (!enabled && timer == null)) return
        if (timer == null) {
            updateTrack()
            return
        }
        if (primary.playbackState == Player.STATE_ENDED) {
            // El archivo terminó: las campanas que tocaban siguen hasta el final.
            val due = timer.update(primary.currentPosition, enabled)
            if (due.isNotEmpty()) queue.offer(due)
            if (enabled && activeBell?.playbackState == Player.STATE_READY && activeBell?.isPlaying == false) {
                activeBell?.play()
            }
            checkDrained()
            return
        }
        if (!primary.isPlaying) {
            activeBell?.pause()
            if (!timerPaused) {
                // La pausa también calla la voz y detiene la fila de vibraciones (R106).
                timerPaused = true
                if (speechCreated) speech.stop()
                if (output == OUTPUT_VIBRATION && queue.active != null) {
                    vibrationToken++
                    vibrationPaused = true
                }
            }
            return
        }
        if (timerPaused) {
            timerPaused = false
            val active = queue.active
            if (vibrationPaused && active != null) scheduleVibrationSlot(active)
            vibrationPaused = false
        }
        val cues = timer.update(primary.currentPosition, enabled)
        if (cues.isNotEmpty()) {
            queue.offer(cues)
        } else if (enabled && activeBell?.playbackState == Player.STATE_READY) {
            activeBell?.play()
        }
    }

    private fun updateTrack() {
        val bell = trackBell ?: return
        if (!primary.isPlaying || primary.playbackState == Player.STATE_ENDED) {
            bell.pause()
            return
        }
        if (schedule.update(primary.currentPosition, primary.duration, primary.playbackParameters.speed.toDouble())) {
            bell.seekTo(0)
            if (bell.playbackState == Player.STATE_IDLE) bell.prepare()
            bell.play()
        } else if (bell.playbackState == Player.STATE_READY && bell.currentPosition > 0) {
            bell.play()
        }
    }

    override fun onEvents(player: Player, events: Player.Events) { update() }

    override fun onPositionDiscontinuity(old: Player.PositionInfo, new: Player.PositionInfo, reason: Int) {
        if (reason == Player.DISCONTINUITY_REASON_AUTO_TRANSITION) schedule.reset()
        else if (reason == Player.DISCONTINUITY_REASON_SEEK) {
            val timer = timerSchedule
            if (timer == null) {
                trackBell?.pause()
                schedule.seek(new.positionMs, primary.duration, primary.playbackParameters.speed.toDouble())
            } else {
                clearActiveBell()
                timer.seek(new.positionMs)
            }
        }
        update()
    }

    fun release() {
        disable()
        primary.removeListener(this)
        trackBell?.release()
        if (speechCreated) speech.release()
    }
}

/** Avisa a la fila que una campana empezó; true si sigue sonando. */
internal interface TimerBellRinger {
    fun ring(cue: BellCue): Boolean
}

/**
 * Fila de campanas: una campana nunca corta a otra. Lo que toca mientras otra
 * suena espera y suena al terminar ella, en el orden en que llegó.
 */
internal class TimerBellQueue(private val ringer: TimerBellRinger) {
    private val waiting = ArrayDeque<BellCue>()

    var active: BellCue? = null
        private set

    val busy: Boolean get() = active != null || waiting.isNotEmpty()

    fun offer(cues: List<BellCue>) {
        waiting.addAll(cues)
        if (active == null) startNext()
    }

    /** La campana activa terminó completa. */
    fun finished() {
        active = null
        startNext()
    }

    fun clear() {
        waiting.clear()
        active = null
    }

    private fun startNext() {
        while (active == null && waiting.isNotEmpty()) {
            val cue = waiting.removeFirst()
            if (ringer.ring(cue)) active = cue
        }
    }
}

/** Espera al final del archivo: lista cuando no hay campanas o pasaron 60 s. */
internal class TimerBellDrain(private val timeoutMs: Long = 60_000L) {
    private var startedAt: Long? = null

    fun begin(nowMs: Long) {
        startedAt = nowMs
    }

    fun ready(nowMs: Long, busy: Boolean): Boolean {
        if (!busy) return true
        val started = startedAt ?: return true
        return nowMs - started >= timeoutMs
    }
}


/** Mantiene la precarga abierta si hay que cargar la campana de respaldo. */
internal class TimerBellPreload(assets: Set<String>, private val fallback: String) {
    private val pending = assets.toMutableSet()
    private var fallbackRequested = fallback in assets

    val settled: Boolean get() = pending.isEmpty()

    fun ready(asset: String) {
        pending.remove(asset)
    }

    fun failed(asset: String): String? {
        pending.remove(asset)
        if (fallbackRequested) return null
        fallbackRequested = true
        pending.add(fallback)
        return fallback
    }
}
