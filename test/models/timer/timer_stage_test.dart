import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_settings.dart' show kMaxTimerMinutes;
import 'package:medito/models/timer/timer_stage.dart';

void main() {
  test('guarda y lee una parte completa', () {
    const stage = TimerStage(
      kind: TimerStageKind.walk,
      minutes: 15,
      sound: 'cuenco_tibetano',
      repeats: 3,
    );
    final json = stage.toJson();
    expect(json, {
      'kind': 'walk',
      'minutes': 15,
      'sound': 'cuenco_tibetano',
      'repeats': 3,
    });
    expect(TimerStage.fromJson(json), stage);
    expect(stage.copyWith(minutes: 5).minutes, 5);
    expect(stage.copyWith(), stage);
    expect(stage.duration, const Duration(minutes: 15));
  });

  test('tolera tipos, sonidos y rangos desconocidos', () {
    expect(
      TimerStage.fromJson({'kind': 'volar', 'minutes': 0, 'repeats': 9}),
      const TimerStage(kind: TimerStageKind.sit, minutes: 1, repeats: 3),
    );
    expect(
      TimerStage.fromJson({
        'kind': 'rest',
        'minutes': 9999,
        'sound': 'eliminado',
        'repeats': 0,
      }),
      const TimerStage(
        kind: TimerStageKind.rest,
        minutes: kMaxTimerMinutes,
        sound: defaultBellSoundId,
        repeats: 1,
      ),
    );
    expect(
      TimerStage.fromJson({'kind': 'sit', 'minutes': 7.0, 'repeats': '2'}),
      const TimerStage(kind: TimerStageKind.sit, minutes: 7),
    );
  });

  test('devuelve null sin minutos utilizables o si no es un mapa', () {
    for (final json in [
      null,
      'sit',
      42,
      <Object?>[],
      {'kind': 'sit'},
      {'kind': 'sit', 'minutes': '10'},
      {'kind': 'sit', 'minutes': double.nan},
    ]) {
      expect(TimerStage.fromJson(json), isNull, reason: '$json');
    }
  });

  test('una lista guardada descarta las partes inválidas y corta en seis', () {
    final stages = timerStagesFromJson([
      {'kind': 'sit', 'minutes': 10},
      'basura',
      {'kind': 'walk'},
      for (var i = 0; i < 8; i++) {'kind': 'rest', 'minutes': i + 1},
    ]);
    expect(stages, hasLength(kMaxTimerStages));
    expect(stages.first.minutes, 10);
    expect(stages[1].kind, TimerStageKind.rest);
    expect(timerStagesFromJson(null), isEmpty);
    expect(timerStagesFromJson({'kind': 'sit'}), isEmpty);
  });
}
