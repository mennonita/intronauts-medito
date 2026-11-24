import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/utils/day_boundary.dart';

void main() {
  group('dayOf - default offset (Duration.zero)', () {
    test('strips time-of-day, returning local midnight', () {
      final t = DateTime(2026, 5, 18, 17, 42, 13, 999);
      expect(dayOf(t), DateTime(2026, 5, 18));
    });

    test('an already-normalised midnight is returned unchanged', () {
      final t = DateTime(2026, 5, 18);
      expect(dayOf(t), t);
    });

    test('one minute before midnight stays on the same day', () {
      final t = DateTime(2026, 5, 18, 23, 59);
      expect(dayOf(t), DateTime(2026, 5, 18));
    });

    test('exact midnight is the next day', () {
      final t = DateTime(2026, 5, 19, 0, 0);
      expect(dayOf(t), DateTime(2026, 5, 19));
    });
  });

  group('dayOf - positive offset (day starts later than midnight)', () {
    // +4h means a user's "day" starts at 04:00 local time.
    // A session at 02:00 should bucket to the previous calendar day.
    const offset = Duration(hours: 4);

    test('01:00 on May 18 buckets as May 17', () {
      final t = DateTime(2026, 5, 18, 1, 0);
      expect(dayOf(t, offset), DateTime(2026, 5, 17));
    });

    test('03:59:59 on May 18 still buckets as May 17', () {
      final t = DateTime(2026, 5, 18, 3, 59, 59);
      expect(dayOf(t, offset), DateTime(2026, 5, 17));
    });

    test('exactly 04:00 on May 18 buckets as May 18 (boundary inclusive)', () {
      final t = DateTime(2026, 5, 18, 4, 0);
      expect(dayOf(t, offset), DateTime(2026, 5, 18));
    });

    test('05:00 on May 18 buckets as May 18', () {
      final t = DateTime(2026, 5, 18, 5, 0);
      expect(dayOf(t, offset), DateTime(2026, 5, 18));
    });

    test('23:59 on May 18 buckets as May 18 (not yet next boundary)', () {
      final t = DateTime(2026, 5, 18, 23, 59);
      expect(dayOf(t, offset), DateTime(2026, 5, 18));
    });
  });

  group('dayOf - negative offset (day starts earlier than midnight)', () {
    // -2h means a user's "day" starts at 22:00 the previous calendar evening.
    // A session at 23:00 should bucket to the next calendar day.
    const offset = Duration(hours: -2);

    test('21:59 on May 18 buckets as May 18', () {
      final t = DateTime(2026, 5, 18, 21, 59);
      expect(dayOf(t, offset), DateTime(2026, 5, 18));
    });

    test('exactly 22:00 on May 18 buckets as May 19', () {
      final t = DateTime(2026, 5, 18, 22, 0);
      expect(dayOf(t, offset), DateTime(2026, 5, 19));
    });

    test('23:30 on May 18 buckets as May 19', () {
      final t = DateTime(2026, 5, 18, 23, 30);
      expect(dayOf(t, offset), DateTime(2026, 5, 19));
    });
  });

  group('dayOf - month and year boundaries with offset', () {
    test(
      '02:00 on Jan 1 with +4h offset rolls back to Dec 31 of prior year',
      () {
        final t = DateTime(2026, 1, 1, 2, 0);
        expect(dayOf(t, const Duration(hours: 4)), DateTime(2025, 12, 31));
      },
    );

    test('02:00 on May 1 with +4h offset rolls back to Apr 30', () {
      final t = DateTime(2026, 5, 1, 2, 0);
      expect(dayOf(t, const Duration(hours: 4)), DateTime(2026, 4, 30));
    });

    test(
      '23:00 on Dec 31 with -2h offset rolls forward to Jan 1 next year',
      () {
        final t = DateTime(2025, 12, 31, 23, 0);
        expect(dayOf(t, const Duration(hours: -2)), DateTime(2026, 1, 1));
      },
    );

    test('02:00 on Mar 1 (non-leap year) with +4h offset → Feb 28', () {
      final t = DateTime(2025, 3, 1, 2, 0);
      expect(dayOf(t, const Duration(hours: 4)), DateTime(2025, 2, 28));
    });

    test('02:00 on Mar 1 (leap year) with +4h offset → Feb 29', () {
      final t = DateTime(2024, 3, 1, 2, 0);
      expect(dayOf(t, const Duration(hours: 4)), DateTime(2024, 2, 29));
    });
  });

  group('dayOf - randomized properties', () {
    // Seed is fixed so failures are reproducible.
    final rng = Random(20260518); // fixed seed for reproducibility

    test('dayOf(t, offset) is always at local midnight (h=m=s=ms=0)', () {
      for (var i = 0; i < 200; i++) {
        final t = _randomDateTime(rng);
        final offset = _randomOffset(rng);
        final out = dayOf(t, offset);
        expect(out.hour, 0, reason: 't=$t offset=$offset');
        expect(out.minute, 0, reason: 't=$t offset=$offset');
        expect(out.second, 0, reason: 't=$t offset=$offset');
        expect(out.millisecond, 0, reason: 't=$t offset=$offset');
      }
    });

    test('a timestamp exactly at the boundary belongs to the new user-day', () {
      // For any offset of N whole hours, a timestamp at HH:00:00 where
      // HH == N should bucket to the same calendar day.
      for (final hours in const [1, 2, 3, 4, 5, 6, 8, 10, 12]) {
        final offset = Duration(hours: hours);
        final t = DateTime(2026, 5, 18, hours, 0);
        expect(
          dayOf(t, offset),
          DateTime(2026, 5, 18),
          reason: 'offset=$offset boundary moment should be inclusive',
        );
        // One millisecond before should belong to the previous day.
        final beforeBoundary = t.subtract(const Duration(milliseconds: 1));
        expect(
          dayOf(beforeBoundary, offset),
          DateTime(2026, 5, 17),
          reason:
              'offset=$offset one ms before boundary belongs to '
              'previous user-day',
        );
      }
    });

    test('shifting a timestamp by one user-day always advances the bucket', () {
      for (var i = 0; i < 50; i++) {
        final t = _randomDateTime(rng);
        final offset = _randomOffset(rng);
        final today = dayOf(t, offset);
        // La misma hora de reloj al día siguiente cae en el siguiente día
        // del usuario, aunque haya un cambio de horario en medio (entonces
        // no son 24 h exactas).
        final nextWallClock = DateTime(
          t.year,
          t.month,
          t.day + 1,
          t.hour,
          t.minute,
          t.second,
          t.millisecond,
        );
        final tomorrow = dayOf(nextWallClock, offset);
        expect(
          tomorrow,
          DateTime(today.year, today.month, today.day + 1),
          reason: 't=$t offset=$offset today=$today tomorrow=$tomorrow',
        );
      }
    });

    test(
      'dayOf is monotonic: t1 <= t2 ⇒ dayOf(t1) <= dayOf(t2) for same offset',
      () {
        for (var i = 0; i < 100; i++) {
          final a = _randomDateTime(rng);
          final b = _randomDateTime(rng);
          final offset = _randomOffset(rng);
          final earlier = a.isBefore(b) ? a : b;
          final later = a.isBefore(b) ? b : a;
          final dEarlier = dayOf(earlier, offset);
          final dLater = dayOf(later, offset);
          expect(
            dEarlier.isAfter(dLater),
            false,
            reason:
                'earlier=$earlier later=$later offset=$offset '
                'dEarlier=$dEarlier dLater=$dLater',
          );
        }
      },
    );
  });

  // Corre con TZ=America/New_York para que haya cambios de horario reales.
  // En 2026 el adelanto es el 8 de marzo (02:00 → 03:00) y el atraso el
  // 1 de noviembre (02:00 → 01:00). Sin horario de verano en la zona, estas
  // pruebas siguen siendo válidas: solo usan horas de reloj.
  group('dayOf - cambios de horario con desfase distinto de 0', () {
    const four = Duration(hours: 4);
    const minusTwo = Duration(hours: -2);

    test('adelanto: 04:30 con inicio a las 04:00 es de ese mismo día', () {
      expect(dayOf(DateTime(2026, 3, 8, 4, 30), four), DateTime(2026, 3, 8));
    });

    test('adelanto: 03:59 todavía es del día anterior', () {
      expect(dayOf(DateTime(2026, 3, 8, 3, 59), four), DateTime(2026, 3, 7));
    });

    test('adelanto: 04:00 exactas empiezan el día', () {
      expect(dayOf(DateTime(2026, 3, 8, 4), four), DateTime(2026, 3, 8));
    });

    test('atraso: 03:30 con inicio a las 04:00 es del día anterior', () {
      expect(dayOf(DateTime(2026, 11, 1, 3, 30), four), DateTime(2026, 10, 31));
    });

    test('atraso: 04:00 exactas empiezan el día', () {
      expect(dayOf(DateTime(2026, 11, 1, 4), four), DateTime(2026, 11, 1));
    });

    test('desfase negativo en ambos cambios: 22:00 abre el día siguiente', () {
      expect(dayOf(DateTime(2026, 3, 7, 22), minusTwo), DateTime(2026, 3, 8));
      expect(
        dayOf(DateTime(2026, 3, 7, 21, 59), minusTwo),
        DateTime(2026, 3, 7),
      );
      expect(
        dayOf(DateTime(2026, 10, 31, 22), minusTwo),
        DateTime(2026, 11, 1),
      );
      expect(
        dayOf(DateTime(2026, 10, 31, 21, 59), minusTwo),
        DateTime(2026, 10, 31),
      );
    });

    test('una fecha UTC usa sus propios campos', () {
      expect(
        dayOf(DateTime.utc(2026, 3, 8, 4, 30), four),
        DateTime(2026, 3, 8),
      );
    });
  });
}

DateTime _randomDateTime(Random rng) {
  // Span a couple of years around "now" so we cross month/year boundaries.
  final year = 2024 + rng.nextInt(4); // 2024..2027
  final month = 1 + rng.nextInt(12);
  final day = 1 + rng.nextInt(28); // safe for every month
  final hour = rng.nextInt(24);
  final minute = rng.nextInt(60);
  final second = rng.nextInt(60);
  final ms = rng.nextInt(1000);
  return DateTime(year, month, day, hour, minute, second, ms);
}

Duration _randomOffset(Random rng) {
  // Realistic offsets only: -6h..+12h, in 15-minute steps.
  // 4*24+1 = 97 buckets centered roughly around midnight.
  final quarterHours = -6 * 4 + rng.nextInt(18 * 4 + 1); // -24..+72 quarters
  return Duration(minutes: quarterHours * 15);
}
