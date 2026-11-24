import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:medito/utils/current_localizations.dart';
import 'package:medito/utils/logger.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Programa y cancela el aviso de respaldo del final (solo iOS; Android lo
/// hace el servicio nativo).
abstract class TimerEndBackupScheduler {
  Future<void> schedule({
    required int id,
    required tz.TZDateTime at,
    required String title,
    required String body,
    required bool sound,
  });

  Future<void> cancel(int id);
}

class _LocalNotificationsScheduler implements TimerEndBackupScheduler {
  // La app ya inicializa el complemento al abrir (avisos y recordatorios);
  // volver a inicializarlo aquí borraría sus respuestas a los toques.
  final _plugin = FlutterLocalNotificationsPlugin();

  @override
  Future<void> schedule({
    required int id,
    required tz.TZDateTime at,
    required String title,
    required String body,
    required bool sound,
  }) => _plugin.zonedSchedule(
    id: id,
    title: title,
    body: body,
    scheduledDate: at,
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    notificationDetails: NotificationDetails(
      iOS: DarwinNotificationDetails(presentSound: sound),
    ),
  );

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
}

/// Aviso «Terminó tu meditación» por si el audio se detuvo antes del final.
/// Es un aviso único en un instante absoluto, así que la zona local no
/// importa.
class TimerEndBackup {
  TimerEndBackup({
    TimerEndBackupScheduler? scheduler,
    tz.TZDateTime Function()? now,
  }) : _scheduler = scheduler ?? _LocalNotificationsScheduler(),
       _now = now;

  static TimerEndBackup instance = TimerEndBackup();

  static const notificationId = 7001;
  static const _margin = Duration(seconds: 10);

  final TimerEndBackupScheduler _scheduler;
  final tz.TZDateTime Function()? _now;

  @visibleForTesting
  static void ensureTimeZones() {
    if (!tz.timeZoneDatabase.isInitialized) tzdata.initializeTimeZones();
  }

  /// Programa el aviso [remaining] + 10 s después de ahora. [output] es la
  /// salida de las campanas: con «vibration» el aviso no suena.
  Future<void> schedule({
    required Duration remaining,
    required int minutes,
    required String output,
  }) async {
    try {
      ensureTimeZones();
      final now = _now?.call() ?? tz.TZDateTime.now(tz.local);
      final l10n = currentLocalizations();
      await _scheduler.schedule(
        id: notificationId,
        at: now.add(remaining + _margin),
        title: l10n.timerEndBackupTitle,
        body: l10n.timerEndBackupBody(minutes),
        sound: output != 'vibration',
      );
    } catch (error) {
      AppLogger.e('TIMER', 'No se pudo programar el aviso de respaldo', error);
    }
  }

  Future<void> cancel() async {
    try {
      await _scheduler.cancel(notificationId);
    } catch (error) {
      AppLogger.e('TIMER', 'No se pudo cancelar el aviso de respaldo', error);
    }
  }
}
