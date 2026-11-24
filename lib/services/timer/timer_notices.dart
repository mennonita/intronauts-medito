import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:medito/scaffold_messenger_key.dart';
import 'package:medito/utils/logger.dart';

/// Avisos de pausa del temporizador en iOS (D2). En Android los publica el
/// servicio nativo.
class TimerNotices {
  static const pausedNotificationId = 7002;

  static final _plugin = FlutterLocalNotificationsPlugin();

  /// Muestra [text] como notificación y como aviso dentro de la app.
  static Future<void> showPaused(String text) async {
    if (!Platform.isIOS) return;
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(text)),
    );
    try {
      await _plugin.show(
        id: pausedNotificationId,
        body: text,
        notificationDetails: const NotificationDetails(
          iOS: DarwinNotificationDetails(presentSound: false),
        ),
      );
    } catch (error) {
      AppLogger.e('TIMER', 'No se pudo mostrar el aviso de pausa', error);
    }
  }
}
