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
    for (final (position, cue) in [
      (0, start),
      (0, null),
      (7999, null),
      (8001, interval),
      (8100, null),
      (7999, null),
      (8001, null),
      (16000, end),
    ]) {
      expect(schedule.update(position, enabled: true), cue);
    }
  });

  test('consume el retraso de dos segundos y acepta uno de 1999 ms', () {
    final schedule = TimerBellSchedule([start, interval, end]);
    expect(schedule.update(2000, enabled: true), isNull);
    expect(schedule.update(9999, enabled: true), interval);
    expect(schedule.update(18000, enabled: true), isNull);
    expect(schedule.update(18001, enabled: true), isNull);
  });

  test('avanzar consume, retroceder rearma las campanas posteriores', () {
    final schedule = TimerBellSchedule([start, interval, end]);
    schedule.seek(8000);
    expect(schedule.update(8000, enabled: true), isNull);
    expect(schedule.update(16001, enabled: true), end);
    schedule.seek(7999);
    expect(schedule.update(7999, enabled: true), isNull);
    expect(schedule.update(8000, enabled: true), interval);
    schedule.seek(0);
    expect(schedule.update(100, enabled: true), isNull);
  });

  test('apagar consume y volver a encender conserva el avance', () {
    final schedule = TimerBellSchedule([start, interval, end]);
    expect(schedule.update(0, enabled: false), isNull);
    expect(schedule.update(1, enabled: true), isNull);
    expect(schedule.update(8000, enabled: false), isNull);
    expect(schedule.update(8001, enabled: true), isNull);
    expect(schedule.update(16000, enabled: true), end);
    schedule.reset();
    expect(schedule.update(0, enabled: true), start);
  });

  test('una lista vacía queda en silencio', () {
    final schedule = TimerBellSchedule([]);
    expect(schedule.update(0, enabled: true), isNull);
    expect(schedule.update(7200000, enabled: true), isNull);
  });

  test('devuelve el cierre con su archivo al cruzar el margen', () {
    final cues = buildTimerBellCues(
      settings: const TimerBellSettings(),
      mode: TimerMode.countdown,
      plannedDuration: const Duration(minutes: 1),
      extraTime: false,
      seed: 1,
    );
    final schedule = TimerBellSchedule(cues);
    expect(schedule.update(0, enabled: true), cues.first);
    expect(schedule.update(53499, enabled: true), isNull);
    expect(
      schedule.update(53500, enabled: true),
      TimerBellCue(
        53500,
        TimerBellKind.end,
        BellSound.resolve(defaultBellSoundId).assetKey,
      ),
    );
  });
}
