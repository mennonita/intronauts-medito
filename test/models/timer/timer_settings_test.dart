import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_settings.dart';

void main() {
  const stages = [
    TimerStage(kind: TimerStageKind.sit, minutes: 20, sound: 'diapason'),
    TimerStage(kind: TimerStageKind.walk, minutes: 10, repeats: 2),
    TimerStage(kind: TimerStageKind.sit, minutes: 20),
  ];

  test('un bloque: previsto, tiempo extra, preparación y archivo', () {
    const settings = TimerSettings(
      mode: TimerMode.countdown,
      minutes: 15,
      extraTime: true,
      prepSeconds: 30,
    );
    expect(settings.isMultiStage, isFalse);
    expect(settings.plannedDuration, const Duration(minutes: 15));
    expect(settings.sessionDuration, settings.plannedDuration);
    expect(settings.hasExtraTime, isTrue);
    expect(settings.prepDuration, const Duration(seconds: 30));
    expect(
      settings.fileDuration,
      const Duration(seconds: 30, minutes: 15) + kStopwatchMaxDuration,
    );
    expect(
      settings.copyWith(extraTime: false).fileDuration,
      const Duration(seconds: 30 + 15 * 60 + 6, milliseconds: 1500),
    );
    expect(settings.canStart, isTrue);
    expect(settings.copyWith(minutes: 0).canStart, isFalse);
  });

  test('cronómetro: 5 h previstas y archivo con cola', () {
    const settings = TimerSettings(
      mode: TimerMode.stopwatch,
      minutes: 0,
      stages: stages,
      extraTime: true,
    );
    expect(settings.isMultiStage, isFalse);
    expect(settings.hasExtraTime, isFalse);
    expect(settings.plannedDuration, kStopwatchMaxDuration);
    expect(
      settings.fileDuration,
      kStopwatchMaxDuration + const Duration(milliseconds: 7500),
    );
    expect(settings.canStart, isTrue);
  });

  test('por partes: suma, sin tiempo extra y límites para empezar', () {
    const settings = TimerSettings(
      mode: TimerMode.countdown,
      minutes: 0,
      stages: stages,
      extraTime: true,
    );
    expect(settings.isMultiStage, isTrue);
    expect(settings.plannedDuration, const Duration(minutes: 50));
    expect(settings.hasExtraTime, isFalse);
    expect(settings.canStart, isTrue);
    expect(
      settings.fileDuration,
      const Duration(minutes: 50, seconds: 7, milliseconds: 500),
    );
    expect(
      settings.copyWith(stages: stages.take(1).toList()).isMultiStage,
      isFalse,
    );
    expect(
      settings
          .copyWith(
            stages: [
              ...stages,
              const TimerStage(kind: TimerStageKind.sit, minutes: 250),
            ],
          )
          .canStart,
      isFalse,
    );
    expect(
      settings
          .copyWith(
            stages: [
              stages.first,
              const TimerStage(kind: TimerStageKind.rest, minutes: 0),
            ],
          )
          .canStart,
      isFalse,
    );
  });

  test('una parte con repeticiones fuera de 1 a 3 no puede empezar', () {
    for (final repeats in [0, 4]) {
      final settings = TimerSettings(
        mode: TimerMode.countdown,
        minutes: 0,
        stages: [
          stages.first,
          TimerStage(kind: TimerStageKind.walk, minutes: 5, repeats: repeats),
        ],
      );
      expect(settings.canStart, isFalse, reason: '$repeats');
      expect(settings.stages.last.isValid, isFalse);
      expect(settings.stages.last.clamped().isValid, isTrue);
    }
  });

  test('los ajustes de la última sesión vuelven completos', () {
    const settings = TimerSettings(
      mode: TimerMode.countdown,
      minutes: 25,
      extraTime: true,
      prepSeconds: 60,
      stages: stages,
      bells: TimerBellSettings(
        start: false,
        intervalMinutes: 5,
        randomCount: 3,
        endSound: 'campana_templo',
        endRepeats: 3,
        output: TimerBellOutput.soundAndVibration,
        spokenCues: true,
      ),
    );
    final json = settings.toSnapshotJson();
    expect(json.keys, [
      'mode',
      'minutes',
      'bells',
      'extraTime',
      'prepSeconds',
      'stages',
    ]);
    final decoded = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
    final restored = TimerSettings.fromSnapshotJson(decoded)!;
    expect(restored.toSnapshotJson(), json);
    expect(restored.stages, stages);
    expect(restored.prepSeconds, 60);
    expect(restored.bells.output, TimerBellOutput.soundAndVibration);
    expect(restored.bells.spokenCues, isTrue);

    final stopwatch = TimerSettings.fromSnapshotJson(
      const TimerSettings(
        mode: TimerMode.stopwatch,
        minutes: 0,
      ).toSnapshotJson(),
    )!;
    expect(stopwatch.mode, TimerMode.stopwatch);
    expect(stopwatch.stages, isEmpty);
  });

  test('ajustes antiguos o dañados de la última sesión', () {
    final valid = const TimerSettings(
      mode: TimerMode.countdown,
      minutes: 10,
    ).toSnapshotJson();
    final old = Map<String, dynamic>.of(valid)
      ..remove('prepSeconds')
      ..remove('stages');
    final restored = TimerSettings.fromSnapshotJson(old)!;
    expect(restored.prepSeconds, 0);
    expect(restored.stages, isEmpty);
    expect(
      TimerSettings.fromSnapshotJson({
        ...valid,
        'prepSeconds': 99999,
      })!.prepSeconds,
      kMaxTimerPrepSeconds,
    );
    expect(
      TimerSettings.fromSnapshotJson({
        ...valid,
        'prepSeconds': -5,
      })!.prepSeconds,
      0,
    );
    expect(
      TimerSettings.fromSnapshotJson({
        ...valid,
        'minutes': 0,
      }, requireStart: false)?.minutes,
      0,
    );
    for (final broken in [
      <String, dynamic>{},
      {...valid, 'mode': 'otro'},
      {...valid, 'mode': 3},
      {...valid, 'minutes': '10'},
      {...valid, 'minutes': kMaxTimerMinutes + 1},
      {...valid, 'minutes': 0},
      {...valid, 'bells': 'nada'},
      {
        ...valid,
        'bells': {'start': true},
      },
      {...valid, 'extraTime': 'sí'},
    ]) {
      expect(TimerSettings.fromSnapshotJson(broken), isNull, reason: '$broken');
    }
  });

  test('constantes de preparación', () {
    expect(kTimerPrepOptions, [0, 10, 30, 60, 120]);
    expect(kMaxTimerPrepSeconds, 7200);
    expect(kMaxTimerStages, 6);
    expect(kMinTimerStages, 2);
  });
}
