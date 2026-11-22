import 'package:flutter_test/flutter_test.dart';
import 'package:medito/services/audio/timer_bell_schedule.dart';

void main() {
  test('toca una vez al cruzar cada campana, incluyendo el inicio', () {
    final schedule = TimerBellSchedule([0, 8000, 16000]);
    for (final (position, cue) in [
      (0, 0),
      (0, null),
      (7999, null),
      (8001, 8000),
      (8100, null),
      (7999, null),
      (8001, null),
      (16000, 16000),
    ]) {
      expect(schedule.update(position, enabled: true), cue);
    }
  });

  test('consume el retraso de dos segundos y acepta uno de 1999 ms', () {
    final schedule = TimerBellSchedule([0, 8000, 16000]);
    expect(schedule.update(2000, enabled: true), isNull);
    expect(schedule.update(9999, enabled: true), 8000);
    expect(schedule.update(18000, enabled: true), isNull);
    expect(schedule.update(18001, enabled: true), isNull);
  });

  test('avanzar consume, retroceder rearma y cero reinicia', () {
    final schedule = TimerBellSchedule([0, 8000, 16000]);
    schedule.seek(8000);
    expect(schedule.update(8000, enabled: true), isNull);
    expect(schedule.update(16001, enabled: true), 16000);
    schedule.seek(7999);
    expect(schedule.update(7999, enabled: true), isNull);
    expect(schedule.update(8000, enabled: true), 8000);
    schedule.seek(0);
    expect(schedule.update(100, enabled: true), 0);
  });

  test('apagar consume y volver a encender conserva el avance', () {
    final schedule = TimerBellSchedule([0, 8000, 16000]);
    expect(schedule.update(0, enabled: false), isNull);
    expect(schedule.update(1, enabled: true), isNull);
    expect(schedule.update(8000, enabled: false), isNull);
    expect(schedule.update(8001, enabled: true), isNull);
    expect(schedule.update(16000, enabled: true), 16000);
    schedule.reset();
    expect(schedule.update(0, enabled: true), 0);
  });

  test('una lista vacía queda en silencio', () {
    final schedule = TimerBellSchedule([]);
    expect(schedule.update(0, enabled: true), isNull);
    expect(schedule.update(7200000, enabled: true), isNull);
  });

  test('el cronómetro reproduce las tres campanas de cinco horas', () {
    final schedule = TimerBellSchedule([0, 9000000, 17994000]);
    expect(schedule.update(0, enabled: true), 0);
    expect(schedule.update(9000000, enabled: true), 9000000);
    expect(schedule.update(17994000, enabled: true), 17994000);
    expect(schedule.update(18000000, enabled: true), isNull);
  });
}
