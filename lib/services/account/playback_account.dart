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
  // Identidades que clear() o la eliminación retiraron. Mientras siguen
  // guardadas en las preferencias, ensureBound no las vuelve a tomar de ahí;
  // solo un bind() explícito las acepta otra vez.
  static final Set<String> _retiredClientIds = {};
  // Limpiezas locales en curso (eliminación de la cuenta): ensureBound no
  // vincula nada hasta que terminen (REV-06).
  static int _wipes = 0;

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
    // Durante una eliminación, la identidad borrada sigue retirada.
    if (_wipes == 0) _retiredClientIds.clear();
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
  /// Durante toda la limpieza de una eliminación ([holdForWipe]) también
  /// falla con [StateError], aunque nada se haya vinculado antes (REV-06).
  static Future<void> ensureBound({SharedPreferences? prefs}) {
    if (_wipes > 0) {
      return Future.error(
        StateError('La cuenta se está borrando; aún no se vincula nada'),
      );
    }
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
      if (epoch != _clearEpoch || _wipes > 0) {
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
    if (clientId != null && _retiredClientIds.contains(clientId)) {
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

  /// Bloquea [ensureBound] durante TODA la limpieza local de una eliminación,
  /// también al reanudarla antes de la primera vinculación, cuando no hay
  /// ninguna identidad cargada (REV-06). Se llama antes de la primera espera
  /// de la limpieza, con la identidad guardada en las preferencias.
  ///
  /// Lo que devuelve se llama al terminar, haya salido bien o no. Aun así,
  /// mientras [persistedClientId] siga guardada no se vuelve a vincular: solo
  /// cuando se confirma que se quitó de las preferencias.
  static void Function() holdForWipe(String? persistedClientId) {
    _wipes++;
    _clearEpoch++;
    _ensuring = null;
    if (persistedClientId != null) _retiredClientIds.add(persistedClientId);
    var released = false;
    return () {
      if (released) return;
      released = true;
      _wipes--;
    };
  }

  static Future<void> clear() {
    // Antes de soltar la identidad: ningún ensureBound en curso la vuelve a
    // vincular, y uno nuevo no se une al intento anterior (TMR-05).
    _clearEpoch++;
    _ensuring = null;
    final retired = _clientId;
    if (retired != null) _retiredClientIds.add(retired);
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
    _retiredClientIds.clear();
    _wipes = 0;
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
