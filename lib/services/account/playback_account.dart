import 'dart:io';

import 'package:flutter/services.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/services/timer/ios_timer_run_store.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:medito/utils/logger.dart';

class PlaybackAccount {
  static const _channel = MethodChannel('intronauts/playback_account');
  static String? _clientId;
  static String? _userId;
  static int _generation = 0;
  static int _discarding = 0;

  static int get generation => _generation;
  static bool isCurrent(int generation) =>
      generation == _generation && _discarding == 0;

  static Future<void> bind(String clientId, {String? userId}) async {
    final changed =
        _clientId != null &&
        (_clientId != clientId ||
            (userId != null && _userId != null && _userId != userId));
    if (changed) _userId = null;
    _clientId = clientId;
    _userId = userId ?? _userId;

    if (changed) {
      await _discard(
        () => Platform.isIOS
            ? iosAudioHandler.discardPlayback()
            : _bindAndroid(clientId, userId),
      );
    } else {
      await _bindAndroid(clientId, userId);
    }
  }

  static Future<void> _bindAndroid(String clientId, String? userId) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('bind', {
        'clientId': clientId,
        'userId': ?userId,
      });
    }
  }

  static Future<void> clear() {
    _clientId = null;
    _userId = null;
    return _discard(() async {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<void>('clear');
      } else if (Platform.isIOS) {
        await iosAudioHandler.discardPlayback();
      }
    });
  }

  static Future<void> _discard(Future<void> Function() stop) async {
    _generation++;
    _discarding++;
    try {
      await Future.wait([
        sessionBellPreview.stop().catchError((Object error) {
          AppLogger.w('BELLS', 'No se pudo detener la muestra: $error');
        }),
        Future.sync(stop),
        AudioSessionTracker.instance.discard(),
        // Después del cambio de generación: ninguna escritura vieja vuelve (R82).
        if (Platform.isIOS) IosTimerRunStore.instance.clear(),
      ]);
    } finally {
      _discarding--;
    }
  }
}
