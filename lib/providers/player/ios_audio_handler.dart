import 'dart:async';
import 'dart:math';
import '../../services/audio/ios_session_bells.dart';
import 'package:flutter/foundation.dart';
import 'package:medito/models/models.dart' show PlaybackRequest;
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_timeline.dart';
import 'package:medito/services/timer/ios_timer_run_store.dart';
import 'package:medito/services/timer/timer_end_backup.dart';
import 'package:medito/services/timer/timer_notices.dart';
import 'package:medito/utils/current_localizations.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/types/type_constants.dart';
import '../../src/audio_pigeon.g.dart';
import '../../utils/stats_updater.dart';
import '../../utils/logger.dart';

/// Único responsable de las interrupciones de audio en iOS (llamadas, otras
/// apps, audífonos) para cualquier sesión. Pausa juntos el reloj, las
/// campanas y el sonido de fondo, y solo reanuda la misma sesión que sonaba.
class TimerInterruptionController {
  TimerInterruptionController({
    required this.isPlaying,
    required this.currentRunId,
    required this.pauseAll,
    required this.resumeAll,
    required this.duck,
    this.onBecomingNoisy,
  });

  final bool Function() isPlaying;
  final String? Function() currentRunId;
  final Future<void> Function() pauseAll;
  final Future<void> Function() resumeAll;
  final void Function(bool ducked) duck;
  final Future<void> Function()? onBecomingNoisy;

  bool _interrupted = false;
  bool _wasPlaying = false;
  String? _runId;
  StreamSubscription<AudioInterruptionEvent>? _interruptions;
  StreamSubscription<void>? _noisy;

  void attach(
    Stream<AudioInterruptionEvent> interruptions,
    Stream<void> becomingNoisy,
  ) {
    _interruptions?.cancel();
    _noisy?.cancel();
    _interruptions = interruptions.listen(
      (event) => unawaited(handleInterruption(event)),
    );
    _noisy = becomingNoisy.listen((_) => unawaited(handleBecomingNoisy()));
  }

  Future<void> handleInterruption(AudioInterruptionEvent event) async {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          duck(true);
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          // Lee el estado ANTES de pausar; una segunda interrupción no lo pisa.
          if (!_interrupted) {
            _wasPlaying = isPlaying();
            _runId = currentRunId();
            _interrupted = true;
          }
          await pauseAll();
      }
      return;
    }
    switch (event.type) {
      case AudioInterruptionType.duck:
        duck(false);
      case AudioInterruptionType.pause:
        final resume = _interrupted && _wasPlaying && _runId == currentRunId();
        _reset();
        if (resume) await resumeAll();
      case AudioInterruptionType.unknown:
        // El sistema no permite reanudar: queda en pausa.
        _reset();
    }
  }

  Future<void> handleBecomingNoisy() async {
    _reset();
    await (onBecomingNoisy ?? pauseAll)();
  }

  void _reset() {
    _interrupted = false;
    _wasPlaying = false;
    _runId = null;
  }
}

class IosAudioHandler extends BaseAudioHandler {
  final AudioPlayer _player;
  late final sessionBells = IosSessionBells(_player);
  final IosTimerRunStore? _runStore;
  final TimerEndBackup? _endBackup;
  IosTimerRunStore get runStore => _runStore ?? IosTimerRunStore.instance;
  TimerEndBackup get endBackup => _endBackup ?? TimerEndBackup.instance;
  late final interruptions = TimerInterruptionController(
    isPlaying: () => _player.playing,
    currentRunId: () => _sessionKey,
    pauseAll: _pauseForInterruption,
    resumeAll: play,
    duck: (ducked) {
      sessionBells.duck(ducked);
      duckAmbient?.call(ducked);
    },
    onBecomingNoisy: () async {
      final isTimer = _isTimer;
      await pause();
      await sessionBells.pauseForInterruption();
      if (isTimer) {
        unawaited(
          TimerNotices.showPaused(currentLocalizations().timerHeadphonesPaused),
        );
      }
    },
  );

  /// Pausa, reanuda y baja el sonido de fondo; los conecta PlayerProvider con
  /// el notificador de sonidos de fondo.
  void Function()? pauseAmbient;
  void Function()? resumeAmbient;
  void Function(bool ducked)? duckAmbient;

  PlaybackRequest? _timerRequest;
  bool _timerCompleting = false;
  bool _endPassedSeen = false;

  /// La solicitud del temporizador en curso, si hay una.
  PlaybackRequest? get timerRequest => _isTimer ? _timerRequest : null;

  /// El `runId` del temporizador en curso, o null en una meditación guiada.
  String? get timerRunId => timerRequest?.timerRunId;

  /// Verdadero mientras el final natural del temporizador suelta el audio.
  bool get timerCompleting => _timerCompleting;

  String get _sessionKey => timerRunId ?? 'guided-$_startGeneration';
  // Distinguish a repeat boundary from terminal completion; never wait for bells.
  final _sessionCompleted = BehaviorSubject<bool>.seeded(false);
  bool _isInitialized = false;
  bool _hasExtraTime = false;
  bool _isTimer = false;
  int _startGeneration = 0;
  bool _discarded = false;
  bool _timerPlayBlocked = false;
  Completer<bool>? _timerReady;
  int _playGeneration = 0;
  Future<void> Function()? onTimerStop;
  RepeatMode _currentRepeatMode = RepeatMode.none;
  bool _hasReplayedOnce = false;

  /// Full play-throughs of the current track, counting repeats. The first is
  /// recorded as the session; each later one only adds its listening time.
  int _completedPlaythroughs = 0;

  /// While the player is paused the audio session is kept active so a quick
  /// resume stays seamless and the lock-screen controls remain. If the pause
  /// lasts longer than this the user has likely walked away, so the session is
  /// released to stop iOS keeping the app alive in the background.
  static const _pauseGracePeriod = Duration(minutes: 3);
  Timer? _pauseDeactivationTimer;

  IosAudioHandler({
    AudioPlayer? player,
    IosTimerRunStore? runStore,
    TimerEndBackup? endBackup,
  }) : _player = player ?? AudioPlayer(handleInterruptions: false),
       _runStore = runStore,
       _endBackup = endBackup;

  /// Configuración de la sesión: con «Música de otras apps» activado se
  /// mezcla con ellas; si no, la otra app se pausa (decisión 2).
  static AudioSessionConfiguration sessionConfiguration({
    required bool mixWithOthers,
  }) => AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.playback,
    avAudioSessionCategoryOptions: mixWithOthers
        ? AVAudioSessionCategoryOptions.mixWithOthers
        : AVAudioSessionCategoryOptions.none,
    avAudioSessionMode: AVAudioSessionMode.defaultMode,
    avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
  );

  /// Se llama antes de cada inicio (temporizador: preferencia; guiada: no).
  Future<void> configureSession({required bool mixWithOthers}) async {
    try {
      final session = await AudioSession.instance;
      await session.configure(
        sessionConfiguration(mixWithOthers: mixWithOthers),
      );
    } catch (e) {
      AppLogger.e('IOS', 'No se pudo configurar la sesión de audio: $e');
    }
  }

  Future<void> _pauseForInterruption() async {
    await Future.wait([pause(), sessionBells.pauseForInterruption()]);
  }

  Future<void> ensureInitialized() async {
    if (_isInitialized) return;

    try {
      final session = await AudioSession.instance;

      // Un solo controlador para llamadas, otras apps y audífonos.
      interruptions.attach(
        session.interruptionEventStream,
        session.becomingNoisyEventStream,
      );

      await session.configure(sessionConfiguration(mixWithOthers: false));

      _setupPlaybackState();
      _setupEventListeners();

      _isInitialized = true;
    } catch (e) {
      AppLogger.e('IOS', 'Failed to initialize audio session: $e');
      rethrow;
    }
  }

  void _setupPlaybackState() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.rewind,
          MediaControl.play,
          MediaControl.fastForward,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setSpeed,
          MediaAction.pause,
          MediaAction.play,
        },
        playing: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
      ),
    );
  }

  void _setupEventListeners() {
    iosStateStream.listen((event) {
      mediaItem.add(
        MediaItem(
          id: event.track.toString(),
          title: event.track.title,
          artist: event.track.artist,
          duration: _hasExtraTime ? null : event.duration,
          // A timer session has no cover; an empty URI is not "no art".
          artUri: event.track.imageUrl.isEmpty
              ? null
              : Uri.parse(event.track.imageUrl),
          playable: true,
          displayTitle: event.track.title,
          displaySubtitle: event.track.artist,
        ),
      );

      playbackState.add(
        playbackState.value.copyWith(
          updatePosition: event.position,
          bufferedPosition: event.bufferedPosition,
          speed: event.speed,
          playing: event.playerState.playing,
        ),
      );
    });

    _player.positionStream.listen((_) => _trackTimerPosition());
    _player.playingStream.listen((playing) {
      // Una pausa (manual o por interrupción) guarda la posición de inmediato.
      if (!playing) _trackTimerPosition(force: true);
    });

    _player.processingStateStream.listen((state) async {
      if (state != ProcessingState.completed) _sessionCompleted.add(false);
      if (state == ProcessingState.completed &&
          !_discarded &&
          _isTimer &&
          _timerRequest != null) {
        await completeTimer();
        return;
      }
      if (state == ProcessingState.completed && !_discarded) {
        final accountGeneration = PlaybackAccount.generation;
        // Handle repeat once mode
        if (_currentRepeatMode == RepeatMode.once && !_hasReplayedOnce) {
          _hasReplayedOnce = true;
          unawaited(_recordPlaythrough());
          await _player.seek(Duration.zero);
          if (!_discarded && PlaybackAccount.isCurrent(accountGeneration)) {
            await _player.play();
          }
          return;
        }

        _sessionCompleted.add(true);

        // Playback has finished and is not repeating. Release the audio
        // session first so iOS does not keep the app alive in the background,
        // which otherwise drains battery for as long as the session stays
        // active after the meditation ends. Reporting the completion runs
        // afterwards because it does network/I/O that can be slow and must
        // not delay session release.
        _cancelPauseDeactivationTimer();
        // The ambient background player loops and keeps rendering audio after
        // the narration ends; pause it first so the shared session is idle and
        // iOS will actually let us deactivate it (a busy session is rejected).
        final generation = _startGeneration;
        await Future.wait([
          sessionBells.disable(),
          iosBackgroundPlayer.pause(),
        ]);
        if (generation != _startGeneration) return;
        await _deactivateSession();

        if (!_discarded && PlaybackAccount.isCurrent(accountGeneration)) {
          await _recordPlaythrough();
        }
      }
    });

    // Repeat forever (LoopMode.one) never reaches `completed`; each loop back
    // to the start surfaces as an auto-advance discontinuity instead.
    // just_audio also reports autoAdvance when a new source is loaded, so only
    // count it when the same, already-playing item wrapped around.
    _player.positionDiscontinuityStream.listen((discontinuity) {
      final prev = discontinuity.previousEvent;
      final curr = discontinuity.event;
      const active = {ProcessingState.ready, ProcessingState.buffering};
      final isLoop =
          discontinuity.reason == PositionDiscontinuityReason.autoAdvance &&
          _currentRepeatMode == RepeatMode.infinite &&
          active.contains(prev.processingState) &&
          active.contains(curr.processingState) &&
          prev.duration != null &&
          prev.duration == curr.duration;
      if (isLoop) unawaited(_recordPlaythrough());
    });

    _player.playbackEventStream.listen((event) {
      final playing = _player.playing;

      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            if (!_isTimer) MediaControl.rewind,
            if (playing) MediaControl.pause else MediaControl.play,
            if (!_isTimer) MediaControl.fastForward,
            if (_isTimer) MediaControl.stop,
          ],
          systemActions: {
            // Un temporizador nunca se adelanta ni se regresa.
            if (!_isTimer) ...const {
              MediaAction.seek,
              MediaAction.seekForward,
              MediaAction.seekBackward,
            },
            if (!_isTimer) MediaAction.setSpeed,
            MediaAction.pause,
            MediaAction.play,
            if (_isTimer) MediaAction.stop,
          },
          playing: playing,
          processingState: const {
            ProcessingState.idle: AudioProcessingState.idle,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[_player.processingState]!,
          updatePosition: _player.position,
          bufferedPosition: _player.bufferedPosition,
          speed: _player.speed,
        ),
      );
    });
  }

  /// Guarda la posición del temporizador (cada 3 s, o ya con [force]) y
  /// marca el final cuando la posición lo pasa (R79).
  void _trackTimerPosition({bool force = false}) {
    final request = timerRequest;
    if (request == null || _discarded || _timerCompleting) return;
    final position = _player.position.inMilliseconds;
    final untilEnd = TimerTimeline.fromRequest(request).untilEndCueMs(position);
    final passed = untilEnd != null && untilEnd <= 0;
    if (passed && !_endPassedSeen) {
      _endPassedSeen = true;
      unawaited(endBackup.cancel());
    }
    unawaited(
      runStore.updatePosition(
        request.timerRunId,
        position,
        force: force,
        endPassed: passed ? true : null,
      ),
    );
  }

  /// Final natural del temporizador: guarda el cierre con el tiempo planeado
  /// ANTES de soltar el audio, deja sonar completas las campanas pendientes
  /// (máximo 60 s) y luego entrega la sesión a las estadísticas.
  @visibleForTesting
  Future<void> completeTimer() async {
    final request = _timerRequest;
    if (request == null || _timerCompleting) return;
    _timerCompleting = true;
    final generation = _startGeneration;
    final accountGeneration = PlaybackAccount.generation;
    try {
      final timeline = TimerTimeline.fromRequest(request);
      final durationMs = max(
        request.plannedDurationMs,
        timeline.elapsedMs(_player.position.inMilliseconds),
      );
      // Si el guardado falla, el registro conserva el tiempo final en memoria
      // y lo guarda en la siguiente escritura.
      await runStore.finish(
        runId: request.timerRunId,
        durationMs: durationMs,
        fallback: TimerRunStart.fromRequest(request),
        generation: accountGeneration,
        keepForRetry: true,
      );
      unawaited(endBackup.cancel());
      _cancelPauseDeactivationTimer();
      await sessionBells.waitTimerBells();
      if (generation != _startGeneration) return;
      // El final se publica cuando ya sonaron las campanas: la pantalla apaga
      // las campanas al verlo y no debe cortar una atrasada.
      _sessionCompleted.add(true);
      await Future.wait([sessionBells.disable(), _pauseAmbient()]);
      if (generation != _startGeneration) return;
      await _deactivateSession();
    } finally {
      _timerCompleting = false;
      if (PlaybackAccount.isCurrent(accountGeneration)) {
        unawaited(runStore.deliver());
      }
    }
  }

  Future<void> _pauseAmbient() async {
    final pause = pauseAmbient;
    if (pause != null) {
      pause();
    } else {
      await iosBackgroundPlayer.pause();
    }
  }

  Duration get position => _player.position;

  bool get playing => _player.playerState.playing;

  bool get isComplete =>
      _player.playerState.processingState == ProcessingState.completed;

  final _trackStateSubject = BehaviorSubject<Track>();

  Track get trackState => _trackStateSubject.value;

  Stream<Track> get _trackStateStream => _trackStateSubject.stream;

  Stream<Duration> get positionStream => _player.positionStream;

  Duration? get duration => _player.duration;

  Stream<IosStateData> get iosStateStream =>
      Rx.combineLatest7<
        double,
        PlayerState,
        Track,
        Duration,
        Duration,
        Duration?,
        bool,
        IosStateData
      >(
        _player.speedStream,
        _player.playerStateStream,
        _trackStateStream,
        _player.positionStream,
        _player.bufferedPositionStream,
        _player.durationStream,
        _sessionCompleted.stream,
        (speed, state, track, position, bufferedPosition, duration, completed) {
          return IosStateData(
            speed,
            state.processingState == ProcessingState.completed && !completed
                ? PlayerState(false, ProcessingState.ready)
                : state,
            track,
            position,
            bufferedPosition,
            duration ?? Duration.zero,
          );
        },
      );

  Future<void> _recordPlaythrough() {
    if (_discarded) return Future.value();
    _completedPlaythroughs++;
    if (_completedPlaythroughs == 1) return _storeTrackCompletion();
    return _storeRepeatPlaythrough();
  }

  Future<void> _storeRepeatPlaythrough() async {
    try {
      if (duration == null) return;
      await handleRepeatPlaythrough({
        TypeConstants.trackIdKey: trackState.id,
        TypeConstants.durationIdKey: duration!.inMilliseconds,
        TypeConstants.fileIdKey: trackState.fileId,
        TypeConstants.guideIdKey: trackState.artist ?? '',
        TypeConstants.timestampIdKey: DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      AppLogger.e('IOS', 'Error recording repeat play-through: $e');
    }
  }

  Future<void> _storeTrackCompletion() async {
    try {
      if (duration == null) return;

      final accountGeneration = PlaybackAccount.generation;
      final payload = _createTrackCompletionPayload();
      if (!PlaybackAccount.isCurrent(accountGeneration)) return;

      // Try to update stats immediately
      if (await _tryUpdateStats(payload)) {
        return;
      }

      // Failed to update stats directly, store for later processing
      if (PlaybackAccount.isCurrent(accountGeneration)) {
        await _storeForLaterProcessing(payload, accountGeneration);
      }
    } catch (e) {
      AppLogger.e(
        'IOS',
        'Error processing track completion in AudioHandler: $e',
      );
    }
  }

  /// Creates a payload map with all track completion data
  Map<String, dynamic> _createTrackCompletionPayload() {
    return {
      TypeConstants.trackIdKey: trackState.id,
      TypeConstants.durationIdKey: duration?.inMilliseconds ?? 0,
      TypeConstants.fileIdKey: trackState.fileId,
      TypeConstants.guideIdKey: trackState.artist ?? '',
      TypeConstants.timestampIdKey: DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// Try to update stats directly and return success status
  Future<bool> _tryUpdateStats(Map<String, dynamic> payload) async {
    try {
      AppLogger.d('IOS', 'Track completed: ${trackState.id}');
      final success = await handleStats(payload);

      if (success) {
        AppLogger.d('IOS', 'Successfully updated stats from audio handler');
        return true;
      }
    } catch (e) {
      AppLogger.e(
        'IOS',
        'Error updating stats directly from audio handler: $e',
      );
    }
    return false;
  }

  /// Store track completion data for later processing
  Future<void> _storeForLaterProcessing(
    Map<String, dynamic> payload,
    int accountGeneration,
  ) async {
    AppLogger.d(
      'IOS',
      'Storing track completion for later processing: ${trackState.id}',
    );
    final prefs = await SharedPreferences.getInstance();
    if (PlaybackAccount.isCurrent(accountGeneration)) {
      await storeTrackCompletion(prefs, payload);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (_isTimer) return;
    return _player.seek(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (_isTimer) return;
    return _player.setSpeed(speed);
  }

  Future<void> setCustomRepeatMode(RepeatMode mode) async {
    _currentRepeatMode = mode;
    _hasReplayedOnce = false;

    switch (mode) {
      case RepeatMode.none:
        await _player.setLoopMode(LoopMode.off);
        break;
      case RepeatMode.once:
        await _player.setLoopMode(LoopMode.off);
        break;
      case RepeatMode.infinite:
        await _player.setLoopMode(LoopMode.one);
        break;
    }
  }

  @override
  Future<void> play() async {
    final generation = _startGeneration;
    final playGeneration = ++_playGeneration;
    final account = PlaybackAccount.generation;
    bool isCurrent() =>
        (!_discarded || _timerReady != null) &&
        !_timerPlayBlocked &&
        generation == _startGeneration &&
        playGeneration == _playGeneration &&
        PlaybackAccount.isCurrent(account);

    if (!isCurrent()) return;
    final ready = _timerReady;
    if (ready != null && !await ready.future) return;
    if (!isCurrent()) return;
    _cancelPauseDeactivationTimer();

    final session = await AudioSession.instance;
    if (!isCurrent()) return;
    await session.setActive(true);
    if (!isCurrent() || (_isTimer && _player.playing)) return;

    unawaited(_player.play());
    // Bells follow _player on their own; resume the ambient sound if any.
    if (iosAmbientActive) {
      final resume = resumeAmbient;
      if (resume != null) {
        resume();
      } else {
        unawaited(iosBackgroundPlayer.play());
      }
    }
  }

  @override
  Future<void> pause() async {
    _playGeneration++;
    unawaited(_player.pause());
    unawaited(_pauseAmbient());

    // Keep the session active for a quick resume, but release it if the pause
    // is prolonged so iOS stops keeping the app alive in the background.
    _schedulePauseDeactivation();
  }

  @override
  Future<void> stop() async {
    final close = onTimerStop;
    if (_isTimer && close != null && (_timerReady != null || !isComplete)) {
      await close();
      return;
    }
    await stopPlayback();
  }

  Future<void> discardPlayback() async {
    _discarded = true;
    onTimerStop = null;
    // Primero se detiene el fondo y se espera: con la marca apagada, la
    // función conectada ya no lo pausaría (R38).
    try {
      await (stopAmbientPlayer ?? iosBackgroundPlayer.pause)();
    } catch (error) {
      AppLogger.e('IOS', 'No se pudo detener el sonido de fondo: $error');
    }
    iosAmbientActive = false;
    await stopPlayback();
  }

  /// Detiene el reproductor de fondo; se reemplaza en pruebas.
  @visibleForTesting
  Future<void> Function()? stopAmbientPlayer;

  /// Detiene solo si [runId] sigue siendo la sesión cargada: una parada que
  /// llega tarde nunca corta una sesión nueva.
  Future<void> stopRun(String runId, {bool full = true}) async {
    if (timerRunId != runId) return;
    await stopPlayback(full: full);
  }

  /// Detiene la sesión. Con [full] (por omisión, también al descartar por un
  /// cambio de cuenta, R38) para todo de inmediato: reloj, campanas, sonido de
  /// fondo y sesión de audio. El cierre propio de PlayerProvider usa
  /// `full: false` en un temporizador: solo para el reloj y las campanas, y
  /// después apaga el fondo con desvanecido y desactiva la sesión.
  Future<void> stopPlayback({bool full = true}) async {
    if (_isTimer) _timerPlayBlocked = true;
    _cancelTimerStart();
    final generation = ++_startGeneration;
    _cancelPauseDeactivationTimer();
    unawaited(endBackup.cancel());
    if (_isTimer) {
      await Future.wait([
        sessionBells.disable(),
        _player.stop(),
        if (full) _pauseAmbient(),
      ]);
    } else {
      await sessionBells.disable();
      // iOS solo desactiva la sesión cuando los reproductores se detienen.
      await _player.stop();
      await _pauseAmbient();
    }
    if (generation == _startGeneration) {
      unawaited(super.stop());
      if (full || !_isTimer) await _deactivateSession();
    }
  }

  /// Desactiva la sesión de audio al final del cierre propio del temporizador.
  Future<void> deactivateSession() => _deactivateSession();

  /// Schedules release of the audio session after [_pauseGracePeriod] if the
  /// player is still paused, so an abandoned pause does not keep the app in
  /// background-audio state indefinitely.
  void _schedulePauseDeactivation() {
    _pauseDeactivationTimer?.cancel();
    _pauseDeactivationTimer = Timer(_pauseGracePeriod, () {
      if (!_player.playing) {
        unawaited(_deactivateSession());
      }
    });
  }

  void _cancelPauseDeactivationTimer() {
    _pauseDeactivationTimer?.cancel();
    _pauseDeactivationTimer = null;
  }

  /// Deactivates the iOS audio session so the OS stops treating the app as an
  /// active background-audio app. Without this, the session activated in
  /// [play] stays active after playback stops/completes and keeps the app
  /// running in the background, draining the battery. The
  /// `notifyOthersOnDeactivation` option lets other apps (e.g. music) resume
  /// once we release the session.
  Future<void> _deactivateSession() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(
        false,
        avAudioSessionSetActiveOptions:
            AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
      );
    } catch (e) {
      AppLogger.e('IOS', 'Failed to deactivate audio session: $e');
    }
  }

  void cancelPendingTimerStart() {
    if (!_isTimer) return;
    _playGeneration++;
    _timerPlayBlocked = true;
    if (_timerReady == null) return;
    _startGeneration++;
    _cancelTimerStart();
    unawaited(sessionBells.disable());
  }

  void _cancelTimerStart() {
    _timerReady?.complete(false);
    _timerReady = null;
  }

  Future<void> setUrl(
    String? downloadPath,
    PlaybackRequest request,
    Track trackData, {
    ({bool enabled, double volume})? timerBells,
  }) async {
    final generation = ++_startGeneration;
    final wasTimer = _isTimer;
    _isTimer = request.isTimer;
    _hasExtraTime = request.hasExtraTime;
    _timerRequest = request.isTimer ? request : null;
    _timerCompleting = false;
    _endPassedSeen = false;
    sessionBells.onEndCueStarted = request.isTimer
        ? () => unawaited(runStore.markEndPassed(request.timerRunId))
        : null;
    _cancelTimerStart();
    final ready = request.isTimer ? Completer<bool>() : null;
    _timerReady = ready;
    _timerPlayBlocked = wasTimer && !request.isTimer;
    final discardingBells = wasTimer ? sessionBells.disable() : null;
    try {
      await discardingBells;
      await ensureInitialized();
      if (generation != _startGeneration) return;
      if (wasTimer || request.isTimer) {
        await _player.pause();
        if (generation != _startGeneration) return;
        await _player.setSpeed(1.0);
        if (generation != _startGeneration) return;
      }

      _hasReplayedOnce = false;
      _completedPlaythroughs = 0;
      _sessionCompleted.add(false);
      sessionBells.reset();

      await sessionBells.setBellCues(
        cues: request.isTimer ? request.timerBellCues ?? const [] : null,
        enabled: timerBells?.enabled ?? false,
        volume: timerBells?.volume ?? 0,
        output: request.timerBellOutput,
      );
      if (generation != _startGeneration) return;

      if (downloadPath == null) {
        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(request.remoteUrl)),
        );
      } else {
        await _player.setAsset(downloadPath);
      }
      if (generation != _startGeneration) return;
      await setCustomRepeatMode(_currentRepeatMode);
      if (generation != _startGeneration) return;

      _discarded = false;
      _timerPlayBlocked = false;
      _trackStateSubject.add(trackData);
      ready?.complete(true);
    } finally {
      if (generation == _startGeneration) {
        if (ready != null && !ready.isCompleted) {
          _timerPlayBlocked = true;
          ready.complete(false);
        }
        _timerReady = null;
      }
    }
  }
}

class IosStateData {
  final double speed;
  final PlayerState playerState;
  final Track track;
  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;

  IosStateData(
    this.speed,
    this.playerState,
    this.track,
    this.position,
    this.bufferedPosition,
    this.duration,
  );
}
