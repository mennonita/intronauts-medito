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
  PlayerProvider({bool? useAndroidAudio, Duration? startConfirmTimeout})
    : _usesAndroidAudio = useAndroidAudio ?? Platform.isAndroid,
      _startConfirmTimeout = startConfirmTimeout ?? const Duration(seconds: 10);

  final bool _usesAndroidAudio;
  final Duration _startConfirmTimeout;
  _PlaybackStart? _start;
  final _timerCloses = StreamController<TimerCloseResult>.broadcast();
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

  Stream<TimerCloseResult> get timerCloses => _timerCloses.stream;

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
    final watch = _startWatch;
    final request = _activeTimer;
    if (watch != null &&
        !watch.failed &&
        next.runId == watch.runId &&
        next.isPlaying &&
        next.position > 0) {
      _startWatch = null;
      watch.cancel();
      unawaited(_commitLastTimer(watch.runId));
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

    if (request.isTimer) {
      // Solo empieza el temporizador que conserva su reserva (R32, R55).
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

    // The audio state outlives sessions; drop the previous track's (possibly
    // completed, full-position) values so nothing reads them as this one's.
    ref.read(audioStateProvider.notifier).resetState();
    final previous = _start;
    final previousTimer = activeTimerRequest;
    previous?.cancelled = true;
    final start = _PlaybackStart();
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
        iosAudioHandler.cancelPendingTimerStart();
      }
      try {
        await Future.wait([
          ref.read(sessionBellPreviewProvider).stop(),
          if (_usesAndroidAudio &&
              previous?.requested == true &&
              previousTimer?.timerSeed != null)
            _api.stopTimerPlayback(previousTimer!.timerSeed!, false),
        ]);
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

  /// Sets the current request WITHOUT starting playback, so the player screen
  /// can be pushed immediately and render its title/cover/duration from this
  /// request while the audio loads. [PlayerView] then calls [play] itself.
  /// Also used to warm-prepare next-up tracks.
  ///
  /// Compares the whole request (not just trackId) so switching voice or
  /// duration on the same track still updates the pending file.
  void prepare(PlaybackRequest request) {
    if (state == request) return;
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
              if (identical(_start, start)) await closeTimer();
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
      return pigeon.AudioData(
        url: url,
        track: trackData,
        dndRequested: dndRequested,
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
    if (_activeTimer?.timerSeed == sessionSeed) {
      await _closeTimer(report: report);
    }
  }

  /// Cierra el temporizador. [save] es la elección del usuario: `true` para
  /// «Terminar» y «Guardar y salir», `false` para «Salir sin guardar».
  /// Con `save: false` que no pudo borrar la sesión devuelve
  /// `stopped == false` y el audio sigue sonando (R52).
  Future<TimerCloseResult?> closeTimer({bool save = true}) =>
      _closeTimer(save: save);

  Future<TimerCloseResult?> _closeTimer({
    pigeon.TimerStopReport? report,
    bool save = true,
  }) async {
    final request = _activeTimer;
    final closer = _timerCloser;
    final start = _start;
    if (request == null ||
        closer == null ||
        start == null ||
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
    bool isCurrent() =>
        identical(_start, start) &&
        PlaybackAccount.isCurrent(start.accountGeneration);
    final result = await closer.close(
      stopPlayback: () => _stopTimerPlayback(request, start, report, save),
      isCurrent: isCurrent,
      onStopped: (result) {
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
    return isCurrent() ? result : null;
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
    if (result.saved) _timerCloses.add(result);
  }

  Future<void> _stopPlayback() =>
      _usesAndroidAudio ? _api.stopAudio() : iosAudioHandler.stopPlayback();

  void stop() {
    final start = _start;
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
  final int accountGeneration = PlaybackAccount.generation;
  bool cancelled = false;
  bool requested = false;
  bool endCueRang = false;

  bool get isCurrent =>
      !cancelled && PlaybackAccount.isCurrent(accountGeneration);

  void check() {
    if (!isCurrent) throw const _PlaybackStartCancelled();
  }
}

class _PlaybackStartCancelled implements Exception {
  const _PlaybackStartCancelled();
}

/// Espera la confirmación de que un temporizador de verdad empezó a sonar.
class _StartWatch {
  _StartWatch(this.request, this.start);

  final PlaybackRequest request;
  final _PlaybackStart start;
  bool failed = false;
  Timer? _timeout;

  String get runId => request.timerRunId;

  void arm(Duration timeout, void Function() onTimeout) {
    _timeout?.cancel();
    _timeout = Timer(timeout, onTimeout);
  }

  void cancel() => _timeout?.cancel();
}

const audioPercentageListened = 0.8;
const androidNotificationIcon = 'logo';
const notificationId = 1595122;
const androidNotificationChannelId = 'medito_reminder_channel';
