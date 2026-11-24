import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/services/timer/ios_timer_run_store.dart';
import 'package:medito/services/timer/mantra_counter_store.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:medito/utils/health_sync_queue.dart';
import 'package:medito/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class PlaybackAccount {
  static const _channel = MethodChannel('intronauts/playback_account');
  static String? _clientId;
  static String? _userId;
  static int _generation = 0;
  static int _discarding = 0;
  // La última vinculación con el servicio nativo terminó bien y sigue vigente.
  static bool _bound = false;
  static Future<void>? _ensuring;
  // Sube con cada clear(): un ensureBound que empezó antes ya no vincula
  // nada al volver de una espera (TMR-05).
  static int _clearEpoch = 0;
  // Identidad que clear() retiró. Mientras la eliminación borra las
  // preferencias, ensureBound no la vuelve a tomar de ahí; solo un bind()
  // explícito la acepta otra vez.
  static String? _retiredClientId;

  /// Android: el servicio nativo guarda las colas y las sesiones por cuenta.
  /// Las pruebas lo activan para ver las llamadas al canal.
  @visibleForTesting
  static bool bindsNatively = Platform.isAndroid;

  static int get generation => _generation;
  static bool isCurrent(int generation) =>
      generation == _generation && _discarding == 0;

  /// Hay una cuenta (o la identidad local) vinculada y confirmada.
  static bool get isBound => _bound && _clientId != null;

  static Future<void> bind(String clientId, {String? userId}) async {
    _retiredClientId = null;
    final changed =
        _clientId != null &&
        (_clientId != clientId ||
            (userId != null && _userId != null && _userId != userId));
    if (changed) _userId = null;
    _clientId = clientId;
    _userId = userId ?? _userId;
    _bound = false;

    if (changed) {
      await _discard(
        () => Platform.isIOS
            ? iosAudioHandler.discardPlayback()
            : _bindAndroid(clientId, userId),
      );
    } else {
      await _bindAndroid(clientId, userId);
    }
    // Solo cuenta si nadie cambió la cuenta mientras se vinculaba.
    if (_clientId == clientId) _bound = true;
  }

  /// Vincula antes de abrir una sesión, venga de la ruta que venga (también
  /// de Descargas sin conexión o de un enlace antes del inicio normal): el
  /// servicio de Android rechaza un temporizador sin cuenta vinculada
  /// (TIMER-REVIEW-03).
  ///
  /// Usa la cuenta ya vinculada, o la identidad guardada en este equipo. Si
  /// aún no existe ninguna, crea y GUARDA una identidad local persistente: es
  /// la misma que el inicio de sesión anónimo reutiliza después, así que el
  /// historial sin dueño de esta instalación no se borra al iniciar sesión.
  ///
  /// Si la cuenta se borra ([clear]) mientras tanto, el intento se descarta
  /// con [StateError] y no vuelve a vincular la identidad anterior (TMR-05).
  static Future<void> ensureBound({SharedPreferences? prefs}) {
    if (isBound) return Future.value();
    final running = _ensuring;
    if (running != null) return running;
    late final Future<void> attempt;
    attempt = _ensureBound(prefs, _clearEpoch).whenComplete(() {
      // Un clear() ya pudo haber soltado este intento y empezado otro.
      if (identical(_ensuring, attempt)) _ensuring = null;
    });
    _ensuring = attempt;
    return attempt;
  }

  static Future<void> _ensureBound(SharedPreferences? prefs, int epoch) async {
    // Después de CADA espera: si se borró la cuenta, este intento ya no es
    // de nadie y no vincula nada.
    void checkEpoch() {
      if (epoch != _clearEpoch) {
        throw StateError('La cuenta se borró mientras se vinculaba');
      }
    }

    final store = prefs ?? await SharedPreferences.getInstance();
    checkEpoch();
    if (isBound) return;
    final current = _clientId;
    if (current != null) {
      // Una vinculación anterior no se confirmó: se repite con la misma cuenta.
      await bind(current, userId: _userId);
      checkEpoch();
      return;
    }
    var clientId = store.getString(SharedPreferenceConstants.userId);
    if (clientId != null && clientId == _retiredClientId) {
      // La eliminación aún no termina de borrar las preferencias.
      throw StateError('La identidad guardada es de la cuenta que se borró');
    }
    if (clientId == null) {
      clientId = newLocalClientId();
      if (!await store.setString(SharedPreferenceConstants.userId, clientId)) {
        throw StateError('No se pudo guardar la identidad local');
      }
      checkEpoch();
    }
    // Otra ruta pudo vincular mientras se leía: no se pisa su cuenta.
    if (_clientId != null) {
      if (!isBound) await bind(_clientId!, userId: _userId);
      checkEpoch();
      return;
    }
    await bind(clientId);
    checkEpoch();
  }

  /// Mismo formato que el identificador del inicio de sesión anónimo.
  @visibleForTesting
  static String newLocalClientId() =>
      '${DateFormat('yyyyMMddHHmmssSSS').format(DateTime.now())}-${const Uuid().v4()}';

  static Future<void> _bindAndroid(String clientId, String? userId) async {
    if (bindsNatively) {
      await _channel.invokeMethod<void>('bind', {
        'clientId': clientId,
        'userId': ?userId,
      });
    }
  }

  static Future<void> clear() {
    // Antes de soltar la identidad: ningún ensureBound en curso la vuelve a
    // vincular, y uno nuevo no se une al intento anterior (TMR-05).
    _clearEpoch++;
    _ensuring = null;
    _retiredClientId = _clientId ?? _retiredClientId;
    _clientId = null;
    _userId = null;
    _bound = false;
    return _discard(() async {
      if (bindsNatively) {
        await _channel.invokeMethod<void>('clear');
      } else if (Platform.isIOS) {
        await iosAudioHandler.discardPlayback();
      }
    });
  }

  @visibleForTesting
  static void resetForTesting() {
    _clientId = null;
    _userId = null;
    _bound = false;
    _ensuring = null;
    _retiredClientId = null;
    bindsNatively = Platform.isAndroid;
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
        // Los envíos a Salud de la cuenta anterior no salen (TIMER-01).
        HealthSyncQueue.invalidate(),
        // Las cuentas de mantras de la cuenta anterior se borran y ningún
        // guardado pendiente las vuelve a escribir (R89).
        MantraCounterStore.clearForAccountChange(),
      ]);
    } finally {
      _discarding--;
    }
  }
}
