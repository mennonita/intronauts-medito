import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:medito/services/reminders/reminder_launch_action.dart';
import 'package:medito/utils/current_localizations.dart';
import 'package:medito/utils/local_time_zone.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/services/analytics/crashlytics_service.dart';
import 'package:timezone/timezone.dart' as tz;

final reminderProvider = Provider<ReminderProvider>((ref) {
  return ReminderProvider();
});

/// Botón «Sentarme 3 min» del aviso diario.
const kReminderActionSit3 = 'reminder_sit3';

/// Botón «Hoy no» del aviso diario.
const kReminderActionNotToday = 'reminder_not_today';

/// Categoría de iOS que agrupa los dos botones del aviso diario.
const kReminderCategoryId = 'intronauts_reminder';

/// Categoría de iOS con los botones del aviso. El plugin es uno solo y el
/// último `initialize` reemplaza las categorías, así que todos los
/// `initialize` de la app deben pasar esta misma categoría.
DarwinNotificationCategory reminderNotificationCategory({
  required String sitLabel,
  required String notTodayLabel,
}) => DarwinNotificationCategory(
  kReminderCategoryId,
  actions: [
    DarwinNotificationAction.plain(
      kReminderActionSit3,
      sitLabel,
      options: const {DarwinNotificationActionOption.foreground},
    ),
    // Sin opción de primer plano: solo quita el aviso, no abre la app.
    DarwinNotificationAction.plain(kReminderActionNotToday, notTodayLabel),
  ],
);

/// La categoría con los textos del idioma actual del teléfono.
List<DarwinNotificationCategory> currentReminderCategories() {
  final l10n = currentLocalizations();
  return [
    reminderNotificationCategory(
      sitLabel: l10n.reminderActionSit3,
      notTodayLabel: l10n.reminderActionNotToday,
    ),
  ];
}

class ReminderProvider {
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin;
  late final Future<void> _initFuture;

  ReminderProvider() : _flutterLocalNotificationsPlugin = pluginFactory() {
    _initFuture = ensurePluginInitialized();
  }

  /// Plugin que usan los avisos; las pruebas lo cambian por uno falso.
  @visibleForTesting
  static FlutterLocalNotificationsPlugin Function() pluginFactory =
      FlutterLocalNotificationsPlugin.new;

  /// Prepara la zona horaria antes de programar; las pruebas la cambian.
  @visibleForTesting
  static Future<void> Function() timeZoneSetup = _defaultTimeZoneSetup;

  /// El plugin compartido de avisos locales.
  static FlutterLocalNotificationsPlugin get sharedPlugin => pluginFactory();

  static Future<void>? _pluginInit;

  /// Inicializa el plugin una sola vez por proceso. Corre en cada arranque
  /// (proveedor de avisos o decisión de inicio) y registra el manejador de
  /// los botones del aviso, aunque Firebase no se haya inicializado.
  static Future<void> ensurePluginInitialized() =>
      _pluginInit ??= _initializeNotifications(pluginFactory());

  @visibleForTesting
  static void resetForTesting() {
    _pluginInit = null;
    pluginFactory = FlutterLocalNotificationsPlugin.new;
    timeZoneSetup = _defaultTimeZoneSetup;
  }

  static Future<void> _defaultTimeZoneSetup() async {
    tz.initializeTimeZones();
    // Usa la zona horaria del teléfono; sin esto tz.local queda en UTC.
    await ensureLocalTimeZone();
  }

  static Future<void> _initializeNotifications(
    FlutterLocalNotificationsPlugin plugin,
  ) async {
    await timeZoneSetup();
    const initializationSettingsAndroid = AndroidInitializationSettings('logo');
    final initializationSettingsIOS = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: currentReminderCategories(),
    );
    final initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );
    // Si Firebase inicializa después, su manejador reenvía los botones aquí;
    // si inicializa antes, este manejador le pasa los toques al cuerpo.
    await plugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: ReminderLaunchAction.handleResponse,
    );
  }

  Future<void> clearBadge() async {
    await _initFuture;
    if (Platform.isIOS) {
      const iOSPlatformChannelSpecifics = DarwinNotificationDetails(
        badgeNumber: 0,
        presentAlert: false,
        presentBadge: false,
        presentSound: false,
      );
      await _flutterLocalNotificationsPlugin.show(
        id: 0,
        title: null,
        body: null,
        notificationDetails: const NotificationDetails(
          iOS: iOSPlatformChannelSpecifics,
        ),
      );
    }
  }

  Future<void> cancelDailyNotification() async {
    await _initFuture;
    try {
      await _flutterLocalNotificationsPlugin.cancel(id: dailyNotificationId);
      AppLogger.d(
        'REMINDER',
        'Cancelled daily notification (id: $dailyNotificationId)',
      );
    } catch (e, s) {
      AppLogger.e('REMINDER', 'Error cancelling daily notification: $e', s);
      CrashlyticsService().recordError(
        e,
        s,
        reason: 'Failed to cancel daily notification',
      );
    }
    try {
      await clearBadge();
    } catch (e, s) {
      AppLogger.e(
        'REMINDER',
        'Error clearing badge after cancelling daily notification: $e',
        s,
      );
    }
  }

  /// Programa cada aviso sobre su identificador (reemplaza al que había).
  /// Devuelve los identificadores que no se pudieron programar; esos
  /// conservan el aviso anterior.
  Future<Set<int>> scheduleReminderSeries(List<ScheduledReminder> items) async {
    await _initFuture;
    final failed = <int>{};
    AppLogger.d(
      'XXXX',
      'scheduleReminderSeries called with ${items.length} items',
    );
    try {
      for (final item in items) {
        try {
          final payload = item.payload;
          AppLogger.d(
            'REMINDER',
            'Scheduling reminder ${item.id} with payload: $payload',
          );
          AppLogger.d(
            'XXXX',
            'Scheduling reminder ID=${item.id}, scheduledDate=${item.scheduledDate}, payload=$payload, title=${item.title}',
          );
          await _flutterLocalNotificationsPlugin.zonedSchedule(
            id: item.id,
            title: item.title,
            body: item.body,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            scheduledDate: item.scheduledDate,
            notificationDetails: reminderNotificationDetails(item),
            // Was omitted entirely: the payload was built and logged but never
            // attached, so every tap arrived with null and the handler's
            // null-guard skipped navigation and analytics alike.
            payload: payload,
          );
          AppLogger.d(
            'XXXX',
            'Successfully scheduled reminder ID=${item.id} at ${item.scheduledDate}',
          );
        } catch (e, s) {
          failed.add(item.id);
          AppLogger.e(
            'REMINDER',
            'Error scheduling reminder ${item.id} at ${item.scheduledDate}: $e',
            s,
          );
          AppLogger.e(
            'XXXX',
            'Error scheduling reminder ID=${item.id} at ${item.scheduledDate}: $e',
          );
          CrashlyticsService().recordError(
            e,
            s,
            reason:
                'Failed to schedule daily reminder ${item.id} at ${item.scheduledDate}',
          );
        }
      }
      AppLogger.d(
        'XXXX',
        'Finished scheduling ${items.length} reminders, checking pending notifications...',
      );
      final pending = await getPendingNotifications();
      AppLogger.d(
        'XXXX',
        'Pending notifications after scheduling: ${pending.length} found',
      );
      for (final notification in pending) {
        AppLogger.d(
          'XXXX',
          'Pending notification: ID=${notification.id}, payload=${notification.payload}',
        );
      }
      return failed;
    } catch (e, s) {
      AppLogger.e('REMINDER', 'Error scheduling daily reminder series: $e', s);
      AppLogger.e('XXXX', 'Error scheduling daily reminder series: $e');
      CrashlyticsService().recordError(
        e,
        s,
        reason:
            'Failed to schedule daily reminder series (${items.length} items)',
      );
      rethrow;
    }
  }

  Future<void> cancelReminderSeries() async {
    await _initFuture;
    try {
      var cancelledCount = 0;
      for (var i = 0; i < reminderSeriesCount; i++) {
        try {
          await _flutterLocalNotificationsPlugin.cancel(
            id: reminderSeriesBaseId + i,
          );
          cancelledCount++;
        } catch (e, s) {
          AppLogger.e(
            'REMINDER',
            'Error cancelling daily reminder ${reminderSeriesBaseId + i}: $e',
            s,
          );
          CrashlyticsService().recordError(
            e,
            s,
            reason:
                'Failed to cancel daily reminder ${reminderSeriesBaseId + i}',
          );
        }
      }
      try {
        await _flutterLocalNotificationsPlugin.cancel(
          id: reminderSeriesBaseId + 15,
        );
        cancelledCount++;
      } catch (e, s) {
        AppLogger.e(
          'REMINDER',
          'Error cancelling day 30 reminder ${reminderSeriesBaseId + 15}: $e',
          s,
        );
      }
      AppLogger.d(
        'REMINDER',
        'Cancelled $cancelledCount daily reminders (including day 30)',
      );
    } catch (e, s) {
      AppLogger.e('REMINDER', 'Error cancelling daily reminder series: $e', s);
      CrashlyticsService().recordError(
        e,
        s,
        reason: 'Failed to cancel daily reminder series',
      );
    }
    try {
      await clearBadge();
    } catch (e, s) {
      AppLogger.e(
        'REMINDER',
        'Error clearing badge after cancelling daily reminders: $e',
        s,
      );
    }
  }

  /// Con [rethrowErrors] el error sale al que llama en vez de volver vacío,
  /// para no confundir «no hay avisos» con «no se pudieron leer».
  Future<List<PendingNotificationRequest>> getPendingNotifications({
    bool rethrowErrors = false,
  }) async {
    await _initFuture;
    AppLogger.d('REMINDER', 'Getting pending notifications...');
    try {
      final pendingNotifications = await _flutterLocalNotificationsPlugin
          .pendingNotificationRequests();
      AppLogger.d(
        'REMINDER',
        'Found ${pendingNotifications.length} pending notification(s)',
      );
      for (final notification in pendingNotifications) {
        AppLogger.d(
          'REMINDER',
          'Notification ID: ${notification.id}, Title: ${notification.title}, Body: ${notification.body}, Payload: ${notification.payload}',
        );
      }
      return pendingNotifications;
    } catch (e, s) {
      AppLogger.e('REMINDER', 'Error getting pending notifications: $e', s);
      CrashlyticsService().recordError(
        e,
        s,
        reason: 'Failed to get pending notifications',
      );
      if (rethrowErrors) rethrow;
      return [];
    }
  }
}

const androidNotificationChannelId = 'medito_reminder_channel';
const androidNotificationChannelName = 'Reminders';
const androidNotificationIcon = 'logo';
const androidNotificationChannelDescription =
    'Notification for meditation reminders';
const dailyNotificationId = 10101024;

const reminderSeriesBaseId = 10102000;
const reminderSeriesCount = 15;

/// Detalles de cada aviso de la serie: mismo canal, importancia e ícono de
/// siempre, más los botones «Sentarme 3 min» y «Hoy no».
NotificationDetails reminderNotificationDetails(ScheduledReminder item) =>
    NotificationDetails(
      android: AndroidNotificationDetails(
        androidNotificationChannelId,
        androidNotificationChannelName,
        channelDescription: androidNotificationChannelDescription,
        icon: androidNotificationIcon,
        importance: Importance.max,
        priority: Priority.high,
        actions: [
          AndroidNotificationAction(
            kReminderActionSit3,
            item.sitLabel,
            showsUserInterface: true,
            cancelNotification: true,
          ),
          // Sin interfaz: Android quita el aviso y no abre la app.
          AndroidNotificationAction(
            kReminderActionNotToday,
            item.notTodayLabel,
            cancelNotification: true,
          ),
        ],
      ),
      iOS: const DarwinNotificationDetails(
        categoryIdentifier: kReminderCategoryId,
      ),
    );

class ScheduledReminder {
  final int id;
  final tz.TZDateTime scheduledDate;
  final String title;
  final String body;

  /// JSON handed back to the tap handler so the open can be attributed.
  /// Must be valid JSON: the handler decodes it.
  final String payload;

  /// Textos de los botones, en el idioma actual del teléfono.
  final String sitLabel;
  final String notTodayLabel;

  ScheduledReminder({
    required this.id,
    required this.scheduledDate,
    required this.title,
    required this.body,
    required this.payload,
    required this.sitLabel,
    required this.notTodayLabel,
  });
}
