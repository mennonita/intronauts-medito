import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/services/audio/timer_bell_schedule.dart';

final start = TimerBellCue(
  0,
  TimerBellKind.start,
  BellSound.resolve('diapason').assetKey,
);
final interval = TimerBellCue(
  8000,
  TimerBellKind.interval,
  BellSound.resolve('handpan').assetKey,
);
final end = TimerBellCue(
  16000,
  TimerBellKind.end,
  BellSound.resolve('kalimba').assetKey,
);

void main() {
  test('toca una vez al cruzar cada campana, incluyendo el inicio', () {
    final schedule = TimerBellSchedule([start, interval, end]);
    for (final (position, ring) in [
      (0, [start]),
      (0, <TimerBellCue>[]),
      (7999, <TimerBellCue>[]),
      (8001, [interval]),
      (8100, <TimerBellCue>[]),
      (7999, <TimerBellCue>[]),
      (8001, <TimerBellCue>[]),
      (16000, [end]),
    ]) {
      expect(schedule.update(position, enabled: true), ring);
    }
  });

  test('las obligatorias suenan tarde; las opcionales, solo antes de 2 s', () {
    final schedule = TimerBellSchedule([start, interval, end]);
    expect(schedule.update(2000, enabled: true), [start]);
    expect(schedule.update(9999, enabled: true), [interval]);
    expect(schedule.update(18000, enabled: true), [end]);
    expect(schedule.update(18001, enabled: true), isEmpty);
  });

  test('el cierre 10 s tarde suena y un intervalo 3 s tarde no', () {
    final late = TimerBellSchedule([interval, end]);
    expect(late.update(11000, enabled: true), isEmpty);
    expect(late.update(26000, enabled: true), [end]);
  });

  test('un salto que cruza dos golpes del cierre devuelve ambos en orden', () {
    final first = TimerBellCue(60000, TimerBellKind.end, end.assetKey);
    final second = TimerBellCue(61676, TimerBellKind.end, end.assetKey);
    final schedule = TimerBellSchedule([start, first, second]);
    expect(schedule.update(0, enabled: true), [start]);
    expect(schedule.update(70000, enabled: true), [first, second]);
    expect(schedule.update(70001, enabled: true), isEmpty);
  });

  test('devuelve todas las obligatorias y solo la opcional más reciente', () {
    final stage = TimerBellCue(9000, TimerBellKind.stage, start.assetKey);
    final random = TimerBellCue(9500, TimerBellKind.random, interval.assetKey);
    final spoken = TimerBellCue(10000, TimerBellKind.spoken, 'spoken:quedan 1');
    final schedule = TimerBellSchedule([
      start,
      interval,
      stage,
      random,
      spoken,
    ]);
    expect(schedule.update(11000, enabled: true), [start, stage, spoken]);

    // Una opcional a tiempo queda en su lugar, antes de una obligatoria.
    final close = TimerBellCue(8500, TimerBellKind.end, end.assetKey);
    final ordered = TimerBellSchedule([interval, close]);
    expect(ordered.update(9000, enabled: true), [interval, close]);
  });

  test('avanzar consume, retroceder rearma las campanas posteriores', () {
    final schedule = TimerBellSchedule([start, interval, end]);
    schedule.seek(8000);
    expect(schedule.update(8000, enabled: true), isEmpty);
    expect(schedule.update(16001, enabled: true), [end]);
    schedule.seek(7999);
    expect(schedule.update(7999, enabled: true), isEmpty);
    expect(schedule.update(8000, enabled: true), [interval]);
    schedule.seek(0);
    expect(schedule.update(100, enabled: true), isEmpty);
  });

  test('apagar consume y volver a encender conserva el avance', () {
    final schedule = TimerBellSchedule([start, interval, end]);
    expect(schedule.update(0, enabled: false), isEmpty);
    expect(schedule.update(1, enabled: true), isEmpty);
    expect(schedule.update(8000, enabled: false), isEmpty);
    expect(schedule.update(8001, enabled: true), isEmpty);
    expect(schedule.update(16000, enabled: true), [end]);
    schedule.reset();
    expect(schedule.update(0, enabled: true), [start]);
  });

  test('una lista vacía queda en silencio', () {
    final schedule = TimerBellSchedule([]);
    expect(schedule.update(0, enabled: true), isEmpty);
    expect(schedule.update(7200000, enabled: true), isEmpty);
  });

  test('toca cada golpe del mismo grupo una sola vez', () {
    final cues = buildTimerBellCues(
      settings: const TimerBellSettings(
        startSound: 'bloque_madera',
        startRepeats: 3,
        end: false,
      ),
      mode: TimerMode.countdown,
      plannedDuration: const Duration(minutes: 1),
      extraTime: false,
      seed: 1,
    );
    final schedule = TimerBellSchedule(cues);
    final assetKey = BellSound.resolve('bloque_madera').assetKey;
    for (final offset in [0, 1702, 3404]) {
      expect(schedule.update(offset, enabled: true), [
        TimerBellCue(offset, TimerBellKind.start, assetKey),
      ]);
      expect(schedule.update(offset, enabled: true), isEmpty);
    }
  });

  test('devuelve el cierre con su archivo al terminar lo previsto', () {
    final cues = buildTimerBellCues(
      settings: const TimerBellSettings(),
      mode: TimerMode.countdown,
      plannedDuration: const Duration(minutes: 1),
      extraTime: false,
      seed: 1,
      prepMs: 10000,
    );
    final schedule = TimerBellSchedule(cues);
    expect(schedule.update(9999, enabled: true), isEmpty);
    expect(schedule.update(10000, enabled: true), [cues.first]);
    expect(schedule.update(69999, enabled: true), isEmpty);
    expect(schedule.update(70000, enabled: true), [
      TimerBellCue(
        70000,
        TimerBellKind.end,
        BellSound.resolve(defaultBellSoundId).assetKey,
      ),
    ]);
  });
}
