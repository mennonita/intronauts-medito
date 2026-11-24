import 'dart:async';

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

  /// Identificadores que fallan al programarse.
  final failIds = <int>{};

  /// Si no es null, la lectura de pendientes espera a que se complete.
  Completer<void>? pendingGate;

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
    if (failScheduling || failIds.contains(id)) {
      throw StateError('No se pudo programar');
    }
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
    // Lee lo pendiente ahora y lo entrega cuando se abra la compuerta, como
    // una lectura del sistema que tarda.
    final result = [
      for (final id in pending) PendingNotificationRequest(id, 't', 'b', null),
    ];
    final gate = pendingGate;
    if (gate != null) await gate.future;
    return result;
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

  test('sin avisos pendientes no programa nada y no marca la pref', () async {
    // Otros avisos (no de la serie) no cuentan. Con avisos encendidos, nunca
    // se da por terminada con cero avisos programados.
    await setUpWith([]);
    plugin.pending.add(dailyNotificationId);

    await migrate();

    expect(plugin.scheduled, isEmpty);
    expect(plugin.pending, {dailyNotificationId});
    expect(prefs.getBool(reminderSeriesCopyV2Key), isNull);
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

  group('REM-01: ancla guardada y reemplazo por identificador', () {
    test(
      'si falla todo, conserva los avisos y reintenta con la misma ancla',
      () async {
        await setUpWith([3, 15]);
        plugin.failScheduling = true;

        await migrate();

        expect(prefs.getBool(reminderSeriesCopyV2Key), isNull);
        // Nada se canceló: los avisos viejos siguen pendientes.
        expect(plugin.pending, {
          reminderSeriesBaseId + 3,
          reminderSeriesBaseId + 15,
        });
        expect(prefs.getString(reminderSeriesMigrationAnchorKey), isNotNull);

        // Al día siguiente, antes de la hora guardada, ya se puede programar.
        plugin.failScheduling = false;
        await migrate(at: DateTime(2026, 1, 13, 6));

        expect(plugin.scheduled.first.id, reminderSeriesBaseId + 3);
        // Misma ancla que el primer intento: el aviso 3 sigue el 13 a las 7:30.
        expect(fields(plugin.scheduled.first.date), (2026, 1, 13, 7, 30));
        expect(plugin.scheduled.last.id, reminderSeriesBaseId + 15);
        expect(prefs.getBool(reminderSeriesCopyV2Key), isTrue);
        expect(prefs.getString(reminderSeriesMigrationAnchorKey), isNull);
        expect(prefs.getInt(reminderSeriesMigrationFromKey), isNull);
      },
    );

    test(
      'si falla el primero, no se convierte el siguiente en el inicio',
      () async {
        await setUpWith([3, 4, 5, 15]);
        plugin.failIds.add(reminderSeriesBaseId + 3);

        await migrate();

        expect(prefs.getBool(reminderSeriesCopyV2Key), isNull);
        // El 3 viejo sigue pendiente para el reintento.
        expect(plugin.pending, contains(reminderSeriesBaseId + 3));

        plugin.failIds.clear();
        plugin.scheduled.clear();
        await migrate(at: DateTime(2026, 1, 12, 20));

        expect(plugin.scheduled.first.id, reminderSeriesBaseId + 3);
        expect(fields(plugin.scheduled.first.date), (2026, 1, 13, 7, 30));
        expect(fields(plugin.scheduled[1].date), (2026, 1, 14, 7, 30));
        expect(prefs.getBool(reminderSeriesCopyV2Key), isTrue);
      },
    );

    test(
      'ancla guardada con todas sus fechas pasadas: no marca y la borra',
      () async {
        await setUpWith([3, 15]);
        plugin.failScheduling = true;
        await migrate();
        plugin.failScheduling = false;
        plugin.scheduled.clear();

        await migrate(at: DateTime(2026, 3, 30, 9));

        expect(plugin.scheduled, isEmpty);
        expect(prefs.getBool(reminderSeriesCopyV2Key), isNull);
        expect(prefs.getString(reminderSeriesMigrationAnchorKey), isNull);
      },
    );

    test('una serie completa programada termina la migración', () async {
      await setUpWith([3, 15]);
      await DailyRemindersScheduler(
        prefs: prefs,
        reminders: ReminderProvider(),
      ).scheduleSeriesFromAnchor(DateTime(2026, 1, 13, 7, 30), l10n: es);

      expect(plugin.scheduled, hasLength(16));
      expect(prefs.getBool(reminderSeriesCopyV2Key), isTrue);
      expect(prefs.getString(reminderSeriesMigrationAnchorKey), isNull);
    });

    test(
      'una serie completa con un fallo deja su ancla para reintentar',
      () async {
        await setUpWith([3, 15]);
        plugin.failIds.add(reminderSeriesBaseId + 2);
        await DailyRemindersScheduler(
          prefs: prefs,
          reminders: ReminderProvider(),
        ).scheduleSeriesFromAnchor(DateTime(2026, 1, 13, 7, 30), l10n: es);
        expect(prefs.getBool(reminderSeriesCopyV2Key), isNull);

        plugin.failIds.clear();
        plugin.scheduled.clear();
        await migrate();

        expect(plugin.scheduled, hasLength(16));
        expect(fields(plugin.scheduled.first.date), (2026, 1, 13, 7, 30));
        expect(prefs.getBool(reminderSeriesCopyV2Key), isTrue);
      },
    );
  });

  group('REM-02: un cambio a la vez', () {
    test('Ajustes apaga los avisos mientras la migración espera', () async {
      await setUpWith([3, 4, 15]);
      plugin.pendingGate = Completer<void>();

      final migration = migrate();
      await pumpEventQueue();
      final disable = DailyRemindersService(
        prefs: prefs,
        reminders: ReminderProvider(),
      ).disable();
      await pumpEventQueue();
      plugin.pendingGate!.complete();
      plugin.pendingGate = null;
      await Future.wait([migration, disable]);

      // Apagado gana: ningún aviso de la serie queda pendiente.
      expect(
        prefs.getBool(SharedPreferenceConstants.dailyReminderEnabled),
        isFalse,
      );
      expect(
        plugin.pending.where(
          (id) => id >= reminderSeriesBaseId && id <= reminderSeriesBaseId + 15,
        ),
        isEmpty,
      );
    });

    test('la migración en cola vuelve a leer las preferencias', () async {
      await setUpWith([3, 4, 15]);
      final service = DailyRemindersService(
        prefs: prefs,
        reminders: ReminderProvider(),
      );
      plugin.pendingGate = Completer<void>();
      // Otro cambio ocupa el turno; mientras, Ajustes apaga y la migración
      // queda en cola.
      final first = DailyRemindersScheduler(
        prefs: prefs,
        reminders: ReminderProvider(),
      ).migratePendingSeries(now: () => now, l10n: es);
      await pumpEventQueue();
      final off = service.disable();
      final second = migrate();
      plugin.pendingGate!.complete();
      plugin.pendingGate = null;
      await Future.wait([first, off, second]);

      expect(
        plugin.pending.where(
          (id) => id >= reminderSeriesBaseId && id <= reminderSeriesBaseId + 15,
        ),
        isEmpty,
      );
    });

    test(
      'tras una sesión no reprograma si los avisos están apagados',
      () async {
        await setUpWith([], enabled: false);

        await DailyRemindersScheduler(
          prefs: prefs,
          reminders: ReminderProvider(),
        ).rescheduleAfterSession(
          endMs: DateTime(2026, 1, 12, 8).millisecondsSinceEpoch,
          durationMs: 600000,
          l10n: es,
        );

        expect(plugin.scheduled, isEmpty);
      },
    );
  });

  group('REM-03: una sola regla de activación', () {
    test('sin interruptor guardado y con hora, la migración corre', () async {
      SharedPreferences.setMockInitialValues({
        SharedPreferenceConstants.savedHours: 7,
        SharedPreferenceConstants.savedMinutes: 30,
      });
      prefs = await SharedPreferences.getInstance();
      plugin = _FakePlugin([3, 15]);
      ReminderProvider.pluginFactory = () => plugin;

      expect(remindersActive(prefs), isTrue);
      await migrate();

      expect(plugin.scheduled.first.id, reminderSeriesBaseId + 3);
      expect(plugin.scheduled.first.title, es.reminderDay4Title);
      expect(prefs.getBool(reminderSeriesCopyV2Key), isTrue);
    });

    test(
      'sin interruptor guardado y con hora, se reprograma tras una sesión',
      () async {
        SharedPreferences.setMockInitialValues({
          SharedPreferenceConstants.savedHours: 7,
          SharedPreferenceConstants.savedMinutes: 30,
        });
        prefs = await SharedPreferences.getInstance();
        plugin = _FakePlugin([]);
        ReminderProvider.pluginFactory = () => plugin;

        await DailyRemindersScheduler(
          prefs: prefs,
          reminders: ReminderProvider(),
        ).rescheduleAfterSession(
          endMs: DateTime(2026, 1, 12, 8).millisecondsSinceEpoch,
          durationMs: 600000,
          l10n: es,
        );

        expect(plugin.scheduled, hasLength(16));
      },
    );

    test('la regla: el interruptor manda; sin él, cuenta la hora', () async {
      Future<bool> active(Map<String, Object> values) async {
        SharedPreferences.setMockInitialValues(values);
        return remindersActive(await SharedPreferences.getInstance());
      }

      expect(await active({}), isFalse);
      expect(
        await active({
          SharedPreferenceConstants.savedHours: 7,
          SharedPreferenceConstants.savedMinutes: 30,
        }),
        isTrue,
      );
      expect(
        await active({
          SharedPreferenceConstants.dailyReminderEnabled: false,
          SharedPreferenceConstants.savedHours: 7,
          SharedPreferenceConstants.savedMinutes: 30,
        }),
        isFalse,
      );
      expect(
        await active({SharedPreferenceConstants.dailyReminderEnabled: true}),
        isTrue,
      );
    });
  });
}
