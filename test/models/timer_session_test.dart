import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/utils/audio_completion_tracker.dart';

void main() {
  group('timer session ids', () {
    test('round-trip the session length through the stats id', () {
      final id = timerSessionId(const Duration(minutes: 20));
      expect(id, 'timer-1200');
      expect(isTimerSessionId(id), isTrue);
      expect(timerSessionDuration(id), const Duration(minutes: 20));
    });

    test('ignore track, manual and freeze ids', () {
      for (final id in [kLegacyTimerTrackId, 'manual1', 'streak-freeze']) {
        expect(isTimerSessionId(id), isFalse, reason: id);
        expect(timerSessionDuration(id), isNull, reason: id);
      }
      expect(timerSessionDuration('timer-abc'), isNull);
    });

    test('request knows its mode and is played from the local file', () {
      final countdown = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 5),
        filePath: '/tmp/medito_timer_300000.wav',
        title: 'Timer',
      );
      expect(countdown.isTimer, isTrue);
      expect(countdown.timerMode, TimerMode.countdown);
      expect(countdown.fileId, 'timer-countdown-300000');
      expect(countdown.duration, 300000);
      expect(countdown.remoteUrl, 'file:///tmp/medito_timer_300000.wav');

      final stopwatch = timerPlaybackRequest(
        mode: TimerMode.stopwatch,
        duration: kStopwatchMaxDuration,
        filePath: '/tmp/x.wav',
        title: 'Stopwatch',
      );
      expect(stopwatch.timerMode, TimerMode.stopwatch);
      expect(stopwatch.fileId, 'timer-stopwatch-0');
      expect(stopwatch.trackId, timerSessionId(kStopwatchMaxDuration));
    });
  });

  test(
    'el tiempo extra conserva la duración prevista, el archivo y la semilla',
    () {
      final request = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 3),
        filePath: '/tmp/timer.wav',
        title: 'Temporizador',
        extraTime: true,
        seed: 1234,
        bells: const TimerBellSettings(
          intervalMinutes: 1,
          randomCount: 3,
          endSound: 'kalimba',
        ),
      );
      final restored = PlaybackRequest.fromJson(request.toJson());
      expect(restored, request);
      expect(restored.hasExtraTime, isTrue);
      expect(restored.plannedDurationMs, 180000);
      expect(restored.duration, kStopwatchMaxDuration.inMilliseconds);
      expect(restored.trackId, 'timer-18000');
      expect(restored.fileId, 'timer-countdown-180000');
      expect(restored.timerSeed, 1234);
      expect(restored.timerEndSound, 'kalimba');
      final endCue = restored.timerBellCues!.singleWhere(
        (cue) => cue.kind == TimerBellKind.end,
      );
      expect(endCue.offsetMs, 180000);
      expect(endCue.assetKey, 'assets/audio/bells/p8-kalimba.mp3');
    },
  );

  test('distingue el sonido general, el silencio y un sonido guardado', () {
    const global = BackgroundSoundsModel(
      id: 'global',
      title: 'A',
      path: '/a',
      duration: 1,
    );
    const saved = BackgroundSoundsModel(
      id: 'saved',
      title: 'B',
      path: '/b',
      duration: 1,
    );
    final request = timerPlaybackRequest(
      mode: TimerMode.countdown,
      duration: const Duration(minutes: 1),
      filePath: '/tmp/timer.wav',
      title: 'Temporizador',
    );
    expect(request.resolveBackgroundSound(global), global);
    expect(
      request
          .copyWith(overrideBackgroundSound: true)
          .resolveBackgroundSound(global),
      isNull,
    );
    expect(
      request
          .copyWith(overrideBackgroundSound: true, backgroundSound: saved)
          .resolveBackgroundSound(global),
      saved,
    );
  });

  group('timer sessions in stats', () {
    test('count as sessions and minutes but are not tracksChecked', () {
      final stats = LocalAllStats.empty().copyWith(tracksChecked: ['abc']);
      final updated = AudioCompletionTracker.updateStatsWithCompletedAudio(
        stats: stats,
        audioCompleted: LocalAudioCompleted(
          id: timerSessionId(const Duration(minutes: 10)),
          timestamp: DateTime(2026, 10, 7, 9).millisecondsSinceEpoch,
        ),
        duration: 600000,
      );
      expect(updated.totalTracksCompleted, 1);
      expect(updated.totalTimeListened, 600000);
      expect(updated.audioCompleted!.single.id, 'timer-600');
      expect(updated.tracksChecked, ['abc']);
    });

    test('first-ever session from a timer leaves tracksChecked empty', () {
      final updated = AudioCompletionTracker.updateStatsWithCompletedAudio(
        stats: null,
        audioCompleted: LocalAudioCompleted(id: 'timer-60', timestamp: 1),
        duration: 60000,
      );
      expect(updated.tracksChecked, isEmpty);
      expect(updated.totalTracksCompleted, 1);
    });
  });
}
