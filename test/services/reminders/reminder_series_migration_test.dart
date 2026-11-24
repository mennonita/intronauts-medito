import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/providers/notification/reminder_provider.dart';
import 'package:medito/services/reminders/daily_reminders_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class _Scheduled {
  _Scheduled(this.id, this.date, this.title, this.details);

  final int id;
  final tz.TZDateTime date;
  final String? title;
  final NotificationDetails details;
}

/// Plugin falso que recuerda qué avisos quedan pendientes.
class _FakePlugin extends Fake implements FlutterLocalNotificationsPlugin {
  _FakePlugin(Iterable<int> pendingIndexes)
    : pending = {for (final i in pendingIndexes) reminderSeriesBaseId + i};

  final Set<int> pending;
  final scheduled = <_Scheduled>[];
  var calls = 0;
  var failScheduling = false;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async => true;

  @override
  Future<void> zonedSchedule({
    required int id,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    calls++;
    if (failScheduling) throw StateError('No se pudo programar');
    scheduled.add(_Scheduled(id, scheduledDate, title, notificationDetails));
    pending.add(id);
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    calls++;
    pending.remove(id);
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    calls++;
    return [
      for (final id in pending) PendingNotificationRequest(id, 't', 'b', null),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();

  final es = lookupAppLocalizations(const Locale('es'));
  // Lunes 12 de enero de 2026, 9:00; la hora guardada (7:30) ya pasó hoy.
  final now = DateTime(2026, 1, 12, 9);

  late _FakePlugin plugin;
  late SharedPreferences prefs;

  Future<void> setUpWith(
    Iterable<int> pendingIndexes, {
    bool enabled = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      SharedPreferenceConstants.dailyReminderEnabled: enabled,
      SharedPreferenceConstants.savedHours: 7,
      SharedPreferenceConstants.savedMinutes: 30,
    });
    prefs = await SharedPreferences.getInstance();
    plugin = _FakePlugin(pendingIndexes);
    ReminderProvider.pluginFactory = () => plugin;
  }

  Future<void> migrate({DateTime? at}) => DailyRemindersScheduler(
    prefs: prefs,
    reminders: ReminderProvider(),
  ).migratePendingSeries(now: () => at ?? now, l10n: es);

  setUp(() {
    ReminderProvider.resetForTesting();
    ReminderProvider.timeZoneSetup = () async {};
    tz.setLocalLocation(tz.getLocation('America/Mexico_City'));
  });

  tearDown(() {
    ReminderProvider.resetForTesting();
    tz.setLocalLocation(tz.UTC);
  });

  (int, int, int, int, int) fields(tz.TZDateTime d) =>
      (d.year, d.month, d.day, d.hour, d.minute);

  test('pendientes 3..15: reprograma desde el 3 a la próxima hora', () async {
    await setUpWith([for (var i = 3; i <= 15; i++) i]);

    await migrate();

    expect(plugin.scheduled.map((e) => e.id), [
      for (var i = 3; i <= 15; i++) reminderSeriesBaseId + i,
    ]);
    // El aviso 3 suena mañana a las 7:30 y los demás conservan su día.
    expect(fields(plugin.scheduled.first.date), (2026, 1, 13, 7, 30));
    expect(fields(plugin.scheduled[1].date), (2026, 1, 14, 7, 30));
    expect(fields(plugin.scheduled[11].date), (2026, 1, 24, 7, 30));
    // El del día 30 queda 29 días después del ancla (10 de enero).
    expect(fields(plugin.scheduled.last.date), (2026, 2, 8, 7, 30));
    // Textos y botones nuevos.
    expect(plugin.scheduled.first.title, es.reminderDay4Title);
    expect(plugin.scheduled.last.title, es.reminderDay30Title);
    for (final item in plugin.scheduled) {
      expect(item.details.android!.actions!.map((a) => a.title), [
        es.reminderActionSit3,
        es.reminderActionNotToday,
      ]);
      expect(item.details.iOS!.categoryIdentifier, kReminderCategoryId);
    }
    expect(prefs.getBool(reminderSeriesCopyV2Key), isTrue);
    // La hora guardada no cambia.
    expect(prefs.getInt(SharedPreferenceConstants.savedHours), 7);
    expect(prefs.getInt(SharedPreferenceConstants.savedMinutes), 30);
  });

  test('antes de la hora guardada, el siguiente aviso es hoy', () async {
    await setUpWith([0, 1, 2, 15]);

    await migrate(at: DateTime(2026, 1, 12, 6));

    expect(plugin.scheduled, hasLength(16));
    expect(fields(plugin.scheduled.first.date), (2026, 1, 12, 7, 30));
  });

  test('solo el del día 30: próxima hora guardada + 7 días', () async {
    await setUpWith([15]);

    await migrate();

    expect(plugin.scheduled.map((e) => e.id), [reminderSeriesBaseId + 15]);
    expect(fields(plugin.scheduled.single.date), (2026, 1, 20, 7, 30));
    expect(plugin.scheduled.single.title, es.reminderDay30Title);
    expect(prefs.getBool(reminderSeriesCopyV2Key), isTrue);
  });

  test('sin avisos pendientes no programa nada y marca la pref', () async {
    // Otros avisos (no de la serie) no cuentan.
    await setUpWith([]);
    plugin.pending.add(dailyNotificationId);

    await migrate();

    expect(plugin.scheduled, isEmpty);
    expect(plugin.pending, {dailyNotificationId});
    expect(prefs.getBool(reminderSeriesCopyV2Key), isTrue);
  });

  test('corre una sola vez: la segunda vez no hace nada', () async {
    await setUpWith([5, 6, 7, 15]);

    await migrate();
    expect(plugin.scheduled, hasLength(11));
    final callsAfterFirst = plugin.calls;

    await migrate();
    expect(plugin.calls, callsAfterFirst);
    expect(plugin.scheduled, hasLength(11));
  });

  test('con avisos apagados no hace nada', () async {
    await setUpWith([3, 4, 15], enabled: false);

    await migrate();

    expect(plugin.calls, 0);
    expect(prefs.getBool(reminderSeriesCopyV2Key), isNull);
  });

  test('si programar falla, no marca la pref', () async {
    await setUpWith([3, 15]);
    plugin.failScheduling = true;

    await migrate();

    expect(prefs.getBool(reminderSeriesCopyV2Key), isNull);
  });
}
