import 'package:flutter_test/flutter_test.dart';
import 'package:medito/views/timer/timer_format.dart';

void main() {
  test('la cuenta regresiva redondea hacia arriba y limita el tiempo', () {
    String count(int position, {int planned = 120000}) => timerClockReading(
      positionMs: position,
      plannedDurationMs: planned,
    ).time;

    expect(count(-1500), '2:00');
    expect(count(119200), '0:01');
    expect(count(120000), '0:00');
    expect(count(121500), '0:00');
    expect(count(0, planned: 3901000), '1:05:01');
    expect(count(200, planned: 3600000), '1:00:00');
  });

  test('el cronómetro trunca milisegundos y muestra horas completas', () {
    String elapsed(int position) =>
        timerClockReading(positionMs: position).time;

    expect(elapsed(-1200), '0:00');
    expect(elapsed(999), '0:00');
    expect(elapsed(3599999), '59:59');
    expect(elapsed(3600000), '1:00:00');
    expect(elapsed(3723999), '1:02:03');
  });

  test('el tiempo extra cambia de fase justo en el límite previsto', () {
    ({String time, bool isExtraTime}) count(int position) => timerClockReading(
      positionMs: position,
      plannedDurationMs: 120000,
      hasExtraTime: true,
    );

    expect(count(0), (time: '2:00', isExtraTime: false));
    expect(count(119200), (time: '0:01', isExtraTime: false));
    expect(count(120000), (time: '0:00', isExtraTime: true));
    expect(count(120999), (time: '0:00', isExtraTime: true));
    expect(count(3720000), (time: '1:00:00', isExtraTime: true));
    expect(count(4020000), (time: '1:05:00', isExtraTime: true));
  });
}
