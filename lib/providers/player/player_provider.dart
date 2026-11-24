import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/models/models.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/last_timer_store.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_timeline.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/dnd_provider.dart';
import 'package:medito/providers/timer/timer_preferences_provider.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/services/analytics/firebase_analytics_service.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/services/review_service.dart';
import 'package:medito/services/timer/ios_timer_run_store.dart';
import 'package:medito/services/timer/timer_device_channel.dart';
import 'package:medito/services/timer/timer_end_backup.dart';
import 'package:medito/services/timer/timer_shortcuts_service.dart';
import 'package:medito/utils/current_localizations.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../timer/timer_session_closer.dart';

import '../../models/player/repeat_mode.dart' as app_repeat;
import '../../src/audio_pigeon.g.dart' as pigeon;
import '../../utils/utils.dart';
import 'audio_state_provider.dart';
import 'download/audio_downloader_provider.dart';
import 'ios_audio_handler.dart';
import 'repeat_state_provider.dart';
import '../../utils/audio_session_tracker.dart';
import '../../utils/logger.dart';

final _api = pigeon.MeditoAudioServiceApi();
final _androidServiceApi = pigeon.MeditoAndroidAudioServiceManager();
late IosAudioHandler iosAudioHandler;

final playerProvider = NotifierProvider<PlayerProvider, PlaybackRequest?>(() {
  return PlayerProvider();
});

class PlayerProvider extends Notifier<PlaybackRequest?>
    implements pigeon.MeditoTimerStopCallbackApi {
  PlayerProvider({
    bool? useAndroidAudio,
    Duration? startConfirmTimeout,
    Duration Function()? sitClock,
  }) : _usesAndroidAudio = useAndroidAudio ?? Platform.isAndroid,
       _sitClock = sitClock,
       _startConfirmTimeout =
           startConfirmTimeout ?? const Duration(seconds: 10);

  final bool _usesAndroidAudio;
  final Duration _startConfirmTimeout;
  final Duration Function()? _sitClock;
  final _sitStopwatch = Stopwatch()..start();
  SitOutcome? _sitOutcome;
  _PlaybackStart? _start;
  final _timerCloses = StreamController<TimerRunCloseResult>.broadcast();
  PlaybackRequest? _activeTimer;
  TimerSessionCloser? _timerCloser;
  String? _reservedRunId;
  bool _sessionOpen = false;
  _StartWatch? _startWatch;
  bool? _backupPlaying;

  /// Publica el `runId` de un temporizador que no pudo iniciar (R56, R68):
  /// `play` lanzó un error, Android reportó un error de ese mismo `runId`
  /// antes de confirmar, o no llegó un estado «sonando» en 10 s. PlayerView
  /// (W2-RUNNING) muestra `timerStartError` solo para su propio `runId`.
  final timerStartFailed = ValueNotifier<String?>(null);

  Object get playbackIdentity => (_start, _start?.cancelled);
  PlaybackRequest? get activeTimerRequest =>
      _start?.isCurrent == true ? _activeTimer : null;

  Stream<TimerRunCloseResult> get timerCloses => _timerCloses.stream;

  /// Marca de la sesión del reproductor: cambia cuando otra sesión se prepara
  /// o empieza. Una pantalla la toma al programar un cierre diferido y la
  /// compara al ejecutarlo; si cambió, no toca la sesión nueva (TMR-03).
  Object get sessionMark {
    PlaybackRequest? request;
    try {
      request = stateOrNull;
    } on StateError {
      // El proveedor ya se desechó: ninguna sesión sigue siendo la misma.
    }
    return PlayerSessionMark(_start, request);
  }

  SitOutcome? takeSitOutcome() {
    final outcome = _sitOutcome;
    _sitOutcome = null;
    final start = _start;
    return start != null && PlaybackAccount.isCurrent(start.accountGeneration)
        ? outcome
        : null;
  }

  /// Verdadero mientras una sesión (temporizador o guiada) está reservada,
  /// empezando, sonando o en pausa, y no se ha cerrado.
  bool get hasActiveSession {
    _expireForAccountChange();
    return _reservedRunId != null || _sessionOpen;
  }

  // Generación de cuenta de la reserva o sesión abierta.
  int _sessionAccount = PlaybackAccount.generation;

  /// Al cambiar o borrar la cuenta el audio ya se detuvo: también se sueltan
  /// la reserva y el estado del inicio de la cuenta anterior.
  void _expireForAccountChange() {
    if (_reservedRunId == null && !_sessionOpen) return;
    if (PlaybackAccount.isCurrent(_sessionAccount)) return;
    _start?.cancelled = true;
    _activeTimer = null;
    _endSession();
  }

  /// Reserva el inicio de un temporizador de forma SÍNCRONA, antes de
  /// cualquier espera. Falso si ya hay una sesión activa u otra reserva.
  bool reserveStart(String runId) {
    if (runId.isEmpty || hasActiveSession) return false;
    _reservedRunId = runId;
    _sessionAccount = PlaybackAccount.generation;
    return true;
  }

  bool isReserved(String runId) {
    _expireForAccountChange();
    return runId.isNotEmpty && _reservedRunId == runId;
  }

  /// Suelta una reserva que no llegó a `play`.
  void releaseStart(String runId) {
    if (_reservedRunId == runId) _reservedRunId = null;
  }

  /// Dueño de las estadísticas al reservar (§4.6).
  String get statsOwnerId => StatsManager().verifiedUserId ?? '';

  @override
  PlaybackRequest? build() {
    ref.listen<pigeon.PlaybackState>(
      audioStateProvider,
      (previous, next) => _onAudioState(previous, next),
    );
    final errors = timerPlayerErrors.stream.listen(_onPlayerError);
    ref.onDispose(() {
      _start?.cancelled = true;
      _startWatch?.cancel();
      unawaited(errors.cancel());
      unawaited(_timerCloses.close());
      timerStartFailed.dispose();
    });
    return null;
  }

  void _endSession() {
    _sessionOpen = false;
    _reservedRunId = null;
    _startWatch?.cancel();
    _startWatch = null;
    _backupPlaying = null;
  }

  void _onAudioState(
    pigeon.PlaybackState? previous,
    pigeon.PlaybackState next,
  ) {
    _trackSitState(next);
    final watch = _startWatch;
    final request = _activeTimer;
    if (watch != null && !watch.failed && next.runId == watch.runId) {
      if (next.isPlaying && next.position > 0) {
        _startWatch = null;
        watch.cancel();
        unawaited(_commitLastTimer(watch.runId));
      } else if (next.waitingForFocus == true && !next.isPlaying) {
        // La sesión ya cargó y su reloj espera el foco (una llamada): no es
        // una carga fallida y el plazo no corre mientras espera (REV-06).
        watch.hold();
      } else if (watch.held && next.isPlaying) {
        // El reloj ya puede avanzar: el plazo de confirmación empieza ahora.
        watch.arm(_startConfirmTimeout, () => unawaited(_failStart(watch)));
      }
    }
    if (request != null &&
        !_usesAndroidAudio &&
        next.runId == request.timerRunId) {
      _syncEndBackup(request, next);
    }
    final current = state;
    if (next.isCompleted &&
        previous?.isCompleted != true &&
        current != null &&
        next.track.fileId == current.fileId &&
        (!current.isTimer || next.runId == current.timerRunId)) {
      _endSession();
      if (current.isTimer && !_usesAndroidAudio) {
        unawaited(_endBackup.cancel());
      }
    }
  }

  Duration get _sitNow => _sitClock?.call() ?? _sitStopwatch.elapsed;

  void _trackSitState(pigeon.PlaybackState audio) {
    final start = _start;
    if (start == null ||
        !start.requested ||
        start.sitClosed ||
        !PlaybackAccount.isCurrent(start.accountGeneration) ||
        (start.cancelled && !(_timerCloser?.isClosing ?? false))) {
      return;
    }
    final request = start.request;
    if (audio.track.fileId != request.fileId ||
        audio.runId != (request.isTimer ? request.timerRunId : null)) {
      return;
    }

    if (request.isTimer) {
      // iOS: al terminar solo, el controlador publica el resultado de la
      // campana final con su `runId` antes de soltar las campanas (SIT-01).
      start.sitEndCueRang |= _usesAndroidAudio
          ? audio.endCueRang == true
          : iosAudioHandler.timerEndCueRang(request.timerRunId);
    }
    if (audio.isCompleted) {
      if (!start.cancelled) _finishSit(start, naturalEnd: true);
      return;
    }
    if (audio.isPlaying) {
      start.sitPlayed |= audio.position > 0;
      start.endSitPause(_sitNow);
    } else if (start.sitPlayed &&
        (audio.waitingForFocus == true ||
            (!audio.isBuffering && !audio.isSeeking))) {
      // La espera al final del archivo deja sonar las campanas pendientes.
      final waitingForBells =
          request.isTimer &&
          (_usesAndroidAudio
              ? audio.duration > 0 && audio.position >= audio.duration
              : iosAudioHandler.isComplete);
      if (waitingForBells) {
        start.endSitPause(_sitNow);
      } else {
        start.sitPauseStart ??= _sitNow;
      }
    }
  }

  void _finishSit(_PlaybackStart start, {required bool naturalEnd}) {
    if (start.sitClosed) return;
    start.sitClosed = true;
    start.endSitPause(_sitNow);
    _sitOutcome = SitOutcome(
      isTimer: start.request.isTimer,
      naturalEnd: naturalEnd,
      endCueRang: start.sitEndCueRang,
      pausedMs: start.sitPaused.inMilliseconds,
    );
  }

  TimerEndBackup get _endBackup => TimerEndBackup.instance;

  /// Tiempo hasta el aviso de respaldo en iOS: solo en cuenta regresiva,
  /// antes del final y si la campana final aún no empezó (R70, R79).
  @visibleForTesting
  static Duration? iosBackupRemaining(
    PlaybackRequest request,
    int positionMs, {
    required bool endPassed,
  }) {
    if (!request.isTimer ||
        request.timerMode != TimerMode.countdown ||
        endPassed) {
      return null;
    }
    final remaining = TimerTimeline.fromRequest(
      request,
    ).untilEndCueMs(positionMs);
    if (remaining == null || remaining <= 0) return null;
    return Duration(milliseconds: remaining);
  }

  // Programa el aviso al empezar o reanudar y lo cancela en pausa.
  void _syncEndBackup(PlaybackRequest request, pigeon.PlaybackState audio) {
    if (request.timerMode != TimerMode.countdown) return;
    if (audio.isCompleted) return;
    if (_backupPlaying == audio.isPlaying) return;
    _backupPlaying = audio.isPlaying;
    if (!audio.isPlaying) {
      unawaited(_endBackup.cancel());
      return;
    }
    final remaining = iosBackupRemaining(
      request,
      audio.position,
      endPassed: IosTimerRunStore.instance.endPassed(request.timerRunId),
    );
    if (remaining == null) return;
    unawaited(
      _endBackup.schedule(
        remaining: remaining,
        minutes: request.plannedDurationMs ~/ Duration.millisecondsPerMinute,
        output: request.timerBellOutput,
      ),
    );
  }

  // «Repetir»: guarda los ajustes solo cuando la sesión de verdad suena (R33).
  Future<void> _commitLastTimer(String runId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await LastTimerStore.commitStaged(prefs, runId);
      unawaited(TimerShortcutsService.refresh());
    } catch (error) {
      AppLogger.e('TIMER', 'No se pudo guardar el último temporizador', error);
    }
  }

  void _onPlayerError(String? runId) {
    final watch = _startWatch;
    if (runId == null || watch == null || watch.runId != runId) return;
    unawaited(_failStart(watch));
  }

  /// Un inicio fallido detiene el reproductor, suelta la reserva, no guarda
  /// nada y publica [timerStartFailed].
  Future<void> _failStart(_StartWatch watch) async {
    if (watch.failed) return;
    watch.failed = true;
    watch.cancel();
    if (identical(_startWatch, watch)) _startWatch = null;
    final start = watch.start;
    final request = watch.request;
    if (identical(_start, start) && !_usesAndroidAudio) {
      iosAudioHandler.cancelPendingTimerStart();
    }
    start.cancelled = true;
    timerStartFailed.value = watch.runId;
    try {
      if (_usesAndroidAudio) {
        // La parada nativa va ligada a la semilla de ESTA sesión.
        final seed = request.timerSeed;
        if (start.requested && seed != null) {
          await _api.stopTimerPlayback(seed, false);
        }
      } else {
        // Solo detiene si sigue cargada esta sesión; luego borra su registro.
        await iosAudioHandler.stopRun(request.timerRunId);
        await IosTimerRunStore.instance.discard(
          request.timerRunId,
          generation: start.accountGeneration,
        );
      }
    } catch (error, stack) {
      AppLogger.e(
        'PLAYER',
        'No se pudo detener el inicio fallido',
        error,
        stack,
      );
    }
    // Tras cada espera se revisa que siga siendo la misma sesión.
    if (identical(_start, start)) {
      _activeTimer = null;
      _endSession();
    }
  }

  /// Starts (or restarts) playback for [request]. The provider's state holds
  /// the same [PlaybackRequest] for the lifetime of the session so the player
  /// UI never has to inspect a nested track graph to know what is playing.
  ///
  /// Throws on failure to start playback (e.g. native audio service didn't
  /// start, ExoPlayer threw, iOS audio session couldn't be configured).
  /// Callers MUST wrap in try/catch and surface the failure to the user —
  /// otherwise we end up navigating to a player screen with no audio (silent
  /// failure that looks like a broken app).
  Future<void> play(PlaybackRequest request) async {
    AppLogger.d(
      'PLAYER',
      'Loading track: ${request.title}, fileId: ${request.fileId}',
    );

    if (request.isTimer && !isReserved(request.timerRunId)) {
      // Solo empieza el temporizador que conserva su reserva (R32, R55).
      AppLogger.w('PLAYER', 'Inicio del temporizador sin reserva vigente');
      return;
    }
    // Un temporizador que sigue sonando se guarda con su posición final
    // ANTES de reemplazarlo. Si no se pudo guardar, sigue sonando, nada de
    // esta sesión cambia y la nueva no empieza (TMR-02).
    final savedTimers = <String>{};
    for (
      var replaced = activeTimerRequest;
      replaced != null &&
          replaced.timerRunId != request.timerRunId &&
          !savedTimers.contains(replaced.timerRunId);
      replaced = activeTimerRequest
    ) {
      final owner = _start;
      if (!await _saveReplacedTimer(replaced, owner)) {
        // La pantalla del temporizador vuelve a ser la de la sesión viva.
        if (identical(_start, owner) && stateOrNull == request) {
          state = replaced;
        }
        throw const TimerReplaceFailedException();
      }
      savedTimers.add(replaced.timerRunId);
    }
    if (request.isTimer) {
      // La espera pudo soltar la reserva.
      if (!isReserved(request.timerRunId)) {
        AppLogger.w('PLAYER', 'Inicio del temporizador sin reserva vigente');
        return;
      }
    } else {
      // Una meditación guiada invalida la reserva pendiente de un temporizador.
      _reservedRunId = null;
    }
    _startWatch?.cancel();
    _startWatch = null;
    _backupPlaying = null;
    _sitOutcome = null;

    // The audio state outlives sessions; drop the previous track's (possibly
    // completed, full-position) values so nothing reads them as this one's.
    ref.read(audioStateProvider.notifier).resetState();
    final previous = _start;
    final previousTimer = activeTimerRequest;
    previous?.cancelled = true;
    final start = _PlaybackStart(request);
    _start = start;
    _sessionOpen = true;
    _sessionAccount = start.accountGeneration;
    _activeTimer = request.isTimer ? request : null;
    _timerCloser = request.isTimer ? TimerSessionCloser() : null;
    final watch = request.isTimer
        ? _startWatch = _StartWatch(request, start)
        : null;
    // El plazo empieza ANTES de cargar el audio: una carga que no termina
    // también vence y suelta la reserva (R56).
    watch?.arm(_startConfirmTimeout, () => unawaited(_failStart(watch)));
    try {
      start.check();
      if (previousTimer != null && !_usesAndroidAudio) {
        // El temporizador anterior ya quedó guardado con su posición final.
        iosAudioHandler.cancelPendingTimerStart();
      }
      try {
        await ref.read(sessionBellPreviewProvider).stop();
      } catch (error, stack) {
        AppLogger.e(
          'PLAYER',
          'No se pudo detener el audio anterior',
          error,
          stack,
        );
      }
      start.check();
      await _playTrack(request, start);
      start.check();
    } on _PlaybackStartCancelled {
      return;
    } catch (_) {
      if (!start.isCurrent) return;
      if (watch != null) await _failStart(watch);
      rethrow;
    }
    // Confirmación del inicio: un estado «sonando» con el mismo runId y la
    // posición avanzada. playAudio == true no lo confirma.
    state = request;

    // Analytics: playback actually started. Fired after _playTrack so a failed
    // start (which rethrows above) does not count as a started session. Also
    // abandons any prior session that never completed (track switch).
    unawaited(
      AudioSessionTracker.instance.onStarted(
        fileId: request.fileId,
        guide: request.isTimer
            ? AnalyticsEventConstants.timerGuide
            : request.guideName,
        durationMs: request.duration,
        plannedDurationMs: request.timerPlannedDurationMs,
        extraTime: request.isTimer ? request.hasExtraTime : null,
        prepMs: request.timerPrepMs,
        // El registro de cada plataforma recupera los temporizadores.
        persist: !request.isTimer,
      ),
    );
  }

  /// Guarda el temporizador [timer] que otra sesión va a reemplazar, con su
  /// posición final. Verdadero si quedó guardado o no había nada que guardar;
  /// falso si el guardado falló: el temporizador sigue sonando (TMR-02).
  Future<bool> _saveReplacedTimer(
    PlaybackRequest timer,
    _PlaybackStart? start,
  ) async {
    try {
      return _usesAndroidAudio
          ? await _saveReplacedAndroidTimer(timer, start)
          : await _saveReplacedIosTimer(timer, start);
    } catch (error, stack) {
      AppLogger.e(
        'TIMER',
        'No se pudo guardar el temporizador reemplazado',
        error,
        stack,
      );
      return false;
    }
  }

  /// iOS: el cierre queda guardado con el tiempo meditado hasta ahora y su
  /// `runId` deja de ser el vivo, para que la recuperación nunca lo omita
  /// (REV-05). Uno que nunca empezó no tiene nada que guardar.
  Future<bool> _saveReplacedIosTimer(
    PlaybackRequest timer,
    _PlaybackStart? start,
  ) async {
    final runs = IosTimerRunStore.instance;
    final runId = timer.timerRunId;
    if (start?.requested != true || iosAudioHandler.timerRunId != runId) {
      runs.releaseLiveRun(runId);
      return true;
    }
    final elapsed = TimerTimeline.fromRequest(
      timer,
    ).elapsedMs(iosAudioHandler.position.inMilliseconds);
    final saved = await runs.finish(
      runId: runId,
      durationMs: elapsed,
      fallback: TimerRunStart.fromRequest(timer),
      generation: start!.accountGeneration,
    );
    if (!saved) {
      AppLogger.w('TIMER', 'No se guardó el temporizador; sigue sonando');
      return false;
    }
    runs.releaseLiveRun(runId);
    unawaited(runs.deliver());
    return true;
  }

  /// Android: como en iOS (REV-05), el temporizador reemplazado se GUARDA con
  /// su posición final; nunca se descarta (TIMER-REVIEW-01). Si el servicio
  /// no pudo guardarlo, no detuvo nada: la sesión sigue sonando y la otra no
  /// empieza, porque la recuperación solo tendría la última foto (TMR-02).
  Future<bool> _saveReplacedAndroidTimer(
    PlaybackRequest timer,
    _PlaybackStart? start,
  ) async {
    final seed = timer.timerSeed;
    if (start?.requested != true || seed == null) return true;
    final report = await _api.stopTimerPlayback(seed, true);
    // Sin `runId`, el servicio ya no tiene esa sesión viva (terminó sola o
    // es de otra cuenta): no hay nada que guardar.
    if (report.stopped ||
        report.completionPersisted == true ||
        report.runId == null) {
      return true;
    }
    AppLogger.w('TIMER', 'No se guardó el temporizador; sigue sonando');
    return false;
  }

  /// Sets the current request WITHOUT starting playback, so the player screen
  /// can be pushed immediately and render its title/cover/duration from this
  /// request while the audio loads. [PlayerView] then calls [play] itself.
  /// Also used to warm-prepare next-up tracks.
  ///
  /// Compares the whole request (not just trackId) so switching voice or
  /// duration on the same track still updates the pending file.
  void prepare(PlaybackRequest request) {
    if (state == request) return;
    _sitOutcome = null;
    state = request;
  }

  Future<void> _playTrack(PlaybackRequest request, _PlaybackStart start) async {
    AppLogger.d(
      'PLAYER',
      '_playTrack called for track: ${request.trackId}, file: ${request.fileId}',
    );

    // A timer's silent file is generated locally and is never a download.
    final downloadPath = request.isTimer
        ? null
        : await ref
              .read(audioDownloaderProvider.notifier)
              .getTrackPath(_constructFileName(request));
    start.check();

    final url = downloadPath ?? request.remoteUrl;
    AppLogger.d('PLAYER', 'Will use path: $url');

    // Both engines outlive the player screen and keep their last repeat mode
    // and speed across tracks, while each player screen starts at repeat off /
    // 1.0x. Reset them so a leftover "repeat forever" can't loop a session
    // (and block the end screen) and a slowed-down speed doesn't carry over.
    // A timer has no repeat control; its length is the session.
    final repeatMode = request.isTimer
        ? app_repeat.RepeatMode.none
        : ref.read(repeatStateProvider);

    final trackData = pigeon.Track(
      id: request.trackId,
      title: request.title,
      fileId: request.fileId,
      artist: request.guideName ?? '',
      artistUrl: request.artist?.path,
      description: request.description,
      imageUrl: request.coverUrl,
    );

    if (_usesAndroidAudio) {
      AppLogger.d(
        'PLAYER',
        'On Android - starting service and checking readiness',
      );
      // NOTE: errors here intentionally propagate to play() and onwards to the
      // caller. Previously this was a swallow ('catch (e) { log; }') which
      // resolved play() successfully despite playback never starting, leading
      // to a silent-fail player screen. See P0-4 in the audit.
      //
      // El servicio solo abre un temporizador con cuenta vinculada (REV-03).
      // Toda ruta pasa por aquí, también Descargas sin conexión: si nadie
      // vinculó todavía, se vincula la identidad local persistente
      // (TIMER-REVIEW-03). Una guiada no lo exige: si falla, suena igual.
      try {
        await PlaybackAccount.ensureBound();
      } catch (error, stack) {
        if (request.isTimer) rethrow;
        AppLogger.e('PLAYER', 'No se pudo vincular la cuenta', error, stack);
      }
      start.check();
      await _androidServiceApi.startService();
      start.check();
      AppLogger.d(
        'PLAYER',
        'Service start requested, now waiting briefly before checking readiness',
      );
      await Future.delayed(const Duration(milliseconds: 500));
      start.check();

      final isReady = await _waitForServiceReadiness(start);
      start.check();

      if (isReady) {
        AppLogger.d('PLAYER', 'Service is ready, proceeding with playback');
      } else {
        AppLogger.w(
          'PLAYER',
          'Service failed to become ready, attempting playback anyway',
        );
        await Future.delayed(const Duration(seconds: 1));
        start.check();
      }
      if (!request.isTimer) setRepeatMode(repeatMode);
      await _playAudioWithRetry(url, trackData, request, start);
    } else {
      AppLogger.d('PLAYER', 'On iOS - setting up audio');
      // NOTE: errors here intentionally propagate (see comment above for the
      // Android path). _playAudioWithRetry on Android already rethrows after
      // its retry budget — iOS has no such retry layer, so a single failure
      // here propagates immediately. That's intentional: callers need to know.
      setRepeatMode(repeatMode);
      setSpeed(1.0);
      iosAudioHandler.onTimerStop = request.isTimer
          ? () async {
              if (identical(_start, start)) {
                await _closeTimer(expectedRunId: request.timerRunId);
              }
            }
          : null;
      final sound = ref.read(backgroundSoundsNotifierProvider.notifier);
      _wireIosAmbient(sound);
      sound.setTimerScope(request.isTimer);
      final bells = request.isTimer ? sound.prepareTimerBells() : null;
      await iosAudioHandler.setUrl(
        downloadPath,
        request,
        trackData,
        timerBells: bells,
      );
      start.check();
      // «Música de otras apps»: solo el temporizador puede mezclarse.
      await iosAudioHandler.configureSession(
        mixWithOthers:
            request.isTimer && ref.read(timerPreferencesProvider).mixWithOthers,
      );
      start.check();
      if (request.isTimer) {
        final saved = await IosTimerRunStore.instance.start(
          TimerRunStart.fromRequest(request),
          generation: start.accountGeneration,
        );
        // Sin registro recuperable la sesión no empieza (R75).
        if (!saved) throw StateError('No se guardó el inicio de la sesión');
        start.check();
      }
      start.requested = true;
      AppLogger.d('PLAYER', 'iOS setUrl succeeded');
      await iosAudioHandler.play();
      start.check();
      AppLogger.d('PLAYER', 'iOS play() called');
    }
  }

  // El controlador de interrupciones pausa, reanuda y baja el fondo a través
  // del notificador de sonidos de fondo.
  void _wireIosAmbient(BackgroundSoundsNotifier sound) {
    iosAudioHandler.pauseAmbient = () => sound.togglePlayPause(true);
    iosAudioHandler.resumeAmbient = () => sound.togglePlayPause(false);
    iosAudioHandler.duckAmbient = (ducked) {
      if (!iosAmbientActive) return;
      final volume = sound.scaledVolume(
        ref.read(backgroundSoundsNotifierProvider).volume,
      );
      unawaited(iosBackgroundPlayer.setVolume(volume * (ducked ? 0.2 : 1)));
    };
  }

  Future<bool> _waitForServiceReadiness(_PlaybackStart start) async {
    const maxAttempts = 10;
    const initialDelayMs = 500;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      var ready = false;
      try {
        ready = await _androidServiceApi.isServiceReady();
      } catch (error) {
        AppLogger.e(
          'PLAYER',
          'No se pudo consultar el servicio de audio',
          error,
        );
      }
      start.check();
      if (ready) return true;
      await Future.delayed(
        Duration(milliseconds: initialDelayMs * (1 << attempt)),
      );
      start.check();
    }
    return false;
  }

  Future<void> _playAudioWithRetry(
    String url,
    pigeon.Track trackData,
    PlaybackRequest request,
    _PlaybackStart start,
  ) async {
    const maxAttempts = 3;
    const initialDelayMs = 300;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        AppLogger.d(
          'PLAYER',
          'Calling playAudio with url: $url (attempt ${attempt + 1})',
        );

        final sound = ref.read(backgroundSoundsNotifierProvider.notifier);
        sound.setTimerScope(request.isTimer);
        await _api.setBellCues(!request.isTimer, [
          for (final cue in request.timerBellCues ?? const <TimerBellCue>[])
            pigeon.BellCue(
              offsetMs: cue.offsetMs,
              kind: cue.kind.name,
              assetKey: cue.assetKey,
            ),
        ]);
        start.check();
        if (request.isTimer) {
          pigeon.MeditoTimerStopCallbackApi.setUp(this);
          final bells = sound.prepareTimerBells();
          await _api.setBackgroundSoundVolume(bells.volume);
          start.check();
          bool enabled;
          do {
            enabled = ref.read(backgroundSoundsNotifierProvider).bellsEnabled;
            await _api.setSessionBells(enabled);
            start.check();
          } while (enabled !=
              ref.read(backgroundSoundsNotifierProvider).bellsEnabled);
        }
        final audioData = await _androidAudioData(url, trackData, request);
        start.check();
        start.requested = true;
        final started = await _api.playAudio(audioData);
        start.check();
        if (!started) {
          start.requested = false;
          throw StateError('El reproductor no pudo iniciar el audio');
        }

        AppLogger.d('PLAYER', 'playAudio call succeeded');
        return;
      } catch (e) {
        start.check();
        AppLogger.e(
          'PLAYER',
          'Error playing audio (attempt ${attempt + 1}): $e',
        );

        if (attempt < maxAttempts - 1) {
          final delayMs = initialDelayMs * (1 << attempt);
          AppLogger.d('PLAYER', 'Retrying playAudio in ${delayMs}ms...');
          await Future.delayed(Duration(milliseconds: delayMs));
          start.check();
        } else {
          rethrow;
        }
      }
    }
  }

  /// Todos los datos que el servicio nativo necesita (§3.1). En una
  /// meditación guiada solo viaja `dndRequested`.
  Future<pigeon.AudioData> _androidAudioData(
    String url,
    pigeon.Track trackData,
    PlaybackRequest request,
  ) async {
    final dndRequested = await ref
        .read(dndProvider.notifier)
        .shouldRequestDnd();
    if (!request.isTimer) {
      return guidedAudioData(
        url,
        trackData,
        dndRequested: dndRequested,
        dndRuleName: currentLocalizations().timerDndRuleName,
      );
    }
    final l10n = currentLocalizations();
    final plannedMinutes =
        request.plannedDurationMs ~/ Duration.millisecondsPerMinute;
    return pigeon.AudioData(
      url: url,
      track: trackData,
      timerSeed: request.timerSeed,
      timerHasExtraTime: request.hasExtraTime,
      timerStopLabel: request.timerStopLabel,
      timerPrepMs: request.timerPrepMs,
      timerPlannedMs: request.plannedDurationMs,
      timerIsStopwatch: request.timerMode == TimerMode.stopwatch,
      timerBellOutput: request.timerBellOutput,
      timerMixWithOthers: ref.read(timerPreferencesProvider).mixWithOthers,
      dndRequested: dndRequested,
      timerLanguageTag: currentLanguageTag(),
      timerPausedText: l10n.timerPaused,
      timerPrepText: l10n.timerPrepLabel,
      timerExtraTimeText: l10n.timerExtraTime,
      timerHeadphonesPausedText: l10n.timerHeadphonesPaused,
      timerOtherAudioPausedText: l10n.timerOtherAudioPaused,
      timerAlertsChannelName: l10n.timerAlertsChannel,
      timerRunId: request.timerRunId,
      timerOwnerId: request.timerOwnerId,
      timerBackupTitle: l10n.timerEndBackupTitle,
      timerBackupBody: l10n.timerEndBackupBody(plannedMinutes),
      timerBackupChannelName: l10n.timerEndBackupChannel,
      timerBackupSilentChannelName: l10n.timerEndBackupSilentChannel,
      timerDndRuleName: l10n.timerDndRuleName,
    );
  }

  /// Datos de una meditación guiada. Si pide «No molestar» también viaja el
  /// nombre localizado de la regla: Android 15+ lo necesita para crearla en
  /// una instalación nueva (REV-12).
  @visibleForTesting
  static pigeon.AudioData guidedAudioData(
    String url,
    pigeon.Track trackData, {
    required bool dndRequested,
    required String dndRuleName,
  }) => pigeon.AudioData(
    url: url,
    track: trackData,
    dndRequested: dndRequested,
    timerDndRuleName: dndRequested ? dndRuleName : null,
  );

  String _constructFileName(PlaybackRequest request) =>
      '${request.trackId}-${request.fileId}${getAudioFileExtension(request.remoteUrl)}';

  Future<void> seekToPosition(int position) async {
    if (_usesAndroidAudio) {
      await _api.seekToPosition(position);
    } else {
      await iosAudioHandler.seek(Duration(milliseconds: position));
    }
  }

  @override
  Future<void> timerStopped(
    int sessionSeed,
    pigeon.TimerStopReport report,
  ) async {
    final active = _activeTimer;
    if (active == null || active.timerSeed != sessionSeed) return;
    // El reporte de otra corrida nunca cierra la actual.
    final reported = report.runId;
    if (reported != null && reported != active.timerRunId) return;
    await _closeTimer(report: report, expectedRunId: active.timerRunId);
  }

  /// Cierra el temporizador [runId]. [save] es la elección del usuario:
  /// `true` para «Terminar» y «Guardar y salir», `false` para «Salir sin
  /// guardar». Si la sesión activa ya es otra, no toca nada y devuelve null
  /// (TIMER-05). Con `save: false` que no pudo borrar la sesión devuelve
  /// `stopped == false` y el audio sigue sonando (R52).
  Future<TimerRunCloseResult?> closeTimer({
    required String runId,
    bool save = true,
  }) => _closeTimer(save: save, expectedRunId: runId);

  Future<TimerRunCloseResult?> _closeTimer({
    pigeon.TimerStopReport? report,
    bool save = true,
    required String expectedRunId,
  }) async {
    final request = _activeTimer;
    final closer = _timerCloser;
    final start = _start;
    if (request == null ||
        closer == null ||
        start == null ||
        expectedRunId.isEmpty ||
        request.timerRunId != expectedRunId ||
        !PlaybackAccount.isCurrent(start.accountGeneration)) {
      return null;
    }
    final audio = ref.read(audioStateProvider);
    if (!closer.isClosing &&
        report == null &&
        start.requested &&
        audio.isCompleted &&
        audio.track.fileId == request.fileId) {
      return null;
    }
    final wasCancelled = start.cancelled;
    start.cancelled = true;
    // Después de cada espera: la misma corrida, la misma cuenta y el mismo
    // `runId` esperado (TIMER-05).
    bool isCurrent() =>
        identical(_start, start) &&
        PlaybackAccount.isCurrent(start.accountGeneration) &&
        (_activeTimer?.timerRunId ?? expectedRunId) == expectedRunId;
    final result = await closer.close(
      // El mismo resultado, con su `runId`, llega al flujo y a quien cerró.
      stopPlayback: () async => TimerRunCloseResult.of(
        expectedRunId,
        await _stopTimerPlayback(request, start, report, save),
      ),
      isCurrent: isCurrent,
      onStopped: (result) {
        if (result.saved) {
          _finishSit(start, naturalEnd: false);
        } else {
          start.sitClosed = true;
        }
        final sound = ref.read(backgroundSoundsNotifierProvider);
        final soundNotifier = ref.read(
          backgroundSoundsNotifierProvider.notifier,
        );
        if (_usesAndroidAudio) {
          soundNotifier.stopTimerAmbient(transportAlreadyStopped: true);
        } else {
          // iOS: primero el reloj y las campanas (ya detenidos), luego el
          // fondo con desvanecido y al final la sesión de audio (§4.9).
          unawaited(() async {
            await soundNotifier.stopTimerAmbient(
              transportAlreadyStopped: false,
              fade: const Duration(seconds: 3),
            );
            if (identical(_start, start) &&
                PlaybackAccount.isCurrent(start.accountGeneration) &&
                iosAudioHandler.timerRunId == request.timerRunId) {
              await iosAudioHandler.deactivateSession();
            }
          }());
        }
        if (result.recorded &&
            !result.endCueRang &&
            sound.bellsEnabled &&
            request.timerEndBellEnabled &&
            result.elapsed.inMilliseconds < request.plannedDurationMs) {
          _playEndSample(
            request,
            soundNotifier.scaledVolume(sound.volume),
            isCurrent,
          );
        }
        if (identical(_start, start)) _endSession();
        _recordTimerClose(request, result);
      },
    );
    if (!result.stopped && isCurrent()) {
      // La sesión sigue sonando: se puede reintentar el cierre.
      start.cancelled = wasCancelled;
    }
    if (!isCurrent()) return null;
    return result is TimerRunCloseResult
        ? result
        : TimerRunCloseResult.of(expectedRunId, result);
  }

  /// Muestra del cierre manual según la salida de las campanas (§4.9):
  /// «Solo vibración» nunca toca audio.
  void _playEndSample(
    PlaybackRequest request,
    double volume,
    bool Function() isCurrent,
  ) {
    final output = request.timerBellOutput;
    final sound = output != 'vibration';
    final vibrate = output == 'vibration' || output == 'soundAndVibration';
    final preview = ref.read(sessionBellPreviewProvider);
    unawaited(
      Future.delayed(const Duration(milliseconds: 400), () async {
        if (!ref.mounted ||
            !isCurrent() ||
            !ref.read(backgroundSoundsNotifierProvider).bellsEnabled) {
          return;
        }
        try {
          if (vibrate) {
            if (_usesAndroidAudio) {
              // Hoy la muestra toca una campana: un pulso.
              await TimerDeviceChannel.vibrateBell(1);
            } else {
              await HapticFeedback.vibrate();
            }
          }
          if (sound) {
            await preview.play(
              volume,
              assetKey: BellSound.resolve(request.timerEndSound).assetKey,
            );
          }
        } catch (error, stack) {
          AppLogger.e(
            'BELLS',
            'No se pudo tocar la campana de cierre',
            error,
            stack,
          );
        }
      }),
    );
  }

  Future<TimerCloseResult> _stopTimerPlayback(
    PlaybackRequest request,
    _PlaybackStart start,
    pigeon.TimerStopReport? report,
    bool save,
  ) async {
    final runs = IosTimerRunStore.instance;
    if (report == null && !start.requested) {
      if (!_usesAndroidAudio) {
        await runs.discard(
          request.timerRunId,
          generation: start.accountGeneration,
        );
        await iosAudioHandler.stopRun(request.timerRunId);
      }
      return TimerCloseResult(Duration.zero, saved: save);
    }
    final timeline = TimerTimeline.fromRequest(request);
    if (_usesAndroidAudio) {
      final seed = request.timerSeed;
      if (report == null && seed == null) {
        return TimerCloseResult(Duration.zero, stopped: false, saved: save);
      }
      // El servicio nativo guarda o descarta la sesión según [save].
      final native = report ?? await _api.stopTimerPlayback(seed!, save);
      if (native.stopped &&
          native.endCueRang &&
          (native.runId == null || native.runId == request.timerRunId)) {
        start.sitEndCueRang = true;
      }
      return TimerCloseResult(
        // Solo cuenta el tiempo meditado: la preparación no suma (§4.1).
        Duration(milliseconds: timeline.elapsedMs(native.positionMs)),
        endCueRang: native.endCueRang,
        stopped: native.stopped,
        completionPersisted: native.completionPersisted ?? false,
        saved: report == null ? save : true,
      );
    }
    final elapsed = Duration(
      milliseconds: timeline.elapsedMs(iosAudioHandler.position.inMilliseconds),
    );
    if (save) {
      // El cierre queda guardado con su tiempo final ANTES de detener el audio.
      // Si no se pudo guardar, la sesión sigue sonando para reintentar.
      if (!await runs.finish(
        runId: request.timerRunId,
        durationMs: elapsed.inMilliseconds,
        fallback: TimerRunStart.fromRequest(request),
        generation: start.accountGeneration,
      )) {
        return TimerCloseResult(elapsed, stopped: false);
      }
    } else if (!await runs.discard(
      request.timerRunId,
      generation: start.accountGeneration,
    )) {
      // «Salir sin guardar» no pudo borrar la sesión: sigue sonando.
      return TimerCloseResult(elapsed, stopped: false, saved: false);
    }
    if (identical(_start, start) &&
        iosAudioHandler.timerRunId == request.timerRunId) {
      start.endCueRang |= iosAudioHandler.sessionBells.stopBellsAndReportEnd();
      start.sitEndCueRang |= start.endCueRang;
    }
    await iosAudioHandler.stopRun(request.timerRunId, full: false);
    return TimerCloseResult(elapsed, endCueRang: start.endCueRang, saved: save);
  }

  void _recordTimerClose(PlaybackRequest request, TimerCloseResult result) {
    final elapsed = Duration(seconds: result.elapsed.inSeconds);
    if (result.recorded) {
      unawaited(
        AudioSessionTracker.instance.onCompleted(fileId: request.fileId),
      );
      // Android: el servicio nativo es la única fuente del registro y lo
      // entrega por handleCompletedTrack. iOS: lo entrega el registro de Dart.
      if (!_usesAndroidAudio) {
        unawaited(IosTimerRunStore.instance.deliver());
      }
    } else {
      unawaited(AudioSessionTracker.instance.onStopped());
    }
    if (!result.completionPersisted) {
      unawaited(
        FirebaseAnalyticsService().logEvent(
          name: AnalyticsEventConstants.timerEnded,
          parameters: {
            AnalyticsEventConstants.paramTimerMode: request.timerMode.name,
            AnalyticsEventConstants.paramElapsedSeconds: elapsed.inSeconds,
            AnalyticsEventConstants.paramRecorded: result.recorded ? 1 : 0,
          },
        ),
      );
    }
    // «Salir sin guardar» no abre la pantalla final: quien cerró decide.
    if (result.saved) {
      _timerCloses.add(
        result is TimerRunCloseResult
            ? result
            : TimerRunCloseResult.of(request.timerRunId, result),
      );
    }
  }

  Future<void> _stopPlayback() =>
      _usesAndroidAudio ? _api.stopAudio() : iosAudioHandler.stopPlayback();

  void stop() {
    final start = _start;
    if (start != null && start.isCurrent && !start.request.isTimer) {
      _finishSit(start, naturalEnd: false);
    }
    start?.cancelled = true;
    if (_timerCloser?.isClosing ?? false) return;
    // Analytics: closing the player ends the session. No-op if it already
    // completed (the completion path also calls stop()).
    unawaited(AudioSessionTracker.instance.onStopped());
    final timer = _activeTimer ?? (state?.isTimer == true ? state : null);
    final pendingAndroidTimer =
        _usesAndroidAudio && timer != null && start?.requested != true;
    _activeTimer = null;
    _endSession();
    if (!_usesAndroidAudio && timer != null) {
      // El final natural suelta el audio por su cuenta y deja sonar la campana.
      if (iosAudioHandler.timerCompleting) return;
      // Cerrar sin guardar: borra la sesión en curso antes de detener.
      final generation = start?.accountGeneration ?? PlaybackAccount.generation;
      unawaited(
        IosTimerRunStore.instance
            .discard(timer.timerRunId, generation: generation)
            .then((_) => iosAudioHandler.stopRun(timer.timerRunId)),
      );
      return;
    }
    if (!pendingAndroidTimer) unawaited(_stopPlayback());
  }

  void setSpeed(double speed) {
    if (_usesAndroidAudio) {
      _api.setSpeed(speed);
    } else {
      iosAudioHandler.setSpeed(speed);
    }
  }

  void setRepeatMode(app_repeat.RepeatMode mode) {
    final pigeonMode = switch (mode) {
      app_repeat.RepeatMode.none => pigeon.RepeatMode.none,
      app_repeat.RepeatMode.once => pigeon.RepeatMode.once,
      app_repeat.RepeatMode.infinite => pigeon.RepeatMode.infinite,
    };
    if (_usesAndroidAudio) {
      _api.setRepeatMode(pigeonMode);
    } else {
      iosAudioHandler.setCustomRepeatMode(pigeonMode);
    }
  }

  void skip10SecondsForward() {
    if (_usesAndroidAudio) {
      _api.skip10SecondsForward();
    } else {
      iosAudioHandler.seek(
        iosAudioHandler.position + const Duration(seconds: 15),
      );
    }
  }

  void skip10SecondsBackward() {
    if (_usesAndroidAudio) {
      _api.skip10SecondsBackward();
    } else {
      iosAudioHandler.seek(
        iosAudioHandler.position - const Duration(seconds: 15),
      );
    }
  }

  void playPause() {
    if (_usesAndroidAudio) {
      _api.playPauseAudio();
    } else {
      if (iosAudioHandler.playing) {
        iosAudioHandler.pause();
      } else {
        iosAudioHandler.play();
      }
    }
  }
}

class _PlaybackStart {
  _PlaybackStart(this.request);

  final PlaybackRequest request;
  final int accountGeneration = PlaybackAccount.generation;
  bool cancelled = false;
  bool requested = false;
  bool endCueRang = false;
  bool sitPlayed = false;
  bool sitClosed = false;
  bool sitEndCueRang = false;
  Duration? sitPauseStart;
  Duration sitPaused = Duration.zero;

  void endSitPause(Duration now) {
    final pausedAt = sitPauseStart;
    if (pausedAt == null) return;
    sitPaused += now - pausedAt;
    sitPauseStart = null;
  }

  bool get isCurrent =>
      !cancelled && PlaybackAccount.isCurrent(accountGeneration);

  void check() {
    if (!isCurrent) throw const _PlaybackStartCancelled();
  }
}

class _PlaybackStartCancelled implements Exception {
  const _PlaybackStartCancelled();
}

/// Otra sesión no empezó porque el temporizador que sonaba no se pudo
/// guardar: sigue sonando y no se perdió nada (TMR-02).
class TimerReplaceFailedException implements Exception {
  const TimerReplaceFailedException();
}

/// Marca de una sesión del reproductor; dos marcas son iguales solo si son
/// el mismo inicio y la misma solicitud (TMR-03).
@immutable
class PlayerSessionMark {
  const PlayerSessionMark(this._start, this._request);

  final Object? _start;
  final PlaybackRequest? _request;

  @override
  bool operator ==(Object other) =>
      other is PlayerSessionMark &&
      identical(other._start, _start) &&
      identical(other._request, _request);

  @override
  int get hashCode =>
      Object.hash(identityHashCode(_start), identityHashCode(_request));
}

/// Espera la confirmación de que un temporizador de verdad empezó a sonar.
class _StartWatch {
  _StartWatch(this.request, this.start);

  final PlaybackRequest request;
  final _PlaybackStart start;
  bool failed = false;
  // El reloj espera el foco de audio: el plazo está detenido (REV-06).
  bool held = false;
  Timer? _timeout;

  String get runId => request.timerRunId;

  void arm(Duration timeout, void Function() onTimeout) {
    held = false;
    _timeout?.cancel();
    _timeout = Timer(timeout, onTimeout);
  }

  /// Detiene el plazo mientras el reloj no puede avanzar.
  void hold() {
    held = true;
    _timeout?.cancel();
  }

  void cancel() => _timeout?.cancel();
}

/// Resultado del cierre de UNA corrida: lleva su `runId` para que quien lo
/// recibe compruebe que es la suya (TIMER-05).
class TimerRunCloseResult extends TimerCloseResult {
  const TimerRunCloseResult(
    this.runId,
    super.elapsed, {
    super.stopped,
    super.endCueRang,
    super.completionPersisted,
    super.saved,
  });

  TimerRunCloseResult.of(String runId, TimerCloseResult result)
    : this(
        runId,
        result.elapsed,
        stopped: result.stopped,
        endCueRang: result.endCueRang,
        completionPersisted: result.completionPersisted,
        saved: result.saved,
      );

  final String runId;
}

const audioPercentageListened = 0.8;
const androidNotificationIcon = 'logo';
const notificationId = 1595122;
const androidNotificationChannelId = 'medito_reminder_channel';
