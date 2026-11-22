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

/** Native scheduling continues with the screen locked, without a Dart timer. */
internal class SessionBellPlayer(context: Context, private val primary: Player) : Player.Listener {
    companion object { const val URI = "medito://session-bells" }
    private val handler = Handler(Looper.getMainLooper())
    private val schedule = SessionBellSchedule()
    private var timerSchedule: TimerBellSchedule? = null
    private var endOffsetMs: Long? = null
    private var endStarted = false
    private var pendingEnd = false
    private var timerStopped = false
    private var onPrepared: (() -> Unit)? = null
    private val bell = ExoPlayer.Builder(context).build().apply {
        setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).build(), false)
        setHandleAudioBecomingNoisy(true)
        setWakeMode(C.WAKE_MODE_LOCAL)
        addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying && pendingEnd) {
                    endStarted = true
                    pendingEnd = false
                }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_READY) notifyPrepared()
            }

            override fun onPlayerError(error: PlaybackException) {
                Log.e("BELLS", "Bell playback failed", error)
                notifyPrepared()
            }
        })
    }
    private var enabled = false
    private val tick = object : Runnable {
        override fun run() {
            update()
            if (!timerStopped && (enabled || timerSchedule != null)) handler.postDelayed(this, 100)
        }
    }

    init { primary.addListener(this) }

    fun configure(
        offsetsMs: List<Long>?,
        endOffsetMs: Long?,
        timerEnabled: Boolean,
        volume: Float
    ) {
        if (offsetsMs == null && timerSchedule == null) return
        disable()
        timerSchedule = offsetsMs?.let(::TimerBellSchedule)
        this.endOffsetMs = endOffsetMs
        endStarted = false
        timerStopped = false
        if (offsetsMs != null) {
            bell.volume = volume
            prepareBell()
            enabled = timerEnabled
            handler.post(tick)
        }
    }

    fun whenPrepared(action: () -> Unit) {
        if (bell.playbackState == Player.STATE_READY || bell.playerError != null) {
            action()
        } else {
            onPrepared = action
        }
    }

    private fun notifyPrepared() {
        val action = onPrepared
        onPrepared = null
        action?.invoke()
    }

    fun setEnabled(value: Boolean, volume: Float) {
        if (timerSchedule == null) {
            if (value) enable(volume) else disable()
            return
        }
        if (timerStopped || enabled == value) return
        if (value) update()
        enabled = value
        if (value) {
            bell.volume = volume
            if (bell.playbackState == Player.STATE_IDLE) prepareBell()
        } else {
            pendingEnd = false
            bell.pause()
            bell.seekTo(0)
        }
    }

    fun stopAndReportEnd(): Boolean {
        val started = endStarted
        disable()
        return started
    }

    private fun prepareBell() {
        bell.setMediaItem(MediaItem.fromUri("asset:///flutter_assets/assets/audio/session_bell_v2.wav"))
        bell.prepare()
    }

    private fun enable(volume: Float) {
        if (enabled) return
        disable()
        enabled = true
        schedule.reset()
        bell.volume = volume
        timerStopped = false
        prepareBell()
        handler.post(tick)
    }

    fun setVolume(volume: Float) { bell.volume = volume }

    fun disable() {
        onPrepared = null
        enabled = false
        timerStopped = true
        pendingEnd = false
        handler.removeCallbacks(tick)
        bell.stop()
    }

    fun reset() {
        schedule.reset()
        bell.pause()
    }

    private fun ring(isEnd: Boolean) {
        pendingEnd = isEnd
        bell.seekTo(0)
        if (bell.playbackState == Player.STATE_IDLE) bell.prepare()
        bell.play()
        if (pendingEnd && bell.isPlaying) {
            endStarted = true
            pendingEnd = false
        }
    }

    private fun update() {
        val timer = timerSchedule
        if (timerStopped || (!enabled && timer == null)) return
        if (primary.playbackState == Player.STATE_ENDED) {
            bell.pause()
            return
        }
        if (!primary.isPlaying) { bell.pause(); return }
        val timerCue = timer?.update(primary.currentPosition, enabled)
        if (timerCue != null) {
            ring(timerCue == endOffsetMs)
        } else if (timer == null && schedule.update(primary.currentPosition, primary.duration, primary.playbackParameters.speed.toDouble())) {
            ring(false)
        } else if (enabled && bell.playbackState == Player.STATE_READY && bell.currentPosition > 0) {
            bell.play()
        }
    }

    override fun onEvents(player: Player, events: Player.Events) { update() }

    override fun onPositionDiscontinuity(old: Player.PositionInfo, new: Player.PositionInfo, reason: Int) {
        if (reason == Player.DISCONTINUITY_REASON_AUTO_TRANSITION) schedule.reset()
        else if (reason == Player.DISCONTINUITY_REASON_SEEK) {
            pendingEnd = false
            bell.pause()
            val timer = timerSchedule
            if (timer == null) {
                schedule.seek(new.positionMs, primary.duration, primary.playbackParameters.speed.toDouble())
            } else {
                timer.seek(new.positionMs)
            }
        }
        update()
    }

    fun release() {
        disable()
        primary.removeListener(this)
        bell.release()
    }
}
