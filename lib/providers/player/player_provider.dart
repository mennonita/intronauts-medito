import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/models/models.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/services/analytics/firebase_analytics_service.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/utils/stats_updater.dart' show handleStats;

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
  PlayerProvider({bool? useAndroidAudio})
    : _usesAndroidAudio = useAndroidAudio ?? Platform.isAndroid;

  final bool _usesAndroidAudio;
  _PlaybackStart? _start;
  final _timerCloses = StreamController<TimerCloseResult>.broadcast();
  PlaybackRequest? _activeTimer;
  TimerSessionCloser? _timerCloser;

  Object get playbackIdentity => (_start, _start?.cancelled);
  PlaybackRequest? get activeTimerRequest =>
      _start?.isCurrent == true ? _activeTimer : null;

  Stream<TimerCloseResult> get timerCloses => _timerCloses.stream;

  @override
  PlaybackRequest? build() {
    ref.onDispose(() {
      _start?.cancelled = true;
      unawaited(_timerCloses.close());
    });
    return null;
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

    // The audio state outlives sessions; drop the previous track's (possibly
    // completed, full-position) values so nothing reads them as this one's.
    ref.read(audioStateProvider.notifier).resetState();
    final previous = _start;
    final previousTimer = activeTimerRequest;
    previous?.cancelled = true;
    final start = _PlaybackStart();
    _start = start;
    _activeTimer = request.isTimer ? request : null;
    _timerCloser = request.isTimer ? TimerSessionCloser() : null;
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
      rethrow;
    }
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
      sound.setTimerScope(request.isTimer);
      final bells = request.isTimer ? sound.prepareTimerBells() : null;
      await iosAudioHandler.setUrl(
        downloadPath,
        request,
        trackData,
        timerBells: bells,
      );
      start.check();
      start.requested = true;
      AppLogger.d('PLAYER', 'iOS setUrl succeeded');
      await iosAudioHandler.play();
      start.check();
      AppLogger.d('PLAYER', 'iOS play() called');
    }
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
        start.requested = true;
        final started = await _api.playAudio(
          pigeon.AudioData(
            url: url,
            track: trackData,
            timerSeed: request.timerSeed,
            timerHasExtraTime: request.hasExtraTime,
            timerStopLabel: request.timerStopLabel,
          ),
        );
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

  Future<TimerCloseResult?> closeTimer() => _closeTimer();

  Future<TimerCloseResult?> _closeTimer({
    pigeon.TimerStopReport? report,
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
    start.cancelled = true;
    bool isCurrent() =>
        identical(_start, start) &&
        PlaybackAccount.isCurrent(start.accountGeneration);
    final result = await closer.close(
      stopPlayback: () => _stopTimerPlayback(request, start, report),
      isCurrent: isCurrent,
      onStopped: (result) {
        final sound = ref.read(backgroundSoundsNotifierProvider);
        final soundNotifier = ref.read(
          backgroundSoundsNotifierProvider.notifier,
        );
        soundNotifier.stopTimerAmbient(
          transportAlreadyStopped: _usesAndroidAudio,
        );
        if (result.recorded &&
            !result.endCueRang &&
            sound.bellsEnabled &&
            request.timerEndBellEnabled &&
            result.elapsed.inMilliseconds < request.plannedDurationMs) {
          final preview = ref.read(sessionBellPreviewProvider);
          final volume = soundNotifier.scaledVolume(sound.volume);
          unawaited(
            Future.delayed(const Duration(milliseconds: 400), () async {
              if (!isCurrent() ||
                  !ref.read(backgroundSoundsNotifierProvider).bellsEnabled) {
                return;
              }
              try {
                await preview.play(
                  volume,
                  assetKey: BellSound.resolve(request.timerEndSound).assetKey,
                );
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
        _recordTimerClose(request, result);
      },
    );
    return isCurrent() ? result : null;
  }

  Future<TimerCloseResult> _stopTimerPlayback(
    PlaybackRequest request,
    _PlaybackStart start,
    pigeon.TimerStopReport? report,
  ) async {
    if (report == null && !start.requested) {
      if (!_usesAndroidAudio) await iosAudioHandler.stopPlayback();
      return const TimerCloseResult(Duration.zero);
    }
    if (_usesAndroidAudio) {
      final seed = request.timerSeed;
      if (report == null && seed == null) {
        return const TimerCloseResult(Duration.zero, stopped: false);
      }
      final native = report ?? await _api.stopTimerPlayback(seed!, true);
      return TimerCloseResult(
        Duration(milliseconds: native.positionMs),
        endCueRang: native.endCueRang,
        stopped: native.stopped,
        completionPersisted: native.completionPersisted ?? false,
      );
    }
    final elapsed = iosAudioHandler.position;
    start.endCueRang |= iosAudioHandler.sessionBells.stopBellsAndReportEnd();
    await iosAudioHandler.stopPlayback();
    return TimerCloseResult(elapsed, endCueRang: start.endCueRang);
  }

  void _recordTimerClose(PlaybackRequest request, TimerCloseResult result) {
    final elapsed = Duration(seconds: result.elapsed.inSeconds);
    if (result.recorded) {
      unawaited(
        AudioSessionTracker.instance.onCompleted(fileId: request.fileId),
      );
      if (!result.completionPersisted) {
        unawaited(
          handleStats({
            TypeConstants.trackIdKey: timerSessionId(elapsed),
            TypeConstants.durationIdKey: elapsed.inMilliseconds,
            TypeConstants.fileIdKey: request.fileId,
            TypeConstants.guideIdKey: '',
            TypeConstants.timestampIdKey: DateTime.now().millisecondsSinceEpoch,
          }),
        );
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
    _timerCloses.add(result);
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
    final pendingAndroidTimer =
        _usesAndroidAudio &&
        (_activeTimer != null || state?.isTimer == true) &&
        start?.requested != true;
    _activeTimer = null;
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

const audioPercentageListened = 0.8;
const androidNotificationIcon = 'logo';
const notificationId = 1595122;
const androidNotificationChannelId = 'medito_reminder_channel';
