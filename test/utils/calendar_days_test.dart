import 'package:flutter_test/flutter_test.dart';
import 'package:medito/utils/calendar_days.dart';

void main() {
  group('calendarDaysBetween', () {
    test('cuenta días de calendario, no bloques de 24 h', () {
      expect(
        calendarDaysBetween(DateTime(2026, 1, 1), DateTime(2026, 1, 1)),
        0,
      );
      expect(
        calendarDaysBetween(DateTime(2026, 1, 1), DateTime(2026, 1, 31)),
        30,
      );
      expect(
        calendarDaysBetween(DateTime(2026, 1, 31), DateTime(2026, 1, 1)),
        -30,
      );
      expect(
        calendarDaysBetween(DateTime(2026, 1, 1, 23, 59), DateTime(2026, 1, 2)),
        1,
      );
    });

    // Fechas de cambio de horario en EE. UU. (zona con horario de verano).
    // Con TZ del sistema en una zona así, la diferencia entre medianoches
    // locales es de 23 o 25 horas; el resultado debe seguir siendo 1.
    test('medianoches seguidas alrededor del cambio de marzo dan 1', () {
      final before = DateTime(2026, 3, 8);
      final after = DateTime(2026, 3, 9);
      expect(calendarDaysBetween(before, after), 1);
      expect(
        calendarDaysBetween(DateTime(2026, 3, 1), DateTime(2026, 3, 15)),
        14,
      );
    });

    test('medianoches seguidas alrededor del cambio de noviembre dan 1', () {
      final before = DateTime(2026, 11, 1);
      final after = DateTime(2026, 11, 2);
      expect(calendarDaysBetween(before, after), 1);
      expect(
        calendarDaysBetween(DateTime(2026, 10, 25), DateTime(2026, 11, 8)),
        14,
      );
    });

    test('una semana con cambio de horario: siete pasos de un día', () {
      for (final start in [DateTime(2026, 3, 5), DateTime(2026, 10, 29)]) {
        var day = start;
        for (var i = 1; i <= 7; i++) {
          final next = addCalendarDays(day, 1);
          expect(calendarDaysBetween(day, next), 1);
          expect(next.hour, 0);
          expect(calendarDaysBetween(start, next), i);
          day = next;
        }
      }
    });

    test('en una zona con horario de verano, inDays falla y esto no', () {
      // Solo aplica si la zona del sistema cambia de horario (por ejemplo,
      // TZ=America/New_York); en UTC las dos cuentas coinciden.
      final a = DateTime(2026, 3, 8);
      final b = DateTime(2026, 3, 9);
      if (b.difference(a).inHours == 23) {
        expect(b.difference(a).inDays, 0);
      }
      expect(calendarDaysBetween(a, b), 1);
    });
  });

  group('addCalendarDays', () {
    test('cae a medianoche aunque cruce fin de mes y año', () {
      expect(addCalendarDays(DateTime(2026, 12, 31), 1), DateTime(2027, 1, 1));
      expect(addCalendarDays(DateTime(2026, 3, 1), -1), DateTime(2026, 2, 28));
      expect(
        addCalendarDays(DateTime(2026, 3, 8, 15), 0),
        DateTime(2026, 3, 8),
      );
    });
  });
}
