import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/services/reminders/mindfulness_bells_service.dart';
import 'package:medito/utils/local_time_zone.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const enabled = MindfulnessBellsConfig(enabled: true);
  final l10n = lookupAppLocalizations(const Locale('es'));
  final ids = List.generate(24, (index) => 7100 + index);

  MindfulnessBellsService service(
    _FakeNotifications plugin, {
    required DateTime now,
    String timeZone = 'America/Mexico_City',
  }) => MindfulnessBellsService(
    notifications: plugin,
    initializeTimeZone: () => ensureLocalTimeZone(
      timeZoneId: () async {
        expect(plugin.cancelled, isEmpty);
        return timeZone;
      },
    ),
    now: () => now,
    localizations: () => l10n,
  );

  tearDown(() => tz.setLocalLocation(tz.UTC));

  group('slots', () {
    List<int> slots(int start, int end, int every) =>
        MindfulnessBellsService.slots(
          startHour: start,
          endHour: end,
          everyHours: every,
        );

    test('starts at the chosen hour and excludes the end', () {
      expect(slots(9, 18, 2), [9, 11, 13, 15, 17]);
      expect(slots(6, 18, 4), [6, 10, 14]);
      expect(slots(22, 23, 4), [22]);
      expect(slots(0, 24, 1), List.generate(24, (hour) => hour));
    });

    test('rejects invalid bounds and intervals', () {
      expect(slots(18, 9, 2), isEmpty);
      expect(slots(9, 9, 2), isEmpty);
      expect(slots(9, 18, 0), isEmpty);
      expect(slots(9, 18, -1), isEmpty);
      expect(slots(-1, 18, 2), isEmpty);
      expect(slots(9, 25, 2), isEmpty);
    });
  });

  test(
    'replaces all bell IDs with repeating local bells and localized copy',
    () async {
      final plugin = _FakeNotifications();
      await service(plugin, now: DateTime.utc(2026, 1, 12, 16)).apply(enabled);

      expect(plugin.cancelled, ids);
      expect(plugin.scheduled.map((bell) => bell.id), ids.take(5));
      expect(plugin.scheduled.map((bell) => bell.date.hour), [
        9,
        11,
        13,
        15,
        17,
      ]);
      expect(plugin.scheduled.map((bell) => bell.date.day), [
        13,
        12,
        12,
        12,
        12,
      ]);
      for (final bell in plugin.scheduled) {
        expect(bell.cancellationsBeforeScheduling, ids.length);
        expect(bell.date.minute, 0);
        expect(bell.title, l10n.mindfulnessBellNotificationTitle);
        expect(bell.body, l10n.mindfulnessBellNotificationBody);
        expect(bell.repeat, DateTimeComponents.time);
        expect(bell.mode, AndroidScheduleMode.inexactAllowWhileIdle);
        final android = bell.details.android!;
        expect(android.channelId, 'mindfulness_bells');
        expect(android.channelName, l10n.mindfulnessBellsTitle);
        expect(android.importance, Importance.defaultImportance);
        expect(android.playSound, isTrue);
        expect(
          (android.sound as RawResourceAndroidNotificationSound).sound,
          'intronauts_bell',
        );
        expect(bell.details.iOS!.presentSound, isTrue);
      }
    },
  );

  test('disabled bells only cancel the reserved IDs', () async {
    final plugin = _FakeNotifications();
    await service(
      plugin,
      now: DateTime.utc(2026, 1, 12),
    ).apply(const MindfulnessBellsConfig());

    expect(plugin.cancelled, ids);
    expect(plugin.scheduled, isEmpty);
  });

  for (final (zone, julyOffset) in [
    ('America/Mexico_City', -6),
    ('America/Chicago', -5),
  ]) {
    test('schedules 09:00 local in January and July in $zone', () async {
      for (final (month, offset) in [(1, -6), (7, julyOffset)]) {
        final plugin = _FakeNotifications();
        await service(
          plugin,
          now: DateTime.utc(2026, month, 12, 13),
          timeZone: zone,
        ).apply(enabled);

        final date = plugin.scheduled.first.date;
        expect(date.location.name, zone);
        expect(date.hour, 9);
        expect(date.timeZoneOffset, Duration(hours: offset));
        expect(date.toUtc(), DateTime.utc(2026, month, 12, 9 - offset));
      }
    });
  }

  test('chooses the next local date across a daylight saving change', () async {
    final plugin = _FakeNotifications();
    await service(
      plugin,
      now: DateTime.utc(2026, 3, 7, 15),
      timeZone: 'America/Chicago',
    ).apply(enabled);

    expect(plugin.scheduled.first.date.toUtc(), DateTime.utc(2026, 3, 8, 14));
  });
}

typedef _ScheduledBell = ({
  int id,
  String title,
  String body,
  tz.TZDateTime date,
  NotificationDetails details,
  DateTimeComponents repeat,
  AndroidScheduleMode mode,
  int cancellationsBeforeScheduling,
});

class _FakeNotifications implements MindfulnessBellsNotifications {
  final cancelled = <int>[];
  final scheduled = <_ScheduledBell>[];

  @override
  Future<void> cancel({required int id}) async => cancelled.add(id);

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required DateTimeComponents matchDateTimeComponents,
    required AndroidScheduleMode androidScheduleMode,
  }) async {
    scheduled.add((
      id: id,
      title: title,
      body: body,
      date: scheduledDate,
      details: notificationDetails,
      repeat: matchDateTimeComponents,
      mode: androidScheduleMode,
      cancellationsBeforeScheduling: cancelled.length,
    ));
  }
}
