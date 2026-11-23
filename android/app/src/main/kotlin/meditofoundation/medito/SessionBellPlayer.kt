@file:androidx.media3.common.util.UnstableApi
package meditofoundation.medito

import android.content.Context
import android.os.Handler
import android.os.Looper
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
    private var enabled = false
    private val tick = object : Runnable {
        override fun run() {
            update()
            if (!timerStopped && (enabled || timerSchedule != null)) handler.postDelayed(this, 100)
        }
    }

    init { primary.addListener(this) }

    fun configure(cues: List<BellCue>?, timerEnabled: Boolean, volume: Float) {
        if (cues == null && timerSchedule == null) return
        disable()
        timerSchedule = cues?.let(::TimerBellSchedule)
        endStarted = false
        timerStopped = false
        if (cues == null) return

        setVolume(volume)
        val assets = cues.map { it.assetKey }.toSet()
        preload = TimerBellPreload(assets, LEGACY_ASSET)
        for (asset in assets) loadTimerAsset(asset)
        enabled = timerEnabled
        handler.post(tick)
    }

    private fun createBell(): ExoPlayer = ExoPlayer.Builder(context).build().apply {
        setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).build(), false)
        setHandleAudioBecomingNoisy(true)
        setWakeMode(C.WAKE_MODE_LOCAL)
        volume = this@SessionBellPlayer.volume
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
            }

            override fun onPlayerError(error: PlaybackException) {
                if (timerPlayers[asset] !== bell) return
                Log.e("BELLS", "No se pudo cargar o tocar la campana", error)
                timerPlayers.remove(asset)
                if (activeBell === bell) clearActiveBell()
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
        for (bell in timerPlayers.values) bell.volume = volume
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
        previous?.pause()
    }

    private fun markEndStarted() {
        if (!pendingEnd) return
        endStarted = true
        pendingEnd = false
    }

    private fun ringTimer(cue: BellCue) {
        clearActiveBell()
        val bell = timerPlayers[cue.assetKey] ?: timerPlayers[LEGACY_ASSET] ?: return
        if (bell.playbackState == Player.STATE_IDLE) return
        activeBell = bell
        pendingEnd = cue.kind == "end"
        bell.seekTo(0)
        bell.play()
        if (bell.isPlaying) markEndStarted()
    }

    private fun update() {
        val timer = timerSchedule
        if (timerStopped || (!enabled && timer == null)) return
        if (timer == null) {
            updateTrack()
            return
        }
        if (primary.playbackState == Player.STATE_ENDED) {
            clearActiveBell()
            return
        }
        if (!primary.isPlaying) {
            activeBell?.pause()
            return
        }
        val cue = timer.update(primary.currentPosition, enabled)
        if (cue != null) {
            ringTimer(cue)
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
