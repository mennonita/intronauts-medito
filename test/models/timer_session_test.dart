import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_stage.dart';
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
      // 5 min + campana de cierre (6 s) + 1.5 s de margen.
      expect(countdown.duration, 307500);
      expect(countdown.trackId, 'timer-300');
      expect(countdown.plannedDurationMs, 300000);
      expect(countdown.timerPrepMs, 0);
      expect(countdown.timerExtraTime, isFalse);
      expect(countdown.timerStageDurationsMs, isEmpty);
      expect(countdown.timerBellOutput, 'sound');
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
      expect(stopwatch.plannedDurationMs, kStopwatchMaxDuration.inMilliseconds);
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
      expect(restored.duration, 180000 + kStopwatchMaxDuration.inMilliseconds);
      expect(restored.trackId, 'timer-180');
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

  group('archivo y campanas con preparación', () {
    PlaybackRequest request({
      TimerMode mode = TimerMode.countdown,
      Duration duration = const Duration(minutes: 10),
      TimerBellSettings bells = const TimerBellSettings(),
      bool extraTime = false,
      int prepMs = 0,
      List<TimerStage> stages = const [],
      String Function(int)? spokenText,
    }) => timerPlaybackRequest(
      mode: mode,
      duration: duration,
      filePath: '/tmp/timer.wav',
      title: 'Temporizador',
      bells: bells,
      extraTime: extraTime,
      seed: 3,
      prepMs: prepMs,
      stages: stages,
      spokenText: spokenText,
    );

    int endCue(PlaybackRequest request) => request.timerBellCues!
        .firstWhere((cue) => cue.kind == TimerBellKind.end)
        .offsetMs;

    test('cuenta regresiva: el cierre suena a prep + previsto', () {
      for (final prepMs in [0, 30000]) {
        final plain = request(prepMs: prepMs);
        expect(endCue(plain), prepMs + 600000);
        expect(plain.timerPrepMs, prepMs);
        expect(plain.plannedDurationMs, 600000);
        expect(plain.duration, prepMs + 600000 + 6000 + 1500);
        expect(plain.trackId, 'timer-600');
        expect(plain.timerBellCues!.first.offsetMs, prepMs);
      }
    });

    test('el archivo cubre los tres golpes de la campana del templo', () {
      const bells = TimerBellSettings(
        endSound: 'campana_templo',
        endRepeats: 3,
      );
      final plain = request(bells: bells);
      final ends = plain.timerBellCues!
          .where((cue) => cue.kind == TimerBellKind.end)
          .map((cue) => cue.offsetMs)
          .toList();
      expect(ends, [600000, 615547, 631094]);
      final temple = BellSound.resolve('campana_templo').durationMs;
      expect(plain.duration, ends.last + temple + 1500);
      expect(
        timerFileDuration(
          mode: TimerMode.countdown,
          planned: const Duration(minutes: 10),
          extraTime: false,
          bells: bells,
        ),
        Duration(milliseconds: ends.last + temple + 1500),
      );
      expect(
        timerFileDuration(
          mode: TimerMode.countdown,
          planned: const Duration(minutes: 10),
          extraTime: false,
          bells: bells.copyWith(end: false),
          prep: const Duration(seconds: 10),
        ),
        const Duration(minutes: 10, seconds: 11, milliseconds: 500),
      );
    });

    test(
      'tiempo extra: cierre en el límite y archivo de prep + previsto + 5 h',
      () {
        final extra = request(extraTime: true, prepMs: 30000);
        expect(extra.hasExtraTime, isTrue);
        expect(extra.timerExtraTime, isTrue);
        expect(endCue(extra), 630000);
        expect(
          extra.duration,
          30000 + 600000 + kStopwatchMaxDuration.inMilliseconds,
        );
      },
    );

    test('cronómetro: cierre a prep + 5 h y archivo con cola final', () {
      final stopwatch = request(
        mode: TimerMode.stopwatch,
        duration: kStopwatchMaxDuration,
        prepMs: 10000,
        extraTime: true,
      );
      final fiveHours = kStopwatchMaxDuration.inMilliseconds;
      expect(endCue(stopwatch), 10000 + fiveHours);
      expect(stopwatch.duration, 10000 + fiveHours + 6000 + 1500);
      expect(stopwatch.timerExtraTime, isFalse);
      expect(stopwatch.plannedDurationMs, fiveHours);
      expect(stopwatch.trackId, timerSessionId(kStopwatchMaxDuration));
      expect(
        stopwatch.timerBellCues!.map((cue) => cue.kind),
        isNot(contains(TimerBellKind.midpoint)),
      );
    });

    test('por partes: suma de partes, sin tiempo extra y con sus tipos', () {
      const stages = [
        TimerStage(kind: TimerStageKind.sit, minutes: 20, sound: 'diapason'),
        TimerStage(kind: TimerStageKind.walk, minutes: 10),
        TimerStage(kind: TimerStageKind.sit, minutes: 20),
      ];
      final parts = request(
        duration: const Duration(minutes: 50),
        stages: stages,
        extraTime: true,
        prepMs: 10000,
        bells: const TimerBellSettings(output: TimerBellOutput.vibration),
      );
      expect(parts.plannedDurationMs, 3000000);
      expect(parts.timerExtraTime, isFalse);
      expect(parts.hasExtraTime, isFalse);
      expect(parts.timerStageDurationsMs, [1200000, 600000, 1200000]);
      expect(parts.timerStageKinds, ['sit', 'walk', 'sit']);
      expect(parts.timerBellOutput, 'vibration');
      expect(parts.trackId, 'timer-3000');
      expect(parts.fileId, 'timer-countdown-3000000');
      expect(parts.duration, 10000 + 3000000 + 6000 + 1500);
      final cues = parts.timerBellCues!;
      expect(cues.first.kind, TimerBellKind.stage);
      expect(cues.first.offsetMs, 10000);
      expect(cues.first.assetKey, BellSound.resolve('diapason').assetKey);
      expect(
        cues
            .where((cue) => cue.kind == TimerBellKind.stage)
            .map((cue) => cue.offsetMs),
        [10000, 1210000, 1810000],
      );
      expect(endCue(parts), 3010000);
      expect(PlaybackRequest.fromJson(parts.toJson()), parts);
    });

    test('pasa el texto de los avisos hablados', () {
      final withSpoken = request(
        duration: const Duration(minutes: 11),
        bells: const TimerBellSettings(spokenCues: true),
        spokenText: (minutes) => 'faltan $minutes',
      );
      expect(
        withSpoken.timerBellCues!
            .where((cue) => cue.kind == TimerBellKind.spoken)
            .map((cue) => cue.assetKey),
        ['spoken:faltan 10', 'spoken:faltan 5', 'spoken:faltan 1'],
      );
    });
  });

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
