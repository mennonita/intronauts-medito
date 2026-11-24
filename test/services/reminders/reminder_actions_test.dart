import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/app_globals.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_launch.dart';
import 'package:medito/providers/notification/reminder_provider.dart';
import 'package:medito/routes/routes.dart';
import 'package:medito/services/deep_link_service.dart';
import 'package:medito/services/reminders/daily_reminders_service.dart';
import 'package:medito/services/reminders/reminder_launch_action.dart';
import 'package:medito/utils/current_localizations.dart';
import 'package:medito/views/timer/timer_view.dart';
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

class _FakePlugin extends Fake implements FlutterLocalNotificationsPlugin {
  final initSettings = <InitializationSettings>[];
  final initCallbacks = <DidReceiveNotificationResponseCallback?>[];
  final scheduled = <_Scheduled>[];
  NotificationAppLaunchDetails? launchDetails;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    initSettings.add(settings);
    initCallbacks.add(onDidReceiveNotificationResponse);
    return true;
  }

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
    scheduled.add(_Scheduled(id, scheduledDate, title, notificationDetails));
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {}

  @override
  Future<List<PendingNotificationRequest>>
  pendingNotificationRequests() async => const [];

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async => launchDetails;
}

class _RouteObserver extends NavigatorObserver {
  MaterialPageRoute<bool>? lastPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is MaterialPageRoute<bool>) lastPush = route;
  }
}

NotificationResponse _response(String? actionId, {int id = 10102000}) =>
    NotificationResponse(
      notificationResponseType: actionId == null
          ? NotificationResponseType.selectedNotification
          : NotificationResponseType.selectedNotificationAction,
      id: id,
      actionId: actionId,
      payload: reminderPayload(1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();

  final es = lookupAppLocalizations(const Locale('es'));
  late _FakePlugin plugin;
  late List<({TimerLaunch launch, String source})> opened;

  setUp(() {
    ReminderProvider.resetForTesting();
    ReminderLaunchAction.resetForTesting();
    plugin = _FakePlugin();
    ReminderProvider.pluginFactory = () => plugin;
    ReminderProvider.timeZoneSetup = () async {};
    opened = [];
    ReminderLaunchAction.opener = (launch, {required source}) async {
      opened.add((launch: launch, source: source));
    };
  });

  tearDown(() {
    ReminderProvider.resetForTesting();
    ReminderLaunchAction.resetForTesting();
    tz.setLocalLocation(tz.UTC);
  });

  Future<List<_Scheduled>> scheduleSeries(DateTime anchor) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await DailyRemindersScheduler(
      prefs: prefs,
      reminders: ReminderProvider(),
    ).scheduleSeriesFromAnchor(anchor, l10n: es);
    return plugin.scheduled;
  }

  group('serie de avisos', () {
    test(
      'cada aviso lleva los dos botones traducidos y la categoría iOS',
      () async {
        tz.setLocalLocation(tz.getLocation('America/Mexico_City'));
        final items = await scheduleSeries(DateTime(2026, 1, 12, 7));

        expect(items.map((e) => e.id), [
          for (var i = 0; i < 16; i++) reminderSeriesBaseId + i,
        ]);
        for (final item in items) {
          final android = item.details.android!;
          expect(android.channelId, 'intronauts_reminders_channel');
          expect(android.channelName, 'Recordatorios');
          expect(android.icon, androidNotificationIcon);
          expect(android.importance, Importance.high);
          expect(android.playSound, isTrue);
          final actions = android.actions!;
          expect(actions.map((a) => a.id), [
            kReminderActionSit3,
            kReminderActionNotToday,
          ]);
          expect(actions.map((a) => a.title), [
            es.reminderActionSit3,
            es.reminderActionNotToday,
          ]);
          expect(actions[0].showsUserInterface, isTrue);
          expect(actions[1].showsUserInterface, isFalse);
          expect(actions.every((a) => a.cancelNotification), isTrue);
          expect(item.details.iOS!.categoryIdentifier, kReminderCategoryId);
        }
      },
    );

    test('el cambio de horario no mueve la hora del aviso', () async {
      // En Nueva York el horario de verano empieza el 8 de marzo de 2026.
      tz.setLocalLocation(tz.getLocation('America/New_York'));
      final items = await scheduleSeries(DateTime(2026, 3, 6, 7));

      for (final item in items) {
        expect((item.date.hour, item.date.minute), (7, 0));
      }
      expect(items.take(15).map((e) => (e.date.month, e.date.day)), [
        for (var d = 6; d <= 20; d++) (3, d),
      ]);
      expect((items.last.date.month, items.last.date.day), (4, 4));
      // Del 7 al 8 de marzo pasan 23 horas reales, no 24.
      expect(
        items[2].date.difference(items[1].date),
        const Duration(hours: 23),
      );

      // En noviembre el regreso al horario normal tampoco la mueve.
      plugin.scheduled.clear();
      final autumn = await scheduleSeries(DateTime(2026, 10, 30, 21, 15));
      for (final item in autumn) {
        expect((item.date.hour, item.date.minute), (21, 15));
      }
      expect(
        autumn[2].date.difference(autumn[1].date),
        const Duration(hours: 25),
      );
    });

    test('sin zona del teléfono usa la hora local del sistema', () async {
      tz.setLocalLocation(tz.UTC);
      final items = await scheduleSeries(DateTime(2026, 3, 6, 7));
      for (final item in items) {
        final local = DateTime.fromMillisecondsSinceEpoch(
          item.date.millisecondsSinceEpoch,
        );
        expect((local.hour, local.minute), (7, 0));
      }
    });
  });

  test('initialize registra los botones de iOS y el manejador', () async {
    await ReminderProvider.ensurePluginInitialized();

    expect(plugin.initSettings, hasLength(1));
    final categories = plugin.initSettings.single.iOS!.notificationCategories;
    final l10n = currentLocalizations();
    expect(categories.single.identifier, kReminderCategoryId);
    final actions = categories.single.actions;
    expect(actions.map((a) => a.identifier), [
      kReminderActionSit3,
      kReminderActionNotToday,
    ]);
    expect(actions.map((a) => a.title), [
      l10n.reminderActionSit3,
      l10n.reminderActionNotToday,
    ]);
    expect(actions[0].options, {DarwinNotificationActionOption.foreground});
    expect(actions[1].options, isEmpty);
    expect(plugin.initCallbacks.single, ReminderLaunchAction.handleResponse);

    // Una sola inicialización por proceso.
    ReminderProvider();
    await ReminderProvider.ensurePluginInitialized();
    expect(plugin.initSettings, hasLength(1));
  });

  group('respuesta en caliente', () {
    test('«Sentarme 3 min» abre 3 minutos con 10 s de preparación', () {
      ReminderLaunchAction.handleResponse(_response(kReminderActionSit3));

      expect(opened, hasLength(1));
      expect(opened.single.launch.minutes, 3);
      expect(opened.single.launch.minPrepSeconds, 10);
      expect(
        opened.single.source,
        AnalyticsEventConstants.sourceReminderAction,
      );
    });

    test('«Hoy no» no abre nada', () {
      final bodyTaps = <NotificationResponse>[];
      ReminderLaunchAction.bodyTapHandler = bodyTaps.add;

      ReminderLaunchAction.handleResponse(_response(kReminderActionNotToday));

      expect(opened, isEmpty);
      expect(bodyTaps, isEmpty);
    });

    test('tocar el cuerpo no navega; solo pasa al manejador de Firebase', () {
      ReminderLaunchAction.handleResponse(_response(null));
      expect(opened, isEmpty);

      final bodyTaps = <NotificationResponse>[];
      ReminderLaunchAction.bodyTapHandler = bodyTaps.add;
      final tap = _response(null);
      ReminderLaunchAction.handleResponse(tap);
      expect(opened, isEmpty);
      expect(bodyTaps, [tap]);
    });

    test('un toque en caliente antes del arranque evita el doble', () async {
      plugin.launchDetails = NotificationAppLaunchDetails(
        true,
        notificationResponse: _response(kReminderActionSit3),
      );
      ReminderLaunchAction.handleResponse(_response(kReminderActionSit3));

      expect(await ReminderLaunchAction.take(), isNull);
      expect(opened, hasLength(1));
    });
  });

  group('arranque en frío', () {
    test(
      'devuelve el temporizador una vez, sin inicializar Firebase',
      () async {
        final launchResponse = _response(kReminderActionSit3);
        plugin.launchDetails = NotificationAppLaunchDetails(
          true,
          notificationResponse: launchResponse,
        );
        var clock = DateTime(2026, 1, 12, 7);
        ReminderLaunchAction.now = () => clock;

        final launch = await ReminderLaunchAction.take();
        expect(launch?.minutes, 3);
        expect(launch?.minPrepSeconds, 10);
        expect(await ReminderLaunchAction.take(), isNull);
        // Solo el proveedor de avisos inicializó el plugin; Firebase nunca.
        expect(plugin.initCallbacks, [ReminderLaunchAction.handleResponse]);
        expect(ReminderLaunchAction.bodyTapHandler, isNull);

        // El mismo toque que ya abrió la app no abre otro temporizador.
        ReminderLaunchAction.handleResponse(launchResponse);
        expect(opened, isEmpty);

        // Un toque nuevo más tarde, en el mismo proceso, sí abre.
        clock = clock.add(const Duration(days: 1));
        ReminderLaunchAction.handleResponse(launchResponse);
        expect(opened, hasLength(1));
      },
    );

    test('otro arranque no devuelve nada', () async {
      for (final details in [
        null,
        const NotificationAppLaunchDetails(false),
        NotificationAppLaunchDetails(
          true,
          notificationResponse: _response(null),
        ),
        NotificationAppLaunchDetails(
          true,
          notificationResponse: _response(kReminderActionNotToday),
        ),
      ]) {
        ReminderLaunchAction.resetForTesting();
        plugin.launchDetails = details;
        expect(await ReminderLaunchAction.take(), isNull);
      }
    });
  });

  testWidgets('openTimerLaunch espera la app y abre TimerView', (tester) async {
    final previousReady = appReadyCompleter;
    appReadyCompleter = Completer<void>();
    addTearDown(() => appReadyCompleter = previousReady);
    final observer = _RouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [observer],
        home: const Scaffold(),
      ),
    );

    final open = DeepLinkService.openTimerLaunch(
      ReminderLaunchAction.sit3Launch,
      source: AnalyticsEventConstants.sourceReminderAction,
    );
    await tester.idle();
    expect(observer.lastPush, isNull);
    appReadyCompleter.complete();
    await tester.idle();

    final route = observer.lastPush!;
    final timer = route.builder(navigatorKey.currentContext!) as TimerView;
    expect(timer.source, AnalyticsEventConstants.sourceReminderAction);
    expect(timer.launch?.minutes, 3);
    expect(timer.launch?.minPrepSeconds, 10);
    navigatorKey.currentState!.removeRoute(route);
    await open;
  });
}
