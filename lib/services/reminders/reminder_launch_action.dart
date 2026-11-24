import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/models/timer/timer_launch.dart';
import 'package:medito/providers/notification/reminder_provider.dart';
import 'package:medito/services/deep_link_service.dart';
import 'package:medito/services/reminders/daily_reminders_service.dart';
import 'package:medito/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Botones del aviso diario: «Sentarme 3 min» abre el temporizador listo y
/// «Hoy no» solo quita el aviso. Cada toque se atiende una sola vez.
class ReminderLaunchAction {
  /// Lo que abre «Sentarme 3 min»: 3 minutos y al menos 10 s de preparación.
  static const sit3Launch = TimerLaunch(minutes: 3, minPrepSeconds: 10);

  // Un toque repetido dentro de este margen es el mismo que abrió la app.
  static const _duplicateWindow = Duration(minutes: 1);

  /// Toques en el cuerpo del aviso. Lo pone el servicio de Firebase cuando
  /// se inicializa, para no perder su comportamiento si este manejador quedó
  /// registrado al final. Sin él, tocar el cuerpo solo abre la app.
  static void Function(NotificationResponse response)? bodyTapHandler;

  /// Abre el temporizador; las pruebas lo cambian.
  @visibleForTesting
  static Future<void> Function(TimerLaunch launch, {required String source})
  opener = DeepLinkService.openTimerLaunch;

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static bool _launchDetailsRead = false;
  static bool _warmSitHandled = false;
  static String? _launchKey;
  static DateTime? _launchTakenAt;

  /// Respuesta a un aviso con la app viva (o recién traída al frente).
  static void handleResponse(NotificationResponse response) {
    final actionId = response.actionId;
    if (actionId == null || actionId.isEmpty) {
      bodyTapHandler?.call(response);
      return;
    }
    if (actionId != kReminderActionSit3) {
      // «Hoy no» y cualquier otro botón: no se abre nada.
      return;
    }

    final takenAt = _launchTakenAt;
    if (_launchKey == _keyOf(response) &&
        takenAt != null &&
        now().difference(takenAt) < _duplicateWindow) {
      AppLogger.d('REMINDER', 'Ignoring reminder action already taken');
      return;
    }
    // Si la decisión de inicio todavía no lee el arranque, ya no debe
    // abrir otro temporizador por el mismo toque.
    _warmSitHandled = true;
    unawaited(
      opener(sit3Launch, source: AnalyticsEventConstants.sourceReminderAction),
    );
  }

  /// Arranque en frío: la app se abrió con «Sentarme 3 min». Devuelve el
  /// temporizador a abrir una sola vez por proceso; si no, null.
  static Future<TimerLaunch?> take() async {
    if (_launchDetailsRead) return null;
    _launchDetailsRead = true;
    if (_warmSitHandled) return null;
    try {
      await ReminderProvider.ensurePluginInitialized();
      final details = await ReminderProvider.sharedPlugin
          .getNotificationAppLaunchDetails();
      final response = details?.notificationResponse;
      if (details?.didNotificationLaunchApp != true ||
          response?.actionId != kReminderActionSit3) {
        return null;
      }
      // Un toque en caliente pudo llegar mientras se leía el arranque.
      if (_warmSitHandled) return null;
      _launchKey = _keyOf(response!);
      _launchTakenAt = now();
      return sit3Launch;
    } catch (e, s) {
      AppLogger.e('REMINDER', 'Error reading reminder launch action: $e', s);
      return null;
    }
  }

  static String _keyOf(NotificationResponse response) =>
      '${response.id}|${response.actionId}|${response.payload}';

  @visibleForTesting
  static void resetForTesting() {
    bodyTapHandler = null;
    opener = DeepLinkService.openTimerLaunch;
    now = DateTime.now;
    _launchDetailsRead = false;
    _warmSitHandled = false;
    _launchKey = null;
    _launchTakenAt = null;
  }
}

/// Reprograma una vez los avisos pendientes de una versión anterior, para
/// que muestren los textos y botones nuevos a la misma hora.
class ReminderSeriesMigration {
  static Future<void>? _running;

  static Future<void> runOnce() => _running ??= _run();

  static Future<void> _run() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await DailyRemindersScheduler(
        prefs: prefs,
        reminders: ReminderProvider(),
      ).migratePendingSeries();
    } catch (e, s) {
      AppLogger.e('REMINDER', 'Error migrating pending reminders: $e', s);
    }
  }

  @visibleForTesting
  static void resetForTesting() => _running = null;
}
