@file:UnstableApi

package meditofoundation.medito

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.IntentCompat
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.util.NotificationUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionCommands
import androidx.media3.session.SessionResult
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import androidx.media3.session.MediaStyleNotificationHelper
import io.flutter.embedding.engine.FlutterEngineCache
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.SupervisorJob
import android.media.AudioManager
import android.media.AudioFocusRequest
import android.content.Context
import android.os.Binder
import android.os.IBinder
import android.content.pm.ServiceInfo
import android.os.Build
import android.app.ForegroundServiceStartNotAllowedException
import android.app.PendingIntent
import android.view.KeyEvent
import meditofoundation.medito.pigeon.*

@UnstableApi
class AudioPlayerService : MediaSessionService(), Player.Listener, MeditoAudioServiceApi {

    // Inner class that allows binding to this service
    inner class LocalBinder : Binder() {
        val service: AudioPlayerService
            get() = this@AudioPlayerService
    }
    
    private val binder = LocalBinder()
    private lateinit var notification: Notification
    private var backgroundMusicVolume: Float = 0.0F
    private var backgroundSoundUri: String? = null
    private lateinit var primaryPlayer: ExoPlayer
    private lateinit var backgroundMusicPlayer: ExoPlayer
    private lateinit var sessionBells: SessionBellPlayer
    private var primaryMediaSession: MediaSession? = null
    private var timerRegisteredSession: MediaSession? = null
    private var meditoAudioApi: MeditoAudioServiceCallbackApi? = null
    private var timerSeed: Long? = null
    private var timerStopLabel: String? = null
    private var timerHasExtraTime = false
    // Parámetros de la sesión de temporizador actual; null en sesiones guiadas.
    private var timerParams: TimerSessionParams? = null
    private var focusPolicy: TimerFocusPolicy? = null
    // Pausa puesta por la política de foco (llamada, otra app): no suelta el foco.
    private var pausedByPolicy = false
    private var duckFactor = 1f
    private var lastClockPhase = -1
    // Intervalo entre fotos del registro con el reloj desde el arranque (REV-04).
    private val storeThrottle = TimerStoreThrottle(STORE_WRITE_INTERVAL_MS, ElapsedClock { SystemClock.elapsedRealtime() })
    // Número de foto del registro, tomado en el evento (R108).
    private var snapshotSeq = 0L
    // El último pedido de foco quedó en espera (llamada en curso).
    private var focusDelayed = false
    // Cierre natural que falló y se reintenta al terminar las campanas.
    private var naturalCloseRetry: (() -> TimerCloseResult)? = null
    private var timerEndPassed = false
    private var backgroundFadeJob: Job? = null
    private val focus by lazy { TimerAudioFocus(AndroidFocusBackend()) }
    private val runStore by lazy { TimerRunStore.forContext(this) }
    private val endBackup by lazy { TimerEndBackup.scheduler(this) }
    private var lastTimerStop: Pair<Long, TimerStopReport>? = null
    private var playbackAttempt = 0L
    private var timerPlaybackStopped = false
    private var pendingTimerBellCues: List<BellCue>? = null
    private val timerStart = TimerStartGate()
    private var pendingTimerBellsEnabled = false
    private var isCompletionHandled = false
    private var isServiceFullyInitialized = false
    private lateinit var audioManager: AudioManager
    private var currentRepeatMode: RepeatMode = RepeatMode.NONE

    // Full play-throughs of the current track, counting repeats. The first is
    // recorded as the session; each later one only adds its listening time.
    private var completedPlaythroughs = 0

    // Result callback when service is ready
    private var readinessCallback: ((Boolean) -> Unit)? = null

    private val serviceJob = SupervisorJob()
    private val serviceScope = CoroutineScope(Dispatchers.Main + serviceJob)
    private val backgroundScope = CoroutineScope(Dispatchers.Default + serviceJob)
    private var positionUpdateJob: Job? = null
    private val fadeOutDurationMillis = 10000
    private val handler = Handler(Looper.myLooper() ?: Looper.getMainLooper())
    @Volatile
    private var isUpdatingPlaybackState = false

    private fun startPositionUpdates() {
        positionUpdateJob?.cancel()
        positionUpdateJob = backgroundScope.launch {
            while (isActive) {
                updatePlaybackState()
                delay(1000) // 1 second interval
            }
        }
    }

    private fun stopPositionUpdates() {
        positionUpdateJob?.cancel()
    }

    private suspend fun updatePlaybackState() {
        if (!::primaryPlayer.isInitialized) return
        
        // Skip if previous update is still in progress to prevent accumulation
        if (isUpdatingPlaybackState) {
            return
        }

        try {
            isUpdatingPlaybackState = true
            
            // ExoPlayer methods should be called on main thread for thread safety.
            // Posición, sesión e intento se toman JUNTOS (R104): un evento de otra
            // sesión nunca toca el respaldo ni el registro de la nueva.
            val snapshot = withContext(Dispatchers.Main) {
                if (!::primaryPlayer.isInitialized) return@withContext null
                val attempt = playbackAttempt
                val state = PlaybackState(
                    isPlaying = primaryPlayer.isPlaying,
                    position = primaryPlayer.currentPosition,
                    volume = primaryPlayer.volume.toLong(),
                    speed = Speed(primaryPlayer.playbackParameters.speed.toDouble()),
                    isBuffering = primaryPlayer.playbackState == Player.STATE_BUFFERING,
                    duration = primaryPlayer.duration,
                    isSeeking = primaryPlayer.playbackState == Player.STATE_BUFFERING,
                    isCompleted = false, // Completion is emitted by the native listener.
                    track = trackFromCurrentMediaItem(),
                    endCueRang = timerEndCueRang(),
                    runId = timerParams?.runId,
                    waitingForFocus = timerWaitingForFocus()
                )
                // Apply background sound volume on main thread (touches ExoPlayer)
                applyBackgroundSoundVolume(state.duration, state.position)
                Triple(state, timerTick(state.position), attempt)
            } ?: return
            val (state, storeWrite, attempt) = snapshot
            storeWrite?.invoke()

            // Pigeon channel communication - already async/non-blocking
            // Post to main thread handler to ensure thread safety for callback
            val api = meditoAudioApi
            if (api != null) {
                handler.post {
                    if (attempt != playbackAttempt) return@post
                    api.updatePlaybackState(state) {
                        if (state.isCompleted && !isCompletionHandled) {
                            isCompletionHandled = true
                            handleTrackCompletion(state)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error updating playback state: ${e.message}")
        } finally {
            isUpdatingPlaybackState = false
        }
    }

    private fun trackFromCurrentMediaItem(): Track {
        return primaryPlayer.currentMediaItem?.let { mediaItem ->
            Track(
                id = mediaItem.mediaId,
                title = mediaItem.mediaMetadata.title?.toString() ?: "",
                fileId = mediaItem.mediaMetadata.extras?.getString(KEY_FILE_ID) ?: "",
                description = mediaItem.mediaMetadata.description?.toString() ?: "",
                imageUrl = mediaItem.mediaMetadata.artworkUri?.toString() ?: "",
                artist = mediaItem.mediaMetadata.artist?.toString() ?: "",
                artistUrl = mediaItem.mediaMetadata.extras?.getString(KEY_ARTIST_URL),
            )
        } ?: Track(id = "", title = "", fileId = "", description = "", imageUrl = "", artist = null, artistUrl = null)
    }

    // Sends the terminal isCompleted=true PlaybackState to Dart. Called from the
    // native STATE_ENDED handler on the main thread, before finishPlayback()
    // cancels the position poll — the poll would otherwise be the only sender of
    // isCompleted and it never gets to run once the track ends.
    private fun pushCompletedStateToDart() {
        if (!::primaryPlayer.isInitialized) return
        val api = meditoAudioApi ?: return

        // Fall back to the playhead if ExoPlayer never resolved a duration —
        // position must stay > 5s or PlayerView's end-screen guard rejects it.
        val duration = primaryPlayer.duration.takeIf { it != C.TIME_UNSET }
            ?: primaryPlayer.currentPosition
        val state = PlaybackState(
            isPlaying = false,
            position = duration,
            volume = primaryPlayer.volume.toLong(),
            speed = Speed(primaryPlayer.playbackParameters.speed.toDouble()),
            isBuffering = false,
            duration = duration,
            isSeeking = false,
            isCompleted = true,
            track = trackFromCurrentMediaItem(),
            endCueRang = timerEndCueRang(),
            runId = timerParams?.runId
        )

        api.updatePlaybackState(state) { /* fire-and-forget */ }
    }

    /**
     * Sólo en temporizadores: el reloj está listo pero espera el foco de audio
     * (llamada o foco en espera). Dart no cuenta el plazo de inicio mientras
     * tanto (REV-06).
     */
    private fun timerWaitingForFocus(): Boolean? =
        if (timerSeed != null) pausedByPolicy && !primaryPlayer.isPlaying else null

    // Sólo en temporizadores: si la campana final de verdad empezó a sonar (R98).
    private fun timerEndCueRang(): Boolean? =
        if (timerSeed != null && ::sessionBells.isInitialized) sessionBells.endCueStarted else null

    private fun handleTrackCompletion(state: PlaybackState) {
        val completionData = createCompletionData(state)
        saveAndSendCompletionData(completionData)
    }

    private fun createCompletionData(state: PlaybackState): CompletionData {
        return CompletionData(
            trackId = state.track.id,
            duration = state.duration,
            fileId = state.track.fileId,
            guideId = state.track.artist,
            timestamp = System.currentTimeMillis()
        )
    }

    // Records one finished play-through. `isTerminal` is false at a repeat
    // boundary (playback continues), so the service must not be torn down.
    private fun recordPlaythroughFromPlayer(isTerminal: Boolean) {
        completedPlaythroughs++
        val completionData = createCompletionDataFromPlayer()
        if (completedPlaythroughs == 1) {
            saveAndSendCompletionData(completionData, finish = isTerminal)
        } else {
            saveAndSendRepeatPlaythrough(completionData)
            if (isTerminal) finishPlayback()
        }
    }

    private var playbackGeneration = -1L

    private fun saveAndSendRepeatPlaythrough(completionData: CompletionData) {
        // Persisted like a completion so MainActivity replays it if Dart
        // doesn't acknowledge (engine frozen or killed).
        val generation = playbackGeneration
        if (!SharedPreferencesManager.addPendingRepeat(this, completionData, generation)) return
        CoroutineScope(Dispatchers.Main).launch {
            if (!SharedPreferencesManager.isCurrent(generation)) return@launch
            meditoAudioApi?.handleRepeatPlaythrough(completionData) { result ->
                if (result.getOrNull() == true) {
                    SharedPreferencesManager.removePendingRepeat(this@AudioPlayerService, completionData, generation)
                }
            }
        }
    }

    // Builds completion data directly from the player. Used by the native
    // STATE_ENDED handler, which must not depend on a Dart-provided PlaybackState.
    private fun createCompletionDataFromPlayer(): CompletionData {
        val mediaItem = primaryPlayer.currentMediaItem
        val metadata = mediaItem?.mediaMetadata
        return CompletionData(
            trackId = mediaItem?.mediaId ?: "",
            duration = primaryPlayer.duration.takeIf { it != C.TIME_UNSET } ?: 0L,
            fileId = metadata?.extras?.getString(KEY_FILE_ID) ?: "",
            guideId = metadata?.artist?.toString(),
            timestamp = System.currentTimeMillis()
        )
    }

    private fun saveAndSendCompletionData(completionData: CompletionData, finish: Boolean = true) {
        // Persist first: completion is replayed by MainActivity on next launch if
        // the app is killed before Dart records it, so nothing is lost.
        val generation = playbackGeneration
        val saved = SharedPreferencesManager.saveCompletionData(this, completionData, generation)

        // Tear down the foreground service + notification immediately and natively.
        // Teardown must NOT depend on the Dart reply below — on devices that freeze
        // the app in the background (e.g. MIUI/Xiaomi) the reply may never arrive,
        // which previously left the player notification stuck until reboot.
        if (finish) finishPlayback()
        if (!saved) return

        // Fire-and-forget the analytics callback. If it completes we can clear the
        // persisted record; if it doesn't, the replay path handles it next launch.
        CoroutineScope(Dispatchers.Main).launch {
            if (!SharedPreferencesManager.isCurrent(generation)) return@launch
            meditoAudioApi?.handleCompletedTrack(completionData) { result ->
                if (result.getOrNull() == true) {
                    SharedPreferencesManager.clearCompletionData(this@AudioPlayerService, completionData, generation)
                }
            }
        }
    }

    private fun finishPlayback() {
        stopPositionUpdates()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun applyBackgroundSoundVolume(trackDuration: Long, currentPosition: Long) {
        try {
            // Only apply fade if background sound is set, initialized, and volume is set
            if (backgroundSoundUri == null || 
                !::backgroundMusicPlayer.isInitialized || 
                backgroundMusicVolume <= 0.0F ||
                backgroundFadeJob?.isActive == true) {
                return
            }

            val params = timerParams.takeIf { timerSeed != null }
            if (params != null && params.isPlainCountdown && trackDuration != C.TIME_UNSET &&
                trackDuration > params.endMs
            ) {
                // Cuenta regresiva simple: se apaga en la cola final, desde el fin planeado.
                val window = (trackDuration - params.endMs).toFloat()
                val fraction = ((trackDuration - currentPosition).toFloat() / window).coerceIn(0f, 1f)
                backgroundMusicPlayer.volume = backgroundMusicVolume * fraction * duckFactor
            } else if (trackDuration != C.TIME_UNSET &&
                trackDuration - currentPosition <= fadeOutDurationMillis &&
                trackDuration > fadeOutDurationMillis
            ) {
                val volumeFraction =
                    (trackDuration - currentPosition).toFloat() / fadeOutDurationMillis
                backgroundMusicPlayer.volume =
                    backgroundMusicVolume * volumeFraction * duckFactor
            } else {
                backgroundMusicPlayer.volume = backgroundMusicVolume * duckFactor
            }
        } catch (e: Exception) {
            e.printStackTrace()
            // Default to the set volume if there's an error
            if (::backgroundMusicPlayer.isInitialized) {
                backgroundMusicPlayer.volume = backgroundMusicVolume
            }
        }
    }

    private var playbackState: PlaybackState? = null

    private fun createMeditationAudioAttributes(): AudioAttributes {
        return AudioAttributes.Builder()
            .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
            .setUsage(C.USAGE_MEDIA)
            .build()
    }

    private fun createBackgroundAudioAttributes(): AudioAttributes {
        return AudioAttributes.Builder()
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .setUsage(C.USAGE_GAME)
            .build()
    }

    private fun createLoadControl(): DefaultLoadControl {
        return DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                DefaultLoadControl.DEFAULT_MIN_BUFFER_MS,
                DefaultLoadControl.DEFAULT_MAX_BUFFER_MS,
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_MS,
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS
            )
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
    }

    private fun createPrimaryMediaSourceFactory(): DefaultMediaSourceFactory {
        val httpDataSourceFactory = DefaultHttpDataSource.Factory()
            .setUserAgent("Medito-Android")
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(30_000)
            .setAllowCrossProtocolRedirects(true)

        return DefaultMediaSourceFactory(this)
            .setDataSourceFactory(DefaultDataSource.Factory(this, httpDataSourceFactory))
    }

    private fun createMediaSession(): MediaSession {
        val player = object : ForwardingPlayer(primaryPlayer) {
            override fun play() {
                if (timerSeed != null) userResumeTimer() else super.play()
            }

            override fun pause() {
                if (timerSeed != null) userPauseTimer() else super.pause()
            }

            override fun setPlayWhenReady(playWhenReady: Boolean) {
                if (timerSeed == null) {
                    super.setPlayWhenReady(playWhenReady)
                } else if (playWhenReady) {
                    userResumeTimer()
                } else {
                    userPauseTimer()
                }
            }

            override fun setPlaybackParameters(playbackParameters: PlaybackParameters) {
                if (timerSeed == null) super.setPlaybackParameters(playbackParameters)
            }

            override fun setPlaybackSpeed(speed: Float) {
                if (timerSeed == null) super.setPlaybackSpeed(speed)
            }

            override fun stop() {
                if (timerSeed != null) requestSystemTimerStop() else super.stop()
            }
        }
        return MediaSession.Builder(this, player)
            .setId("MeditoAudioSession_${System.currentTimeMillis()}")
            .setCustomLayout(timerStopLayout())
            .setCallback(object : MediaSession.Callback {
                override fun onConnect(
                    session: MediaSession,
                    controller: MediaSession.ControllerInfo
                ): MediaSession.ConnectionResult {
                    return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                        .setAvailablePlayerCommands(mediaPlayerCommands())
                        .setAvailableSessionCommands(mediaSessionCommands())
                        .setCustomLayout(timerStopLayout())
                        .build()
                }

                override fun onPostConnect(
                    session: MediaSession,
                    controller: MediaSession.ControllerInfo
                ) {
                    if (timerSeed != null && session.mediaNotificationControllerInfo == controller) {
                        applyTimerNotificationControls(session, controller)
                    }
                }

                override fun onCustomCommand(
                    session: MediaSession,
                    controller: MediaSession.ControllerInfo,
                    customCommand: SessionCommand,
                    args: Bundle
                ): ListenableFuture<SessionResult> {
                    val result = when {
                        customCommand != timerStopCommand() -> SessionResult.RESULT_ERROR_NOT_SUPPORTED
                        requestSystemTimerStop() -> SessionResult.RESULT_SUCCESS
                        else -> SessionResult.RESULT_ERROR_UNKNOWN
                    }
                    return Futures.immediateFuture(SessionResult(result))
                }

                override fun onMediaButtonEvent(
                    session: MediaSession,
                    controllerInfo: MediaSession.ControllerInfo,
                    intent: Intent
                ): Boolean {
                    val event = IntentCompat.getParcelableExtra(
                        intent, Intent.EXTRA_KEY_EVENT, KeyEvent::class.java
                    ) ?: return false
                    if (event.keyCode == KeyEvent.KEYCODE_MEDIA_STOP && timerSeed != null) {
                        if (event.action == KeyEvent.ACTION_DOWN) requestSystemTimerStop()
                        return true
                    }
                    // Ningún temporizador acepta saltos ni adelantos (UX-13).
                    return timerSeed != null && event.keyCode in timerBlockedKeys
                }

                override fun onPlayerCommandRequest(
                    session: MediaSession,
                    controller: MediaSession.ControllerInfo,
                    playerCommand: Int
                ): Int {
                    if (!TimerMediaCommands.allows(timerSeed != null, playerCommand)) {
                        return SessionResult.RESULT_ERROR_NOT_SUPPORTED
                    }
                    return SessionResult.RESULT_SUCCESS
                }
            })
            .build()
    }

    private fun timerStopCommand(): SessionCommand? {
        val seed = timerSeed ?: return null
        if (timerStopLabel == null) return null
        return SessionCommand("$ACTION_TIMER_STOP/$seed", Bundle.EMPTY)
    }

    private fun timerStopLayout(): List<CommandButton> {
        val label = timerStopLabel ?: return emptyList()
        val command = timerStopCommand() ?: return emptyList()
        return listOf(
            CommandButton.Builder(CommandButton.ICON_STOP)
                .setSessionCommand(command)
                .setDisplayName(label)
                .build()
        )
    }

    private fun mediaPlayerCommands(): Player.Commands =
        if (timerSeed != null) Player.Commands.Builder()
            .addAll(*TimerMediaCommands.timer.toIntArray())
            .build()
        else MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS

    private fun mediaSessionCommands(): SessionCommands {
        val defaults = MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS
        val stop = timerStopCommand() ?: return defaults
        return defaults.buildUpon().add(stop).build()
    }

    private fun updateTimerMediaControls(session: MediaSession) {
        if (timerSeed != null && !isSessionAdded(session)) {
            // La reproducción desde Flutter no pasa por onGetSession.
            // El registro conecta el controlador que publica los comandos de Android.
            timerRegisteredSession = session
            addSession(session)
        }

        val notificationController = session.mediaNotificationControllerInfo
        val playerCommands = mediaPlayerCommands()
        val sessionCommands = mediaSessionCommands()
        for (controller in session.connectedControllers) {
            if (controller != notificationController) {
                session.setAvailableCommands(controller, sessionCommands, playerCommands)
            }
        }
        session.setCustomLayout(timerStopLayout())
        notificationController?.let { applyTimerNotificationControls(session, it) }

        if (timerSeed == null && timerRegisteredSession === session) {
            if (isSessionAdded(session)) removeSession(session)
            timerRegisteredSession = null
        }
    }

    private fun applyTimerNotificationControls(
        session: MediaSession,
        controller: MediaSession.ControllerInfo
    ) {
        session.setAvailableCommands(controller, mediaSessionCommands(), mediaPlayerCommands())
        // Media3 actualiza el PlaybackState de Android al aplicar este diseño al controlador.
        session.setCustomLayout(controller, timerStopLayout())
    }

    override fun onUpdateNotification(session: MediaSession, startInForegroundRequired: Boolean) {
        // El servicio publica la notificación del temporizador con sus propias acciones.
        if (timerSeed != null || timerRegisteredSession === session) return
        super.onUpdateNotification(session, startInForegroundRequired)
    }

    override fun onCreate() {
        super.onCreate()
        println("🔊 [AudioPlayerService] onCreate called")
        Log.d(TAG, "🔊 Service onCreate called")
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        isActive = true
        backupRescheduleHook = { rescheduleBackupFromPlayer() }

        // Flutter Engine and API setup is handled in onStartCommand

        try {
            primaryPlayer = ExoPlayer.Builder(this)
                .setAudioAttributes(
                    createMeditationAudioAttributes(),
                    false
                )  // Don't handle focus automatically
                .setHandleAudioBecomingNoisy(true)
                .setWakeMode(C.WAKE_MODE_NETWORK)
                .setLoadControl(createLoadControl())
                .setMediaSourceFactory(createPrimaryMediaSourceFactory())
                .build().apply {
                    addListener(object : Player.Listener {
                        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                            if (playWhenReady) {
                                Log.d(
                                    TAG,
                                    "🔊 Player set to playWhenReady=true, requesting audio focus"
                                )
                                requestAudioFocus()

                                // 👉 Sync background to resume
                                if (backgroundSoundUri != null && !backgroundMusicPlayer.isPlaying &&
                                    backgroundFadeJob?.isActive != true) {
                                    Log.d(
                                        TAG,
                                        "🔊 Resuming background sound from playWhenReadyChanged"
                                    )
                                    playBackgroundSound()
                                }
                            } else {
                                Log.d(
                                    TAG,
                                    "🔊 Player set to playWhenReady=false, abandoning audio focus"
                                )
                                if (timerSeed != null &&
                                    reason == Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY
                                ) {
                                    // Se desconectaron los audífonos: pausa de la persona, con aviso (D2).
                                    focusPolicy?.onUserPause()
                                    timerStart.pause()
                                    pausedByPolicy = false
                                    postTimerAlert(timerParams?.headphonesPausedText)
                                }
                                // Una pausa de la política (llamada, otra app) conserva el foco.
                                if (!pausedByPolicy) abandonAudioFocus()
                                if (timerSeed != null) onTimerPaused()

                                // 👉 Sync background to pause
                                if (backgroundMusicPlayer.isPlaying && backgroundFadeJob?.isActive != true) {
                                    Log.d(
                                        TAG,
                                        "🔊 Pausing background sound from playWhenReadyChanged"
                                    )
                                    backgroundMusicPlayer.pause()
                                }
                            }
                        }
                    })
                }
            Log.d(TAG, "🔊 Primary player initialized successfully")

            backgroundMusicPlayer = ExoPlayer.Builder(this)
                .setAudioAttributes(
                    createBackgroundAudioAttributes(),
                    false
                )  // Don't handle focus automatically
                .setHandleAudioBecomingNoisy(false)  // Don't respond to headphones disconnection
                .setWakeMode(C.WAKE_MODE_LOCAL)
                .setLoadControl(createLoadControl())
                .build()
            Log.d(TAG, "🔊 Background music player initialized successfully")

            sessionBells = SessionBellPlayer(this, primaryPlayer)
            sessionBells.onEndCueStarted = { markTimerEndPassed() }
            primaryPlayer.addListener(this)

            primaryMediaSession = createMediaSession()
            Log.d(TAG, "🔊 Media session created successfully")
            
            // Mark service as fully initialized
            isServiceFullyInitialized = true
            
            // Notify any waiting callbacks that service is ready
            readinessCallback?.invoke(true)
            readinessCallback = null
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error initializing players: ${e.message}")
            e.printStackTrace()
            
            // Notify any waiting callbacks of failure
            readinessCallback?.invoke(false)
            readinessCallback = null
        }
        println("🔊 [AudioPlayerService] onCreate finished")
    }

    override fun onDestroy() {
        timerStart.cancel()
        Log.d(TAG, "🔊 Service onDestroy called")
        isActive = false
        backupRescheduleHook = null
        // La sesión murió con el servicio: sin aviso de respaldo y sin «No molestar».
        if (timerSeed != null) {
            cancelTimerBackup()
            TimerEndBackup.markEnded(this, timerParams?.runId)
        }
        currentRunId = null
        dndOwnerId = null
        DndGuard.restore(this)

        // Always remove the foreground notification on teardown, even when the
        // service dies via a path that didn't call finishPlayback()/stopAudio()
        // (e.g. the OS killing a background-frozen service). Without this an
        // orphaned, un-dismissable media notification could linger until reboot.
        try {
            clearNotification()
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error clearing notification in onDestroy: ${e.message}")
        }

        // First, ensure we've released audio focus
        if (focus.isHeld) {
            Log.d(TAG, "🔊 Abandoning audio focus on destroy")
            abandonAudioFocus()
        }

        // Cancel any pending coroutines
        serviceJob.cancel()
        stopPositionUpdates()

        // Clean up on the main thread to avoid threading issues
        handler.post {
            try {
                Log.d(TAG, "🔊 Removing callbacks and stopping players")
                
                if (::sessionBells.isInitialized) sessionBells.release()
                if (::primaryPlayer.isInitialized) {
                    primaryPlayer.stop()
                    primaryPlayer.removeListener(this@AudioPlayerService)
                    primaryPlayer.release()
                }

                if (::backgroundMusicPlayer.isInitialized) {
                    backgroundMusicPlayer.stop()
                    backgroundMusicPlayer.release()
                }

                primaryMediaSession?.run {
                    player.release()
                    release()
                    primaryMediaSession = null
                }

                Log.d(TAG, "🔊 Service cleanup completed")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error during service cleanup: ${e.message}")
                e.printStackTrace()
            }
        }

        super.onDestroy()
    }

    override fun onPlayerStateChanged(isPlaying: Boolean, playbackState: Int) {
        Log.d(TAG, "🔊 Player state changed: isPlaying=$isPlaying, state=$playbackState")

        // Update notification to reflect current state
        updateNotification()
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) {
        // El cronómetro de la notificación del temporizador se rehace al pausar y reanudar.
        if (timerSeed != null && !isCompletionHandled) updateNotification()
    }

    override fun onPlayerError(error: PlaybackException) {
        Log.e(TAG, "❌ Player error: ${error.errorCodeName} — ${error.message}", error)
        if (!::primaryPlayer.isInitialized) return
        val resumePos = primaryPlayer.currentPosition.takeIf { it > 0 } ?: 0L
        val duration = primaryPlayer.duration.takeIf { it != C.TIME_UNSET } ?: -1L
        val api = meditoAudioApi
        // El id se toma al ocurrir el error, no cuando se envía (R104).
        val errorRunId = timerParams?.runId.takeIf { timerSeed != null }
        if (api != null) {
            handler.post {
                api.reportPlayerError(
                    error.errorCodeName,
                    error.message ?: "unknown",
                    resumePos,
                    duration,
                    errorRunId,
                ) { /* fire-and-forget */ }
            }
        }
        primaryPlayer.prepare()
        if (resumePos > 0) primaryPlayer.seekTo(resumePos)
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
        Log.d(TAG, "🔊 Playback state changed: $playbackState")

        if (playbackState == Player.STATE_ENDED) {
            timerStart.cancel()
            // Drive completion + notification teardown natively and immediately.
            // This fires regardless of whether the Flutter engine is alive, unlike
            // the Dart-reply-gated poll path in updatePlaybackState(). Skipping the
            // updateNotification() below avoids re-posting the stuck "ended" card.
            if (!isCompletionHandled) {
                isCompletionHandled = true
                if (timerSeed != null) {
                    completeTimerNaturally()
                    return
                }
                // Push a final isCompleted=true state to Dart before teardown:
                // finishPlayback() cancels the position poll before it can observe
                // STATE_ENDED, and PlayerView opens the end screen off that flag.
                sessionBells.disable()
                pushCompletedStateToDart()
                recordPlaythroughFromPlayer(isTerminal = true)
                // La sesión guiada terminó: se quita el «No molestar» que puso el servicio.
                restoreDnd()
            }
            return
        }

        if (playbackState == Player.STATE_READY) {
            isCompletionHandled = false
            startPositionUpdates()
        }
        if (playbackState == Player.STATE_READY || playbackState == Player.STATE_IDLE) {
            syncBackgroundWithPrimaryState()
        }

        // Update notification to reflect current state
        updateNotification()
    }

    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
        // Repeat once plays a two-item playlist (AUTO advance between them);
        // repeat forever loops one item (REPEAT). Either way the previous
        // play-through finished in full.
        if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO ||
            reason == Player.MEDIA_ITEM_TRANSITION_REASON_REPEAT
        ) {
            recordPlaythroughFromPlayer(isTerminal = false)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Only stop service if not playing
        if (!primaryPlayer.isPlaying) {
            // Temporizador en pausa y app cerrada: cierre del sistema que guarda el tiempo.
            if (timerSeed != null) requestSystemTimerStop()
            serviceScope.launch {
                // Session analytics: the user swiped the app away while the
                // track was paused — i.e. abandoned it. Push one last position
                // snapshot to Dart before teardown so AudioSessionTracker has
                // the freshest position to attribute the audio_session_abandoned
                // event (fired in Dart, or replayed on next launch from the
                // persisted record). Skipped if the track already completed —
                // that path reports its own event. Mirrors how completion is
                // surfaced to Dart rather than firing Firebase from native code.
                if (!isCompletionHandled) {
                    try {
                        updatePlaybackState()
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Error pushing final playback state on task removal: ${e.message}")
                    }
                }
                stopPositionUpdates()
                clearNotification()
                resetPrimaryQueue()
                resetBackgroundQueue()
                DndGuard.restore(this@AudioPlayerService)
                dndOwnerId = null
                stopSelf()
            }
        }
    }

    override fun stopService(name: Intent?): Boolean {
        return super.stopService(name)
    }

    private fun clearNotification() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        publishNotification(null)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return primaryMediaSession
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "🔊 Service onStartCommand called with action: ${intent?.action}")

        // Recreado por START_STICKY tras morir el proceso: no hay sesión que seguir.
        // Se quita el «No molestar» que dejó la sesión muerta y el servicio se cierra.
        if (intent == null && timerSeed == null && primaryPlayerIdle()) {
            Log.d(TAG, "🔊 Servicio recreado sin sesión: se restaura «No molestar» y se detiene")
            DndGuard.restoreIfStale(this, null)
            stopSelf()
            return START_NOT_STICKY
        }
        
        // Handle media button actions from notification
        when (intent?.action) {
            ACTION_TIMER_STOP -> {
                if (::primaryPlayer.isInitialized &&
                    intent.getLongExtra(KEY_TIMER_SEED, 0L) == timerSeed) {
                    requestSystemTimerStop()
                }
                return START_NOT_STICKY
            }
            ACTION_PLAY_PAUSE -> {
                Log.d(TAG, "🔊 Handling play/pause action from notification")
                playPauseAudio()
                return START_STICKY
            }
            ACTION_SKIP_FORWARD -> {
                Log.d(TAG, "🔊 Handling skip forward action from notification")
                skip10SecondsForward()
                return START_STICKY
            }
            ACTION_SKIP_BACKWARD -> {
                Log.d(TAG, "🔊 Handling skip backward action from notification")
                skip10SecondsBackward()
                return START_STICKY
            }
        }
        
        // Create and show notification immediately
        try {
            val notification = createInitialNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            Log.d(TAG, "🔊 Started foreground service with initial notification")
        } catch (e: ForegroundServiceStartNotAllowedException) {
            // This exception only occurs on Android 12+ (API 31+) when trying to start
            // a foreground service from the background
            Log.e(TAG, "❌ ForegroundServiceStartNotAllowedException: ${e.message}")
            Log.w(TAG, "⚠️ Cannot start foreground service from background, stopping service")
            // Stop the service since we can't run as foreground
            stopSelf()
            return START_NOT_STICKY
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error starting foreground service: ${e.message}")
            e.printStackTrace()
            // Try to continue anyway if it's not a critical error
        }

        // Call super after starting foreground
        super.onStartCommand(intent, flags, startId)

        // Check for required permissions
        if (!hasRequiredPermissions()) {
            Log.e(TAG, "❌ Missing required permissions, stopping service")
            stopSelf()
            return START_NOT_STICKY
        }

        // Move initialization off main thread
        CoroutineScope(Dispatchers.Default).launch {
            try {
                FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)?.let { engine ->
                    Log.d(TAG, "🔊 Found Flutter engine in cache")
                    withContext(Dispatchers.Main) {
                        MeditoAudioServiceApi.setUp(
                            engine.dartExecutor.binaryMessenger,
                            this@AudioPlayerService
                        )
                        meditoAudioApi =
                            MeditoAudioServiceCallbackApi(engine.dartExecutor.binaryMessenger)
                        Log.d(TAG, "🔊 Set up API communication with Flutter")
                    }
                } ?: run {
                    Log.e(TAG, "❌ Flutter engine not found in cache!")
                }

                // Start position updates
                withContext(Dispatchers.Main) {
                    Log.d(TAG, "🔊 Starting position updates")
                    startPositionUpdates()
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error setting up service: ${e.message}")
                e.printStackTrace()
            }
        }

        return START_STICKY
    }

    private fun createInitialNotification(): Notification {
        val initialNotification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Intronauts")
            .setContentText("Preparing media playback...")
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
        return initialNotification
    }

    private fun hasRequiredPermissions(): Boolean {
        // Add any media playback related permission checks here
        // For example, checking audio focus permissions if needed
        return true
    }

    private fun buildPrimaryMediaItem(audioData: AudioData): MediaItem {
        return MediaItem.Builder()
            .setUri(audioData.url)
            .setMediaId(audioData.track.id)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(audioData.track.title)
                    .setArtist(audioData.track.artist)
                    .setDescription(audioData.track.description)
                    .setArtworkUri(audioData.track.imageUrl?.takeIf { it.isNotEmpty() }?.let { Uri.parse(it) })
                    .setExtras(android.os.Bundle().apply {
                        putString(KEY_ARTIST_URL, audioData.track.artistUrl)
                        putString(KEY_FILE_ID, audioData.track.fileId)
                    })
                    .build()
            )
            .build()
    }

    private fun resetPrimaryQueue() {
        primaryPlayer.stop()
        primaryPlayer.clearMediaItems()
    }

    private fun resetBackgroundQueue() {
        backgroundMusicPlayer.stop()
        backgroundMusicPlayer.clearMediaItems()
    }

    private fun configurePrimaryPlaylist(mediaItem: MediaItem, mode: RepeatMode) {
        when (mode) {
            RepeatMode.NONE -> {
                primaryPlayer.setMediaItem(mediaItem)
                primaryPlayer.repeatMode = Player.REPEAT_MODE_OFF
            }
            RepeatMode.ONCE -> {
                primaryPlayer.addMediaItem(mediaItem)
                primaryPlayer.addMediaItem(mediaItem)
                primaryPlayer.repeatMode = Player.REPEAT_MODE_OFF
                Log.d(TAG, "🔊 Added media item twice for repeat once mode")
            }
            RepeatMode.INFINITE -> {
                primaryPlayer.setMediaItem(mediaItem)
                primaryPlayer.repeatMode = Player.REPEAT_MODE_ONE
            }
        }
    }

    private fun ensureMediaSession() {
        if (primaryMediaSession != null) return

        Log.w(TAG, "⚠️ MediaSession is null, recreating it")
        primaryMediaSession = createMediaSession()
    }

    override fun playAudio(audioData: AudioData): Boolean {
        Log.d(TAG, "🔊 playAudio called with URL: ${audioData.url}, trackId: ${audioData.track.id}")
        if (!isServiceFullyInitialized || !::primaryPlayer.isInitialized || !::backgroundMusicPlayer.isInitialized) {
            Log.e(TAG, "❌ Players not initialized or service not ready")
            return false
        }

        val attempt = ++playbackAttempt
        timerStart.cancel()
        isCompletionHandled = false
        backgroundFadeJob?.cancel()
        backgroundFadeJob = null
        playbackGeneration = SharedPreferencesManager.currentGeneration()
        val accountGeneration = playbackGeneration
        completedPlaythroughs = 0
        sessionBells.reset()

        try {
            // Remember if background was playing
            val wasBackgroundPlaying = backgroundMusicPlayer.isPlaying

            // Stop any existing playback
            Log.d(TAG, "🔊 Stopping any existing primary playback")
            if (audioData.timerSeed != null) primaryPlayer.pause()
            resetPrimaryQueue()
            timerSeed = audioData.timerSeed
            if (timerSeed != null) timerStart.reset()
            timerStopLabel = audioData.timerStopLabel
            timerHasExtraTime = timerSeed != null && audioData.timerHasExtraTime == true
            if (timerSeed == null && timerParams != null) {
                // Una sesión guiada reemplaza al temporizador sin cerrarlo: su aviso de
                // respaldo ya no aplica y la sesión pasa a recuperada con su última foto.
                cancelTimerBackup()
                TimerEndBackup.markEnded(this, timerParams?.runId)
                if (runStore.recoverStale(null, SharedPreferencesManager.currentGeneration())) {
                    deliverPendingRuns()
                }
            }
            timerParams = if (timerSeed != null) TimerSessionParams.from(audioData) else null
            focusPolicy = timerParams?.let { TimerFocusPolicy(it.mixWithOthers) }
            pausedByPolicy = false
            setDuck(1f)
            lastClockPhase = -1
            storeThrottle.reset()
            timerEndPassed = false
            currentRunId = timerParams?.runId
            // El registro se confirma ANTES de que el reloj pueda arrancar (REV-03):
            // sin registro recuperable, el inicio falla y Dart lo informa.
            timerParams?.let { params ->
                if (!openTimerRun(params, audioData, accountGeneration)) {
                    abortTimerStart()
                    return false
                }
            }
            // Temporizador: archivo local (LOCAL). Guiada: puede ser de red (NETWORK) (TECH-14).
            primaryPlayer.setWakeMode(if (timerSeed != null) C.WAKE_MODE_LOCAL else C.WAKE_MODE_NETWORK)
            ensureMediaSession()
            primaryMediaSession?.let(::updateTimerMediaControls)
            lastTimerStop = null
            timerPlaybackStopped = false
            if (timerSeed != null) currentRepeatMode = RepeatMode.NONE
            primaryPlayer.setPlaybackSpeed(1.0f)
            sessionBells.configure(
                if (timerSeed != null) pendingTimerBellCues ?: emptyList() else null,
                pendingTimerBellsEnabled,
                backgroundMusicVolume,
                timerParams?.bellOutput,
                timerParams?.languageTag
            )
            installingTimerBellCues = false

            // Apply current repeat mode
            configurePrimaryPlaylist(buildPrimaryMediaItem(audioData), currentRepeatMode)

            // «No molestar» lo pone y lo quita el servicio (cualquier sesión, también guiadas).
            applyDnd(audioData)

            // Request audio focus before preparing (but don't stop background sound)
            val audioFocusGranted = requestAudioFocus()
            
            // On Android 16+, continue even if audio focus is denied initially
            // The system may grant it later, and we want to attempt playback
            if (!audioFocusGranted) {
                Log.w(TAG, "⚠️ Audio focus not granted initially, but continuing with playback attempt")
            }

            // Prepare the player
            primaryPlayer.prepare()
            
            // Helper function to start playback once ready
            val startPlayback = start@{
                if (playbackAttempt != attempt ||
                    accountGeneration != SharedPreferencesManager.currentGeneration()) return@start
                // Ensure we still have audio focus or request it again
                if (!focus.granted) {
                    requestAudioFocus()
                }
                
                // Start playback
                primaryPlayer.play()
                
                // Update notification
                updateNotification()
                
                // Start position updates
                startPositionUpdates()
                
                // Restart background sound if it was playing before
                if (wasBackgroundPlaying && backgroundSoundUri != null && !backgroundMusicPlayer.isPlaying) {
                    Log.d(TAG, "🔊 Restarting background sound that was playing before")
                    playBackgroundSound()
                }
            }
            
            if (timerSeed != null) {
                playTimer()
                sessionBells.whenPrepared { timerStart.bellsReady() }
            }

            val startWhenPrepared = {
                if (playbackAttempt == attempt &&
                    accountGeneration == SharedPreferencesManager.currentGeneration()
                ) {
                    if (audioData.timerSeed != null) timerStart.primaryReady() else startPlayback()
                }
            }

            // Check if player is already ready
            if (primaryPlayer.playbackState == Player.STATE_READY) {
                Log.d(TAG, "🔊 Player already ready, starting playback immediately")
                startWhenPrepared()
            } else {
                // Wait for player to be ready before playing (important for Android 16+)
                // Use a listener to start playback once ready
                val playbackListener = object : Player.Listener {
                    private var isHandled = false
                    
                    override fun onPlaybackStateChanged(state: Int) {
                        if (state == Player.STATE_READY && !isHandled) {
                            isHandled = true
                            Log.d(TAG, "🔊 Player is ready, starting playback")
                            primaryPlayer.removeListener(this)
                            startWhenPrepared()
                        } else if (state == Player.STATE_IDLE || state == Player.STATE_ENDED) {
                            if (!isHandled) {
                                isHandled = true
                                primaryPlayer.removeListener(this)
                            }
                        }
                    }
                }
                
                primaryPlayer.addListener(playbackListener)
            }

            Log.d(TAG, "🔊 Started primary audio playback preparation")
            return true
        } catch (e: Exception) {
            if (audioData.timerSeed != null) {
                timerStart.cancel()
                sessionBells.disable()
                currentRunId = null
            }
            Log.e(TAG, "❌ Error in playAudio: ${e.message}")
            e.printStackTrace()
            return false
        }
    }

    private fun updateNotification() {
        if (!::primaryPlayer.isInitialized || timerPlaybackStopped) return

        val mediaItem = primaryPlayer.currentMediaItem ?: return
        val notificationTimerSeed = timerSeed
        val title = mediaItem.mediaMetadata?.title?.toString() ?: "Intronauts"
        val artist = mediaItem.mediaMetadata?.artist?.toString() ?: "Intronauts"

        serviceScope.launch {
            try {
                val artworkBitmap = mediaItem.mediaMetadata?.artworkUri?.let { uri ->
                    try {
                        withContext(Dispatchers.IO) {
                            val inputStream = java.net.URL(uri.toString()).openStream()
                            BitmapFactory.decodeStream(inputStream)
                        }
                    } catch (e: Exception) {
                        null
                    }
                }

                withContext(Dispatchers.Main) {
                    if (!timerPlaybackStopped && notificationTimerSeed == timerSeed) {
                        showNotification(createNotificationBuilder(title, artist, artworkBitmap).build())
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
                withContext(Dispatchers.Main) {
                    if (!timerPlaybackStopped && notificationTimerSeed == timerSeed) {
                        showNotification(createNotificationBuilder(title, artist, null).build())
                    }
                }
            }
        }
    }

    private fun showNotification(newNotification: Notification) {
        notification = newNotification
        publishNotification(notification)
    }

    private fun publishNotification(newNotification: Notification?) {
        NotificationUtil.setNotification(
            this@AudioPlayerService,
            NOTIFICATION_ID,
            newNotification
        )
    }

    private fun createNotificationBuilder(
        title: String,
        artist: String,
        artworkBitmap: Bitmap?
    ): NotificationCompat.Builder {
        val params = timerParams.takeIf { timerSeed != null }
        // Temporizador con permiso de notificaciones: notificación simple con cronómetro.
        if (params != null && canPostNotifications()) {
            return createTimerNotificationBuilder(title, params)
        }
        val isPlaying = if (::primaryPlayer.isInitialized) primaryPlayer.isPlaying else false

        val builder = NotificationCompat.Builder(this@AudioPlayerService, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(artist)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setLargeIcon(artworkBitmap)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        // Add explicit media control actions for older Android versions
        // These are required for pre-Android 8 devices to show controls on lock screen
        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        // Skip backward action (ningún temporizador tiene saltos)
        if (timerSeed == null) builder.addAction(
            NotificationCompat.Action(
                R.drawable.ic_skip_backward,
                "Skip Backward",
                createMediaButtonPendingIntent(KeyEvent.KEYCODE_MEDIA_PREVIOUS, pendingIntentFlags)
            )
        )

        // Play/Pause action
        val playPauseIcon = if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play
        val playPauseTitle = if (isPlaying) "Pause" else "Play"
        builder.addAction(
            NotificationCompat.Action(
                playPauseIcon,
                playPauseTitle,
                createMediaButtonPendingIntent(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, pendingIntentFlags)
            )
        )

        // Skip forward action
        if (timerSeed == null) builder.addAction(
            NotificationCompat.Action(
                R.drawable.ic_skip_forward,
                "Skip Forward",
                createMediaButtonPendingIntent(KeyEvent.KEYCODE_MEDIA_NEXT, pendingIntentFlags)
            )
        )

        timerStopLabel?.let { label ->
            val stopIntent = Intent(this, AudioPlayerService::class.java).apply {
                action = ACTION_TIMER_STOP
                putExtra(KEY_TIMER_SEED, timerSeed ?: 0L)
                data = Uri.parse("medito://timer-stop/$timerSeed")
            }
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                label,
                PendingIntent.getService(this, 0, stopIntent, pendingIntentFlags)
            )
        }

        // Apply MediaStyle with actions shown in compact view
        primaryMediaSession?.let { session ->
            val style = MediaStyleNotificationHelper.MediaStyle(session)
            if (timerSeed != null) {
                if (timerStopLabel != null) style.setShowActionsInCompactView(0, 1)
                else style.setShowActionsInCompactView(0)
            } else {
                style.setShowActionsInCompactView(0, 1, 2)
            }
            builder.setStyle(style)
        }

        return builder
    }

    private fun canPostNotifications(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun notificationFlags(): Int =
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT

    /**
     * Notificación del temporizador sin MediaStyle (§4.8): el cronómetro se ve en
     * todas las versiones. Acciones: Pausa/Reanudar y «Terminar». Media3 no la
     * reemplaza porque `onUpdateNotification` no publica nada en temporizadores.
     */
    private fun createTimerNotificationBuilder(
        title: String,
        params: TimerSessionParams
    ): NotificationCompat.Builder {
        val playing = ::primaryPlayer.isInitialized && primaryPlayer.isPlaying
        val position = if (::primaryPlayer.isInitialized) primaryPlayer.currentPosition else 0L
        val clock = TimerNotificationClock.clock(
            nowMs = System.currentTimeMillis(),
            positionMs = position,
            isPlaying = playing,
            prepMs = params.prepMs,
            plannedMs = params.plannedMs,
            extraTime = params.extraTime,
            isStopwatch = params.isStopwatch
        )
        val builder = NotificationCompat.Builder(this@AudioPlayerService, CHANNEL_ID)
            .setContentTitle(title)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setUsesChronometer(clock.usesChronometer)
            .setShowWhen(clock.usesChronometer)
            .setWhen(clock.whenMs)
            .setChronometerCountDown(clock.countDown)
        TimerEndBackup.openAppIntent(this)?.let(builder::setContentIntent)
        when (clock.subText) {
            TimerClock.Kind.PREP -> params.prepText?.let(builder::setSubText)
            TimerClock.Kind.EXTRA_TIME -> params.extraTimeText?.let(builder::setSubText)
            null -> Unit
        }
        if (!playing) params.pausedText?.let(builder::setContentText)

        // Textos de Media3 (traducidos por el sistema): sin texto fijo en inglés.
        val playPauseIcon = if (playing) R.drawable.ic_pause else R.drawable.ic_play
        val playPauseTitle = getString(
            if (playing) androidx.media3.session.R.string.media3_controls_pause_description
            else androidx.media3.session.R.string.media3_controls_play_description
        )
        builder.addAction(
            playPauseIcon,
            playPauseTitle,
            createMediaButtonPendingIntent(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, notificationFlags())
        )
        timerStopLabel?.let { label ->
            val stopIntent = Intent(this, AudioPlayerService::class.java).apply {
                action = ACTION_TIMER_STOP
                putExtra(KEY_TIMER_SEED, timerSeed ?: 0L)
                data = Uri.parse("medito://timer-stop/$timerSeed")
            }
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                label,
                PendingIntent.getService(this, 0, stopIntent, notificationFlags())
            )
        }
        return builder
    }

    /** Aviso de pausa (audífonos u otra app) en el canal `timer_alerts`. */
    private fun postTimerAlert(text: String?) {
        if (text.isNullOrBlank() || !canPostNotifications()) return
        try {
            val manager = getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(TIMER_ALERTS_CHANNEL_ID) == null) {
                val name = timerParams?.alertsChannelName?.takeIf { it.isNotBlank() } ?: return
                manager.createNotificationChannel(
                    NotificationChannel(TIMER_ALERTS_CHANNEL_ID, name, NotificationManager.IMPORTANCE_DEFAULT)
                )
            }
            val builder = NotificationCompat.Builder(this, TIMER_ALERTS_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            TimerEndBackup.openAppIntent(this)?.let(builder::setContentIntent)
            manager.notify(TIMER_ALERT_NOTIFICATION_ID, builder.build())
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo mostrar el aviso de pausa", error)
        }
    }

    private fun createMediaButtonPendingIntent(keyCode: Int, flags: Int): PendingIntent {
        val action = when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> ACTION_PLAY_PAUSE
            KeyEvent.KEYCODE_MEDIA_PREVIOUS -> ACTION_SKIP_BACKWARD
            KeyEvent.KEYCODE_MEDIA_NEXT -> ACTION_SKIP_FORWARD
            else -> return PendingIntent.getService(this, keyCode, Intent(this, AudioPlayerService::class.java), flags)
        }

        val intent = Intent(this, AudioPlayerService::class.java).apply {
            this.action = action
        }
        return PendingIntent.getService(this, keyCode, intent, flags)
    }

    private var backgroundPreparationAttempt = 0L

    override fun playBackgroundSound(callback: (Result<Boolean>) -> Unit) {
        if (!playBackgroundSound()) {
            callback(Result.success(false))
            return
        }
        val player = backgroundMusicPlayer
        if (player.playbackState == Player.STATE_READY) {
            callback(Result.success(true))
            return
        }
        if (player.playbackState != Player.STATE_BUFFERING) {
            callback(Result.success(false))
            return
        }

        val attempt = backgroundPreparationAttempt
        val listener = object : Player.Listener {
            private var finished = false
            val timeout: Runnable = Runnable {
                if (attempt == backgroundPreparationAttempt && isActive &&
                    player.playbackState == Player.STATE_BUFFERING
                ) player.stop()
                finish(false)
            }

            private fun finish(prepared: Boolean) {
                if (finished) return
                finished = true
                handler.removeCallbacks(timeout)
                player.removeListener(this)
                callback(Result.success(prepared))
            }

            override fun onEvents(player: Player, events: Player.Events) {
                when {
                    attempt != backgroundPreparationAttempt || !isActive ||
                        player.playerError != null -> finish(false)
                    player.playbackState == Player.STATE_READY -> {
                        if (timerBackgroundShouldWait()) player.pause()
                        finish(true)
                    }
                    player.playbackState != Player.STATE_BUFFERING -> finish(false)
                }
            }
        }
        player.addListener(listener)
        handler.postDelayed(listener.timeout, 10_000L)
    }

    private fun timerBackgroundShouldWait(): Boolean =
        timerSeed != null && ::primaryPlayer.isInitialized && !primaryPlayer.playWhenReady

    private fun playBackgroundSound(): Boolean {
        val uri = backgroundSoundUri ?: return false
        if (uri == SessionBellPlayer.URI || !isActive || !::backgroundMusicPlayer.isInitialized) return false

        return try {
            backgroundFadeJob?.cancel()
            backgroundFadeJob = null
            val player = backgroundMusicPlayer
            val mediaUri = Uri.parse(uri)
            // Al reanudar, conserva la preparación que ya está en curso.
            if (player.currentMediaItem?.localConfiguration?.uri != mediaUri ||
                (player.playbackState != Player.STATE_READY && player.playbackState != Player.STATE_BUFFERING)
            ) {
                backgroundPreparationAttempt++
                resetBackgroundQueue()
                player.repeatMode = Player.REPEAT_MODE_ONE
                player.setMediaItem(MediaItem.fromUri(mediaUri))
                player.prepare()
            }

            player.volume = backgroundMusicVolume * duckFactor
            // Un temporizador en pausa prepara el fondo y lo reanuda con el reloj.
            player.playWhenReady = !timerBackgroundShouldWait()
            true
        } catch (e: Exception) {
            Log.e(TAG, "No se pudo preparar el sonido de fondo", e)
            false
        }
    }

    override fun pauseBackgroundSound() {
        backgroundMusicPlayer.pause()
    }

    override fun setBackgroundSound(uri: String?) {
        Log.d(TAG, "🔊 setBackgroundSound called with URI: $uri")
        backgroundPreparationAttempt++

        // Always stop the current background sound first
        try {
            backgroundFadeJob?.cancel()
            backgroundFadeJob = null
            if (::backgroundMusicPlayer.isInitialized) {
                backgroundMusicPlayer.stop()
                Log.d(TAG, "🔊 Stopped current background sound")
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error stopping background sound: ${e.message}")
        }

        // Now set the new URI
        this.backgroundSoundUri = uri

        if (uri == null) {
            Log.d(TAG, "🔊 Background sound cleared")
        } else {
            Log.d(TAG, "🔊 Background sound URI set to: $uri")
        }
    }

    override fun stopBackgroundSound() {
        backgroundPreparationAttempt++
        try {
            Log.d(TAG, "🔊 Stopping background sound")
            backgroundFadeJob?.cancel()
            backgroundFadeJob = null
            if (::backgroundMusicPlayer.isInitialized) {
                backgroundMusicPlayer.stop()
                // Don't clear the URI - that should be done by setBackgroundSound(null)
                Log.d(TAG, "🔊 Background sound stopped successfully")
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error stopping background sound: ${e.message}")
            e.printStackTrace()
        }
    }

    // Bells are independent of the ambient sound: both can play at once.
    override fun setSessionBells(enabled: Boolean) {
        if (!::sessionBells.isInitialized) {
            Log.w(TAG, "setSessionBells($enabled) before the service was ready")
            return
        }
        if (pendingTimerBellCues != null) pendingTimerBellsEnabled = enabled
        if (!installingTimerBellCues) sessionBells.setEnabled(enabled, backgroundMusicVolume)
    }

    private var installingTimerBellCues = false

    override fun setBellCues(useTrackSchedule: Boolean, cues: List<BellCue>) {
        pendingTimerBellCues = if (useTrackSchedule) null else cues
        installingTimerBellCues = !useTrackSchedule
    }

    override fun setBackgroundSoundVolume(volume: Double) {
        if (!isServiceFullyInitialized) {
            Log.d(TAG, "⚠️ setBackgroundSoundVolume called before service fully initialized")
            throw IllegalStateException("Service not fully initialized")
        }
        this.backgroundMusicVolume = volume.toFloat()
        sessionBells.setVolume(this.backgroundMusicVolume)
        if (::backgroundMusicPlayer.isInitialized && backgroundFadeJob?.isActive != true) {
            backgroundMusicPlayer.volume = this.backgroundMusicVolume * duckFactor
        }
    }

    override fun seekToPosition(position: Long) {
        // Ningún temporizador permite adelantar o regresar (UX-13).
        if (timerSeed != null) return
        isCompletionHandled = false
        primaryPlayer.seekTo(position)
    }

    override fun setSpeed(speed: Double) {
        if (timerSeed != null) return
        primaryPlayer.setPlaybackSpeed(speed.toFloat())
    }

    override fun skip10SecondsForward() {
        seekBy(SEEK_INTERVAL_MS)
    }

    override fun skip10SecondsBackward() {
        seekBy(-SEEK_INTERVAL_MS)
    }

    private fun seekBy(deltaMs: Long) {
        if (timerSeed != null || !::primaryPlayer.isInitialized) return

        val currentPosition = primaryPlayer.currentPosition
        val targetPosition = if (deltaMs > 0) {
            val duration = primaryPlayer.duration
            if (duration == C.TIME_UNSET) return
            minOf(currentPosition + deltaMs, duration)
        } else {
            maxOf(currentPosition + deltaMs, 0L)
        }

        primaryPlayer.seekTo(targetPosition)
    }

    override fun setRepeatMode(mode: RepeatMode) {
        Log.d(TAG, "🔊 Setting repeat mode to: $mode")
        currentRepeatMode = mode
        if (timerSeed != null) return

        if (::primaryPlayer.isInitialized) {
            val currentMediaItem = primaryPlayer.currentMediaItem
            if (currentMediaItem == null) {
                Log.d(TAG, "🔊 No media item currently loaded, repeat mode will be applied when media is loaded")
                return
            }

            // Get current position to restore after rebuilding playlist
            val currentPosition = primaryPlayer.currentPosition
            val wasPlaying = primaryPlayer.isPlaying

            // Rebuild playlist based on repeat mode
            resetPrimaryQueue()
            configurePrimaryPlaylist(currentMediaItem, mode)

            // Restore playback state
            primaryPlayer.prepare()
            if (wasPlaying) {
                primaryPlayer.seekTo(currentPosition)
                primaryPlayer.play()
            } else {
                primaryPlayer.seekTo(currentPosition)
            }
        }
    }

    private fun requestSystemTimerStop(): Boolean {
        val seed = timerSeed ?: return false
        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID)
        // Un cierre del sistema (notificación, auriculares, app cerrada) guarda el tiempo.
        val report = stopTimerPlaybackInternal(seed, systemStop = true, save = true)
        if (report.stopped && engine != null) {
            MeditoTimerStopCallbackApi(engine.dartExecutor.binaryMessenger).timerStopped(seed, report) { result ->
                result.exceptionOrNull()?.let {
                    Log.e(TAG, "No se pudo comunicar el cierre del temporizador", it)
                }
            }
        }
        return report.stopped
    }

    override fun stopTimerPlayback(sessionSeed: Long, save: Boolean): TimerStopReport =
        stopTimerPlaybackInternal(sessionSeed, systemStop = false, save = save)

    private fun stopTimerPlaybackInternal(sessionSeed: Long, systemStop: Boolean, save: Boolean): TimerStopReport {
        if (playbackGeneration != SharedPreferencesManager.currentGeneration()) {
            return TimerStopReport(0L, false, false)
        }
        lastTimerStop?.let { (seed, report) ->
            if (seed == sessionSeed) return report
        }
        if (timerSeed != sessionSeed || isCompletionHandled) {
            return TimerStopReport(0L, false, false)
        }

        val position = primaryPlayer.currentPosition
        val params = timerParams
        val runId = params?.runId
        val generation = playbackGeneration
        var completionPersisted = false
        if (params != null) {
            if (save) {
                // El cierre se guarda con su tiempo FINAL antes de detener el audio.
                val elapsed = params.elapsedMs(position)
                val seconds = elapsed / 1000L
                val result = runStore.finish(
                    runId = params.runId,
                    durationMs = seconds * 1000L,
                    trackId = TimerElapsed.trackId(elapsed),
                    timestamp = System.currentTimeMillis(),
                    generation = generation,
                    fallback = activeRunSnapshot(params, position)
                )
                Log.d(TAG, "Cierre del temporizador (sistema=$systemStop): ${elapsed} ms, resultado=$result")
                if (result == TimerCloseResult.FAILED && !systemStop) {
                    // No se pudo guardar: la sesión sigue sonando y se informa el fallo (R100).
                    return TimerStopReport(position, false, false, false, runId)
                }
                // Cierre del sistema que falló: se detiene igual y la última foto
                // confirmada queda en `active` para recuperarla después.
                completionPersisted = result == TimerCloseResult.SAVED
            } else if (!runStore.discard(params.runId, generation)) {
                // «Salir sin guardar» no pudo borrar la sesión: no se detiene nada (R52).
                Log.e(TAG, "No se pudo descartar la sesión; el temporizador sigue")
                return TimerStopReport(position, false, false, runId = runId)
            }
        }
        playbackAttempt++
        timerStart.cancel()
        var endCueRang = false
        try {
            endCueRang = sessionBells.stopAndReportEnd()
            stopPlayers(clearTimerQueue = true, fadeBackground = true)
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo detener el temporizador", error)
            return TimerStopReport(position, endCueRang, false, completionPersisted, runId)
        }
        endTimerRun(runId)
        val report = TimerStopReport(position, endCueRang, true, completionPersisted, runId)
        lastTimerStop = sessionSeed to report
        finishManualStop()
        if (completionPersisted) deliverPendingRuns()
        return report
    }

    override fun stopAudio() {
        playbackAttempt++
        timerStart.cancel()
        sessionBells.disable()
        val wasTimer = timerSeed != null
        // stopAudio en un temporizador vivo = salir sin guardar (R102). Aunque el
        // descarte no se confirme, la sesión queda marcada y nunca se recupera.
        val params = timerParams
        if (wasTimer && params != null && !isCompletionHandled) {
            if (!runStore.discard(params.runId, playbackGeneration, rememberOnFailure = true)) {
                Log.e(TAG, "No se pudo confirmar el descarte de la sesión en stopAudio")
            }
        }
        stopPlayers(clearTimerQueue = wasTimer, fadeBackground = false)
        if (wasTimer) endTimerRun(params?.runId) else restoreDnd()
        finishManualStop()
    }

    private fun stopPlayers(clearTimerQueue: Boolean, fadeBackground: Boolean = false) {
        // El desvanecimiento se protege ANTES de detener el reloj: su paso a IDLE
        // ya no puede pausar el fondo (R107).
        val fade = fadeBackground && backgroundMusicPlayer.isPlaying
        if (fade) fadeOutBackground(clear = clearTimerQueue)
        primaryPlayer.stop()
        if (!fade) {
            backgroundFadeJob?.cancel()
            backgroundFadeJob = null
            backgroundMusicPlayer.stop()
            if (clearTimerQueue) backgroundMusicPlayer.clearMediaItems()
        }
        if (clearTimerQueue) {
            backgroundSoundUri = null
            primaryPlayer.clearMediaItems()
        }
    }

    /**
     * Al terminar un temporizador a mano, el sonido de fondo baja a 0 en 3 s
     * (15 pasos) y luego se detiene; campanas y reloj ya se detuvieron.
     */
    private fun fadeOutBackground(clear: Boolean) {
        backgroundFadeJob?.cancel()
        val startVolume = backgroundMusicPlayer.volume
        val job = serviceScope.launch {
            for (step in 1..BACKGROUND_FADE_STEPS) {
                delay(BACKGROUND_FADE_MS / BACKGROUND_FADE_STEPS)
                backgroundMusicPlayer.volume = startVolume * (1f - step.toFloat() / BACKGROUND_FADE_STEPS)
            }
            backgroundMusicPlayer.stop()
            if (clear) backgroundMusicPlayer.clearMediaItems()
        }
        backgroundFadeJob = job
        job.invokeOnCompletion {
            handler.post { if (backgroundFadeJob === job) backgroundFadeJob = null }
        }
    }

    /** Cierra lo nativo de la sesión: respaldo, estado, «No molestar». */
    private fun endTimerRun(runId: String?) {
        cancelTimerBackup()
        TimerEndBackup.markEnded(this, runId)
        if (currentRunId == runId) currentRunId = null
        restoreDnd()
    }

    private fun finishManualStop() {
        if (timerSeed != null) timerPlaybackStopped = true
        timerSeed = null
        timerStopLabel = null
        timerHasExtraTime = false
        timerParams = null
        focusPolicy = null
        pausedByPolicy = false
        setDuck(1f)
        isCompletionHandled = false
        stopPositionUpdates()
        try {
            primaryMediaSession?.let(::updateTimerMediaControls)
            clearNotification()
        } catch (error: Exception) {
            Log.e(TAG, "No se pudieron quitar los controles del reproductor", error)
        }
    }

    private fun playTimer() {
        val attempt = playbackAttempt
        timerStart.play {
            if (attempt != playbackAttempt ||
                playbackGeneration != SharedPreferencesManager.currentGeneration()
            ) return@play
            val granted = requestAudioFocus()
            val params = timerParams
            val policy = focusPolicy
            if (params != null && policy != null) {
                val inCall = TimerFocusPolicy.isCallMode(audioManager.mode)
                // Modo normal: se espera el foco si quedó en espera o hay llamada.
                // Modo mezcla: se revisa la llamada en cada arranque (R103).
                val waitForFocus = !params.mixWithOthers && !granted && (focusDelayed || inCall)
                if (!policy.onStartAttempt(params.mixWithOthers && inCall, !waitForFocus)) {
                    Log.d(TAG, "🔊 El reloj espera: llamada o foco pendiente")
                    pausedByPolicy = true
                    updateNotification()
                    // Dart ve la espera (no es una carga fallida) y, en modo mezcla,
                    // la revisión de cada segundo detecta el fin de la llamada (REV-06).
                    startPositionUpdates()
                    return@play
                }
            }
            pausedByPolicy = false
            primaryPlayer.play()
            updateNotification()
            startPositionUpdates()
            scheduleTimerBackup()
        }
    }

    /** Reanudar pedido por la persona (app, notificación, controles del sistema). */
    private fun userResumeTimer() {
        focusPolicy?.onUserResume()
        playTimer()
    }

    /** Pausa pedida por la persona: cancela la reanudación automática y suelta el foco. */
    private fun userPauseTimer() {
        focusPolicy?.onUserPause()
        timerStart.pause()
        if (pausedByPolicy) {
            pausedByPolicy = false
            abandonAudioFocus()
        }
        primaryPlayer.pause()
    }

    override fun playPauseAudio() {
        Log.d(TAG, "🔊 playPauseAudio called")
        try {
            // Check if player is initialized and in a valid state
            if (!::primaryPlayer.isInitialized) {
                Log.e(TAG, "❌ Primary player not initialized")
                return
            }
            
            if (timerSeed != null) {
                // Un temporizador terminado (esperando sus campanas) ya no se reanuda.
                if (isCompletionHandled) return
                if (primaryPlayer.playWhenReady) {
                    userPauseTimer()
                } else {
                    userResumeTimer()
                }
                return
            }
            isCompletionHandled = false

            if (primaryPlayer.isPlaying) {
                Log.d(TAG, "🔊 Pausing primary player")
                primaryPlayer.pause()
                // Also pause background sound
                if (backgroundMusicPlayer.isPlaying) {
                    Log.d(TAG, "🔊 Also pausing background sound")
                    backgroundMusicPlayer.pause()
                }
            } else {
                Log.d(TAG, "🔊 Playing primary player")
                
                // Check player state before attempting to play
                val playbackState = primaryPlayer.playbackState
                if (playbackState == Player.STATE_IDLE || playbackState == Player.STATE_ENDED) {
                    Log.w(TAG, "⚠️ Player is in $playbackState state, cannot play. Need to prepare first.")
                    return
                }

                // Request audio focus before playing
                requestAudioFocus()

                // Only play if player is in a ready state
                if (playbackState == Player.STATE_READY || playbackState == Player.STATE_BUFFERING) {
                    primaryPlayer.play()
                    
                    // If background sound was previously playing, resume it
                    if (backgroundSoundUri != null) {
                        Log.d(TAG, "🔊 Resuming background sound if available")
                        playBackgroundSound()
                    }

                    Log.d(TAG, "🔊 Primary player playback started")
                } else {
                    Log.w(TAG, "⚠️ Player not ready (state: $playbackState), waiting for STATE_READY")
                    // Add listener to play when ready
                    val playListener = object : Player.Listener {
                        private var isHandled = false
                        
                        override fun onPlaybackStateChanged(state: Int) {
                            if (state == Player.STATE_READY && !isHandled) {
                                isHandled = true
                                primaryPlayer.removeListener(this)
                                primaryPlayer.play()
                                
                                if (backgroundSoundUri != null) {
                                    playBackgroundSound()
                                }
                                
                                Log.d(TAG, "🔊 Primary player playback started after becoming ready")
                            }
                        }
                    }
                    primaryPlayer.addListener(playListener)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error in playPauseAudio: ${e.message}")
            e.printStackTrace()
        }
    }

    /** Pide el foco a través del único dueño; en modo mezcla no pide nada. */
    private fun requestAudioFocus(): Boolean {
        return try {
            val kind = if (timerSeed != null) FocusKind.TIMER else FocusKind.GUIDED
            val mix = timerSeed != null && timerParams?.mixWithOthers == true
            val granted = focus.ensure(kind, mix)
            Log.d(TAG, "🔊 Audio focus ($kind, mezcla=$mix): ${if (granted) "GRANTED" else "NOT HELD"}")
            granted
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error requesting audio focus: ${e.message}")
            e.printStackTrace()
            false
        }
    }

    private fun abandonAudioFocus() {
        try {
            focus.abandon()
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error abandoning audio focus: ${e.message}")
        }
    }

    /** Foco real de Android: arma la solicitud una vez y avisa los cambios por tipo de sesión. */
    private inner class AndroidFocusBackend : FocusBackend<AudioFocusRequest> {
        override fun build(kind: FocusKind): AudioFocusRequest {
            val audioAttributes = android.media.AudioAttributes.Builder()
                .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
            return AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(audioAttributes)
                // El temporizador acepta foco en espera: durante una llamada llega GAIN al colgar.
                .setAcceptsDelayedFocusGain(kind == FocusKind.TIMER)
                .setOnAudioFocusChangeListener({ change -> onAudioFocusChange(kind, change) }, handler)
                .build()
        }

        override fun request(request: AudioFocusRequest): Boolean {
            val result = audioManager.requestAudioFocus(request)
            focusDelayed = result == AudioManager.AUDIOFOCUS_REQUEST_DELAYED
            return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }

        override fun abandon(request: AudioFocusRequest) {
            audioManager.abandonAudioFocusRequest(request)
        }
    }

    private fun onAudioFocusChange(kind: FocusKind, focusChange: Int) {
        Log.d(TAG, "🔊 Audio focus changed to: $focusChange ($kind)")
        focus.onFocusChange(focusChange == AudioManager.AUDIOFOCUS_GAIN)
        if (kind == FocusKind.TIMER) {
            val policy = focusPolicy ?: return
            val change = TimerFocusPolicy.fromAndroid(focusChange) ?: return
            applyFocusActions(policy.onFocusChange(change, timerWantsToPlay()))
            return
        }
        // Sesiones guiadas: el comportamiento de siempre.
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                Log.d(TAG, "🔊 Audio focus GAINED")
                if (::primaryPlayer.isInitialized) {
                    // Restore volume
                    primaryPlayer.volume = 1f

                    // Resume playback if we should be playing
                    if (primaryPlayer.playWhenReady && !primaryPlayer.isPlaying &&
                        primaryPlayer.playbackState != Player.STATE_IDLE &&
                        primaryPlayer.playbackState != Player.STATE_ENDED
                    ) {
                        Log.d(TAG, "🔊 Resuming playback after gaining focus")
                        primaryPlayer.play()
                    }
                }
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                Log.d(TAG, "🔊 Audio focus LOST")
                // Do NOT pause the primary player on audio focus loss
                // Just lower the volume to be polite to other apps
                if (::primaryPlayer.isInitialized && primaryPlayer.isPlaying) {
                    primaryPlayer.volume = 0.3f
                }
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                Log.d(TAG, "🔊 Audio focus LOST TRANSIENT")
                // Do NOT pause the primary player on transient focus loss
                // Just lower the volume to be polite to other apps
                if (::primaryPlayer.isInitialized && primaryPlayer.isPlaying) {
                    primaryPlayer.volume = 0.3f
                }
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                Log.d(TAG, "🔊 Audio focus LOST TRANSIENT (CAN DUCK)")
                if (::primaryPlayer.isInitialized) {
                    Log.d(TAG, "🔊 Ducking volume due to transient focus loss")
                    primaryPlayer.volume = 0.2f
                }
            }
        }
    }

    // ---- Temporizador: política de foco, reloj, registro, respaldo ----

    private fun timerWantsToPlay(): Boolean =
        ::primaryPlayer.isInitialized && primaryPlayer.playWhenReady &&
            primaryPlayer.playbackState != Player.STATE_IDLE &&
            primaryPlayer.playbackState != Player.STATE_ENDED

    private fun applyFocusActions(actions: List<FocusAction>) {
        if (timerSeed == null) return
        for (action in actions) {
            Log.d(TAG, "🔊 Política de foco: $action")
            when (action) {
                is FocusAction.Pause -> {
                    // Pausa de la política: el foco se conserva para recibir GAIN.
                    pausedByPolicy = true
                    timerStart.pause()
                    primaryPlayer.pause()
                }
                FocusAction.Resume -> playTimer()
                FocusAction.Duck -> setDuck(DUCK_FACTOR)
                FocusAction.Unduck -> setDuck(1f)
                FocusAction.NotifyOtherAudio -> {
                    // Otra app se quedó con el audio: ya no habrá GAIN, se suelta el foco.
                    pausedByPolicy = false
                    abandonAudioFocus()
                    postTimerAlert(timerParams?.otherAudioPausedText)
                }
                FocusAction.None -> Unit
            }
        }
    }

    /** Sonido de fondo y campanas al 20 % (o de vuelta al 100 %); nunca el reloj silencioso. */
    private fun setDuck(factor: Float) {
        duckFactor = factor
        if (::sessionBells.isInitialized) sessionBells.setDuck(factor)
        if (::backgroundMusicPlayer.isInitialized && backgroundFadeJob?.isActive != true &&
            backgroundMusicVolume > 0f
        ) {
            backgroundMusicPlayer.volume = backgroundMusicVolume * duckFactor
        }
    }

    private fun onTimerPaused() {
        val params = timerParams ?: return
        cancelTimerBackup()
        val position = primaryPlayer.currentPosition
        runStore.update(params.runId, position, timerEndPassed, System.currentTimeMillis(), playbackGeneration, ++snapshotSeq)
        storeThrottle.markWritten()
    }

    /**
     * Revisión de cada segundo (hilo principal). Devuelve la escritura periódica
     * del registro para hacerla fuera del hilo principal.
     */
    private fun timerTick(position: Long): (() -> Unit)? {
        val params = timerParams ?: return null
        if (timerSeed == null || isCompletionHandled) return null

        // Modo mezcla: las llamadas se ven en el modo de audio.
        focusPolicy?.takeIf { it.mixWithOthers }?.let { policy ->
            applyFocusActions(policy.onCallState(TimerFocusPolicy.isCallMode(audioManager.mode), timerWantsToPlay()))
        }
        if (!timerEndPassed && position >= params.endMs) markTimerEndPassed()

        val phase = TimerNotificationClock.phase(position, params.prepMs, params.plannedMs)
        if (phase != lastClockPhase) {
            lastClockPhase = phase
            updateNotification()
        }

        // El intervalo se mide con el reloj desde el arranque; la hora del teléfono
        // sólo fecha la foto (REV-04).
        if (!primaryPlayer.isPlaying || !storeThrottle.due()) return null
        storeThrottle.markWritten()
        val now = System.currentTimeMillis()
        val runId = params.runId
        val endPassed = timerEndPassed
        val generation = playbackGeneration
        val seq = ++snapshotSeq
        return { runStore.update(runId, position, endPassed, now, generation, seq) }
    }

    /** Pasó el final planeado (sonó la campana final o la posición llegó): sin respaldo (R79). */
    private fun markTimerEndPassed() {
        val params = timerParams ?: return
        cancelTimerBackup()
        if (timerEndPassed) return
        timerEndPassed = true
        TimerEndBackup.markEnded(this, params.runId)
        val position = primaryPlayer.currentPosition
        val generation = playbackGeneration
        val seq = ++snapshotSeq
        backgroundScope.launch {
            runStore.update(params.runId, position, true, System.currentTimeMillis(), generation, seq)
        }
    }

    private fun backupRequest(params: TimerSessionParams) = TimerBackupRequest(
        runId = params.runId,
        title = params.backupTitle,
        body = params.backupBody,
        output = params.bellOutput,
        channelName = params.backupChannelName,
        silentChannelName = params.backupSilentChannelName
    )

    private fun scheduleTimerBackup() {
        val params = timerParams ?: return
        try {
            endBackup.schedule(
                request = backupRequest(params),
                prepMs = params.prepMs,
                plannedMs = params.plannedMs,
                extraTime = params.extraTime,
                isStopwatch = params.isStopwatch,
                positionMs = primaryPlayer.currentPosition,
                endPassed = timerEndPassed
            )
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo programar el aviso de respaldo", error)
        }
    }

    private fun cancelTimerBackup() {
        try {
            endBackup.cancel()
        } catch (error: Exception) {
            Log.e(TAG, "No se pudo cancelar el aviso de respaldo", error)
        }
    }

    /** La alarma sonó con la sesión viva: se recalcula con lo que le queda al reproductor. */
    private fun rescheduleBackupFromPlayer() {
        if (timerSeed == null || !::primaryPlayer.isInitialized || !primaryPlayer.isPlaying) return
        scheduleTimerBackup()
    }

    private fun activeRunSnapshot(params: TimerSessionParams, position: Long): TimerActiveRun {
        val metadata = primaryPlayer.currentMediaItem?.mediaMetadata
        val now = System.currentTimeMillis()
        return TimerActiveRun(
            runId = params.runId,
            ownerId = params.ownerId,
            fileId = metadata?.extras?.getString(KEY_FILE_ID).orEmpty(),
            trackId = primaryPlayer.currentMediaItem?.mediaId.orEmpty(),
            guideId = metadata?.artist?.toString(),
            startEpochMs = params.startEpochMs,
            prepMs = params.prepMs,
            plannedMs = params.plannedMs,
            extraTime = params.extraTime,
            isStopwatch = params.isStopwatch,
            lastPositionMs = position,
            updatedAtMs = now,
            endPassed = timerEndPassed
        )
    }

    /**
     * Guarda la sesión al aceptarla, ANTES de arrancar el reloj; una sesión vieja
     * sin cerrar pasa a recuperada. Devuelve false si no se pudo guardar (REV-03).
     */
    private fun openTimerRun(params: TimerSessionParams, audioData: AudioData, generation: Long): Boolean {
        val run = TimerActiveRun(
            runId = params.runId,
            ownerId = params.ownerId,
            fileId = audioData.track.fileId,
            trackId = audioData.track.id,
            guideId = audioData.track.artist,
            startEpochMs = params.startEpochMs,
            prepMs = params.prepMs,
            plannedMs = params.plannedMs,
            extraTime = params.extraTime,
            isStopwatch = params.isStopwatch,
            lastPositionMs = 0L,
            updatedAtMs = params.startEpochMs,
            endPassed = false
        )
        return when (runStore.open(run, generation)) {
            TimerRunOpen.FAILED -> {
                Log.e(TAG, "No se pudo guardar el inicio de la sesión del temporizador")
                false
            }
            TimerRunOpen.OPENED_WITH_RECOVERY -> {
                TimerEndBackup.writeRunState(this, params.runId, ended = false)
                deliverPendingRuns()
                true
            }
            TimerRunOpen.OPENED -> {
                TimerEndBackup.writeRunState(this, params.runId, ended = false)
                true
            }
        }
    }

    /** El inicio no se pudo guardar: nada de esta sesión queda armado (REV-03). */
    private fun abortTimerStart() {
        timerStart.cancel()
        sessionBells.disable()
        currentRunId = null
        timerSeed = null
        timerStopLabel = null
        timerHasExtraTime = false
        timerParams = null
        focusPolicy = null
        pausedByPolicy = false
    }

    /**
     * Fin natural del temporizador: el cierre (tiempo planeado) se guarda en el
     * acto; la pantalla final y el cierre del servicio esperan a que suenen
     * completas las campanas pendientes (máximo 60 s, R53).
     */
    private fun completeTimerNaturally() {
        val params = timerParams
        val attempt = playbackAttempt
        cancelTimerBackup()
        if (params != null) {
            timerEndPassed = true
            TimerEndBackup.markEnded(this, params.runId)
            val mediaItem = primaryPlayer.currentMediaItem
            // Cuenta regresiva y cronómetro: lo planeado (TECH-9; el cronómetro tiene 5 h).
            // Tiempo extra que llegó al final del archivo: lo meditado, con su tope.
            val duration = if (params.extraTime) params.elapsedMs(primaryPlayer.currentPosition)
            else params.plannedMs
            // El historial lleva el id de lo registrado; el del archivo es del reproductor (REV-07).
            val trackId = TimerFinishedRun.naturalTrackId(params.extraTime, duration, mediaItem?.mediaId, params.plannedMs)
            val fallback = activeRunSnapshot(params, primaryPlayer.currentPosition)
            val generation = playbackGeneration
            val closeNatural = {
                runStore.finish(params.runId, duration, trackId, System.currentTimeMillis(), generation, fallback)
            }
            var result = closeNatural()
            Log.d(TAG, "Fin natural del temporizador: $result")
            if (result == TimerCloseResult.FAILED) {
                // Reintento con el tiempo final; si sigue fallando, la foto final queda
                // en `active` para que la recuperación use ese tiempo (R100).
                result = closeNatural()
                if (result == TimerCloseResult.FAILED) {
                    runStore.update(params.runId, primaryPlayer.currentPosition, true,
                        System.currentTimeMillis(), generation, ++snapshotSeq)
                    naturalCloseRetry = closeNatural
                }
            }
            // Guardado: el cierre va ya al historial de Dart, que es quien confirma
            // «Guardamos tu sesión» al publicar el final (END-01).
            if (NaturalTimerClose.deliverBeforeEnd(result)) deliverPendingRuns()
        }
        sessionBells.drainThen {
            naturalCloseRetry?.let { retry ->
                naturalCloseRetry = null
                val retried = retry()
                if (retried == TimerCloseResult.FAILED) {
                    Log.e(TAG, "No se pudo guardar el fin natural; queda para la recuperación")
                } else if (NaturalTimerClose.deliverBeforeEnd(retried)) {
                    deliverPendingRuns()
                }
            }
            if (attempt != playbackAttempt) {
                // Otra sesión empezó mientras sonaban las campanas: sólo se entrega el cierre.
                deliverPendingRuns()
                return@drainThen
            }
            pushCompletedStateToDart()
            sessionBells.disable()
            endTimerRun(params?.runId)
            finishPlayback()
            deliverPendingRuns()
        }
    }

    /** Entrega a Dart los cierres pendientes si el motor de Flutter vive. */
    private fun deliverPendingRuns() {
        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_ID) ?: return
        val api = MeditoAudioServiceCallbackApi(engine.dartExecutor.binaryMessenger)
        handler.post {
            runStore.deliverPending { completion, reply ->
                api.handleCompletedTrack(completion) { result -> reply(result.getOrNull() == true) }
            }
        }
    }

    private fun applyDnd(audioData: AudioData) {
        if (audioData.dndRequested == true) {
            val owner = timerParams?.runId ?: "guided-${System.currentTimeMillis()}-$playbackAttempt"
            if (DndGuard.apply(this, owner, audioData.timerDndRuleName)) dndOwnerId = owner
        } else {
            restoreDnd()
        }
    }

    private fun restoreDnd() {
        DndGuard.restore(this)
        dndOwnerId = null
    }

    private fun primaryPlayerIdle(): Boolean =
        !::primaryPlayer.isInitialized || primaryPlayer.currentMediaItem == null

    private fun syncBackgroundWithPrimaryState() {
        if (!::primaryPlayer.isInitialized || !::backgroundMusicPlayer.isInitialized) {
            return
        }

        try {
            // Un apagado gradual en curso no se interrumpe.
            if (backgroundFadeJob?.isActive == true) return
            // If primary is playing, ensure background is playing too
            if (primaryPlayer.isPlaying && backgroundSoundUri != null) {
                if (!backgroundMusicPlayer.isPlaying) {
                    Log.d(TAG, "🔊 Syncing background sound - playing")
                    playBackgroundSound()
                }
            }
            // If primary is paused/stopped, pause background too
            else if (backgroundMusicPlayer.isPlaying) {
                Log.d(TAG, "🔊 Syncing background sound - pausing")
                backgroundMusicPlayer.pause()
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error syncing background with primary: ${e.message}")
        }
    }

    // Check if service is fully initialized and components are ready
    fun isReady(): Boolean {
        return isServiceFullyInitialized && ::primaryPlayer.isInitialized && ::backgroundMusicPlayer.isInitialized
    }
    
    // Allow setting a callback to be notified when service is ready
    fun checkReadiness(callback: (Boolean) -> Unit) {
        if (isServiceFullyInitialized) {
            callback(true)
        } else {
            readinessCallback = callback
        }
    }

    override fun onBind(intent: Intent?): IBinder? {
        println("🔊 [AudioPlayerService] onBind called with intent action: ${intent?.action}")
        if (intent?.action == ACTION_BIND_SERVICE) {
            println("🔊 [AudioPlayerService] Returning binder")
            return binder
        }
        println("🔊 [AudioPlayerService] Calling super.onBind")
        return super.onBind(intent)
    }

    companion object {
        const val CHANNEL_ID = "medito_reminder_channel"
        const val NOTIFICATION_ID = 101011
        const val TIMER_ALERTS_CHANNEL_ID = "timer_alerts"
        const val TIMER_ALERT_NOTIFICATION_ID = 101012
        private const val DUCK_FACTOR = 0.2f
        private const val STORE_WRITE_INTERVAL_MS = 3000L
        private const val BACKGROUND_FADE_MS = 3000L
        private const val BACKGROUND_FADE_STEPS = 15

        /** True desde onCreate hasta onDestroy (mismo proceso). */
        @Volatile
        var isActive = false

        /** Id de la sesión de temporizador en curso; null si no hay. */
        @Volatile
        var currentRunId: String? = null

        /** Dueño del «No molestar» puesto por la sesión en curso (timer o guiada). */
        @Volatile
        var dndOwnerId: String? = null

        /** Lo usa el receptor del respaldo para pedir al servicio vivo que reprograme. */
        @Volatile
        internal var backupRescheduleHook: (() -> Unit)? = null
        private const val TAG = "MeditoAudioService"
        const val ACTION_BIND_SERVICE = "meditofoundation.medito.BIND_SERVICE"
        const val ACTION_PLAY_PAUSE = "meditofoundation.medito.ACTION_PLAY_PAUSE"
        private val timerBlockedKeys = setOf(
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD,
            KeyEvent.KEYCODE_MEDIA_REWIND
        )
        const val ACTION_TIMER_STOP = "meditofoundation.medito.ACTION_TIMER_STOP"
        const val KEY_TIMER_SEED = "timer_seed"
        const val ACTION_SKIP_FORWARD = "meditofoundation.medito.ACTION_SKIP_FORWARD"
        const val ACTION_SKIP_BACKWARD = "meditofoundation.medito.ACTION_SKIP_BACKWARD"
        private const val KEY_ARTIST_URL = "artistUrl"
        private const val KEY_FILE_ID = "fileId"
        private const val SEEK_INTERVAL_MS = 15_000L
    }
}


/** Retiene Play hasta que estén listos el temporizador y sus campanas. */
internal class TimerStartGate {
    private var current = false
    private var primaryReady = false
    private var bellsReady = false
    private var pendingPlay: (() -> Unit)? = null

    fun reset() {
        current = true
        primaryReady = false
        bellsReady = false
        pendingPlay = null
    }

    fun cancel() {
        current = false
        pendingPlay = null
    }

    fun pause() {
        pendingPlay = null
    }

    fun play(action: () -> Unit) {
        if (!current) return
        pendingPlay = action
        startIfReady()
    }

    fun primaryReady() {
        primaryReady = true
        startIfReady()
    }

    fun bellsReady() {
        bellsReady = true
        startIfReady()
    }

    private fun startIfReady() {
        if (!current || !primaryReady || !bellsReady) return
        val action = pendingPlay
        pendingPlay = null
        action?.invoke()
    }
}


/** Parámetros de una sesión de temporizador que llegan de Dart en [AudioData]. */
internal data class TimerSessionParams(
    val runId: String,
    val ownerId: String,
    val startEpochMs: Long,
    val prepMs: Long,
    val plannedMs: Long,
    val isStopwatch: Boolean,
    val extraTime: Boolean,
    val bellOutput: String,
    val mixWithOthers: Boolean,
    val languageTag: String?,
    val pausedText: String?,
    val prepText: String?,
    val extraTimeText: String?,
    val headphonesPausedText: String?,
    val otherAudioPausedText: String?,
    val alertsChannelName: String?,
    val backupTitle: String?,
    val backupBody: String?,
    val backupChannelName: String?,
    val backupSilentChannelName: String?
) {
    val isPlainCountdown: Boolean get() = !isStopwatch && !extraTime

    /** Momento del archivo en que termina lo planeado (incluye la preparación). */
    val endMs: Long get() = prepMs + plannedMs

    fun elapsedMs(positionMs: Long): Long =
        TimerElapsed.elapsedMs(positionMs, prepMs, plannedMs, extraTime, isStopwatch)

    companion object {
        fun from(audioData: AudioData): TimerSessionParams {
            val isStopwatch = audioData.timerIsStopwatch == true
            val planned = audioData.timerPlannedMs
                ?: if (isStopwatch) TimerElapsed.STOPWATCH_CAP_MS else 0L
            return TimerSessionParams(
                // Sin id de Dart (no debería pasar) se crea uno local para no perder el registro.
                runId = audioData.timerRunId?.takeIf { it.isNotBlank() }
                    ?: java.util.UUID.randomUUID().toString().replace("-", ""),
                ownerId = audioData.timerOwnerId ?: "",
                startEpochMs = System.currentTimeMillis(),
                prepMs = (audioData.timerPrepMs ?: 0L).coerceAtLeast(0L),
                plannedMs = planned.coerceAtLeast(0L),
                isStopwatch = isStopwatch,
                extraTime = !isStopwatch && audioData.timerHasExtraTime == true,
                bellOutput = audioData.timerBellOutput ?: SessionBellPlayer.OUTPUT_SOUND,
                mixWithOthers = audioData.timerMixWithOthers == true,
                languageTag = audioData.timerLanguageTag,
                pausedText = audioData.timerPausedText,
                prepText = audioData.timerPrepText,
                extraTimeText = audioData.timerExtraTimeText,
                headphonesPausedText = audioData.timerHeadphonesPausedText,
                otherAudioPausedText = audioData.timerOtherAudioPausedText,
                alertsChannelName = audioData.timerAlertsChannelName,
                backupTitle = audioData.timerBackupTitle,
                backupBody = audioData.timerBackupBody,
                backupChannelName = audioData.timerBackupChannelName,
                backupSilentChannelName = audioData.timerBackupSilentChannelName
            )
        }
    }
}

/**
 * Fin natural del temporizador (END-01). El final se publica a Dart aunque el
 * guardado haya fallado; lo que dice si quedó guardado es el historial. Por eso
 * un cierre confirmado se entrega al historial en cuanto se guarda, antes de
 * esperar las campanas y de publicar el final; uno fallido no se entrega y
 * queda en `active` para la recuperación, y la pantalla no promete el guardado.
 */
internal object NaturalTimerClose {
    fun deliverBeforeEnd(result: TimerCloseResult?): Boolean = result == TimerCloseResult.SAVED
}
