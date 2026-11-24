import 'dart:async';
import 'dart:io';

import 'package:medito/providers/player/player_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../constants/types/type_constants.dart';
import '../../services/analytics/crashlytics_service.dart';
import '../../src/audio_pigeon.g.dart';
import '../../utils/audio_session_tracker.dart';
import '../../utils/stats_updater.dart';
import '../../utils/stats_updater.dart' as stats_updater;
import '../timer/native_timer_close_recovery.dart';

/// `runId` de cada error del reproductor de Android (null si no es de un
/// temporizador). PlayerProvider lo usa para detectar un inicio fallido.
final timerPlayerErrors = StreamController<String?>.broadcast(sync: true);

class AudioStateProvider implements MeditoAudioServiceCallbackApi {
  final AudioStateNotifier notifier;
  final WidgetRef? ref;
  final _timerRecovery = NativeTimerCloseRecovery();

  AudioStateProvider(this.notifier, {this.ref});

  @override
  void updatePlaybackState(PlaybackState state) {
    notifier.updatePlaybackState(state);
    // Android position feed for session analytics (the poll runs ~1/s).
    AudioSessionTracker.instance.onPositionUpdate(
      positionMs: state.position,
      durationMs: state.duration,
      isPlaying: state.isPlaying,
      isCompleted: state.isCompleted,
    );
  }

  @override
  void reportPlayerError(
    String errorCode,
    String message,
    int positionMs,
    int durationMs,
    String? runId,
  ) {
    CrashlyticsService().recordError(
      Exception('ExoPlayer $errorCode: $message'),
      StackTrace.current,
      reason: 'ExoPlayer onPlayerError',
      information: [
        'errorCode=$errorCode',
        'positionMs=$positionMs',
        'durationMs=$durationMs',
        'runId=$runId',
      ],
    );
    timerPlayerErrors.add(runId);
  }

  // only used on Android
  @override
  Future<bool> handleCompletedTrack(CompletionData completionData) async {
    try {
      // Sesiones del temporizador del registro nativo: una sola vez por runId.
      if (completionData.runId != null) {
        return await _timerRecovery.handleRun(completionData);
      }
      if (completionData.timerEnded != null) {
        return await _timerRecovery.handle(completionData);
      }
      return await handleStats({
        TypeConstants.trackIdKey: completionData.trackId,
        TypeConstants.durationIdKey: completionData.duration,
        TypeConstants.fileIdKey: completionData.fileId,
        TypeConstants.guideIdKey: completionData.guideId,
        TypeConstants.timestampIdKey: completionData.timestamp,
      });
    } on Exception catch (_) {
      return false;
    }
  }

  // only used on Android
  @override
  Future<bool> handleRepeatPlaythrough(CompletionData completionData) {
    return stats_updater.handleRepeatPlaythrough({
      TypeConstants.trackIdKey: completionData.trackId,
      TypeConstants.durationIdKey: completionData.duration,
      TypeConstants.fileIdKey: completionData.fileId,
      TypeConstants.guideIdKey: completionData.guideId,
      TypeConstants.timestampIdKey: completionData.timestamp,
    });
  }
}

class AudioStateNotifier extends Notifier<PlaybackState> {
  @override
  PlaybackState build() {
    final initialState = PlaybackState(
      position: 0,
      isPlaying: false,
      isBuffering: false,
      isSeeking: false,
      isCompleted: false,
      duration: 0,
      speed: Speed(speed: 1),
      volume: 100,
      track: Track(
        id: '',
        title: '',
        fileId: '',
        description: '',
        imageUrl: '',
        artist: '',
      ),
    );

    if (Platform.isIOS) {
      iosAudioHandler.iosStateStream.listen((event) {
        var playerState = event.playerState;
        final isCompleted =
            playerState.processingState == ProcessingState.completed;
        state = state.copyWith(
          speed: Speed(speed: event.speed),
          track: iosAudioHandler.trackState,
          isPlaying: event.playerState.playing,
          isBuffering: playerState.processingState == ProcessingState.buffering,
          isSeeking: false,
          isCompleted: isCompleted,
          position: event.position.inMilliseconds,
          duration: event.duration.inMilliseconds,
          runId: iosAudioHandler.timerRunId,
        );
        // iOS position feed for session analytics.
        AudioSessionTracker.instance.onPositionUpdate(
          positionMs: event.position.inMilliseconds,
          durationMs: event.duration.inMilliseconds,
          isPlaying: event.playerState.playing,
          isCompleted: isCompleted,
        );
      });
    }

    return initialState;
  }

  void updatePlaybackState(PlaybackState newState) {
    state = newState;
  }

  void resetState() {
    state = PlaybackState(
      position: 0,
      isPlaying: false,
      isBuffering: false,
      isSeeking: false,
      isCompleted: false,
      duration: 0,
      speed: Speed(speed: 1),
      volume: 100,
      track: Track(
        id: '',
        title: '',
        fileId: '',
        description: '',
        imageUrl: '',
        artist: '',
      ),
    );
  }
}

var audioStateNotifier = AudioStateNotifier();

final audioStateProvider = NotifierProvider<AudioStateNotifier, PlaybackState>(
  () {
    return audioStateNotifier;
  },
);

const _keepRunId = Object();

extension PlaybackStateExt on PlaybackState {
  PlaybackState copyWith({
    int? position,
    bool? isPlaying,
    bool? isBuffering,
    bool? isSeeking,
    bool? isCompleted,
    int? duration,
    Speed? speed,
    int? volume,
    Track? track,
    Object? runId = _keepRunId,
    bool? waitingForFocus,
  }) {
    return PlaybackState(
      backgroundSound: backgroundSound,
      endCueRang: endCueRang,
      runId: identical(runId, _keepRunId) ? this.runId : runId as String?,
      waitingForFocus: waitingForFocus ?? this.waitingForFocus,
      position: position ?? this.position,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      isSeeking: isSeeking ?? this.isSeeking,
      isCompleted: isCompleted ?? this.isCompleted,
      duration: duration ?? this.duration,
      speed: speed ?? this.speed,
      volume: volume ?? this.volume,
      track: track ?? this.track,
    );
  }
}
