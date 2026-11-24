import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/strings/shared_preference_constants.dart';
import 'health_kit_manager.dart';
import 'logger.dart';
import 'stats_manager.dart';

class HealthSyncEntry {
  const HealthSyncEntry({
    required this.key,
    required this.startMs,
    required this.endMs,
    required this.accountId,
    this.attempting = false,
    this.awaitingConsent = false,
  });

  final String key;
  final int startMs;
  final int endMs;
  final String accountId;

  /// iOS: se guardó `true` justo antes de escribir. Si se encuentra así en el
  /// siguiente envío, la escritura pudo haber llegado, así que se descarta.
  final bool attempting;

  /// Sesión que espera el «Activar» de la persona; nunca se escribe mientras
  /// siga en `true`.
  final bool awaitingConsent;

  HealthSyncEntry copyWith({bool? attempting, bool? awaitingConsent}) =>
      HealthSyncEntry(
        key: key,
        startMs: startMs,
        endMs: endMs,
        accountId: accountId,
        attempting: attempting ?? this.attempting,
        awaitingConsent: awaitingConsent ?? this.awaitingConsent,
      );

  Map<String, dynamic> toJson() => {
    'key': key,
    'startMs': startMs,
    'endMs': endMs,
    'accountId': accountId,
    'attempting': attempting,
    'awaitingConsent': awaitingConsent,
  };

  factory HealthSyncEntry.fromJson(Map<String, dynamic> json) =>
      HealthSyncEntry(
        key: json['key'] as String,
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        accountId: json['accountId'] as String,
        attempting: json['attempting'] as bool? ?? false,
        awaitingConsent: json['awaitingConsent'] as bool? ?? false,
      );
}

/// Escritura en Salud. [stillAllowed] dice si la entrada sigue siendo de la
/// cuenta actual, con su permiso y en la misma generación de la cola; quien
/// escribe lo revisa después de cada espera y justo antes de enviar (TMR-01).
typedef HealthWrite =
    Future<bool> Function(HealthSyncEntry entry, bool Function() stillAllowed);

/// Suelta una pausa de [HealthSyncQueue.holdForAccountChange]. Llamarla más
/// de una vez no hace nada.
typedef HealthSyncRelease = void Function();

/// Lo que la cola necesita del resto de la app. Las pruebas lo reemplazan.
class HealthSyncDependencies {
  HealthSyncDependencies({
    Future<SharedPreferences> Function()? prefs,
    Future<void> Function()? ready,
    String Function(SharedPreferences prefs)? currentAccountId,
    bool? isIOS,
    // Escritura que no revisa nada por su cuenta (pruebas). La cola igual
    // revisa justo antes de llamarla.
    Future<bool> Function(HealthSyncEntry entry)? write,
    HealthWrite? guardedWrite,
    void Function()? invalidateWrites,
    Future<void> Function(int endMs)? markSynced,
    Future<bool> Function()? healthAvailable,
    Future<List<HealthPendingRun>> Function()? pendingRuns,
    Future<bool> Function(String runId)? clearPending,
    Future<bool> Function(SharedPreferences prefs, String? raw)? persist,
    bool Function(SharedPreferences prefs)? accountChanging,
  }) : prefs = prefs ?? SharedPreferences.getInstance,
       ready = ready ?? _statsReady,
       currentAccountId = currentAccountId ?? _verifiedAccountId,
       isIOS = isIOS ?? Platform.isIOS,
       write =
           guardedWrite ??
           (write == null ? _writeToHealth : (entry, _) => write(entry)),
       invalidateWrites =
           invalidateWrites ??
           (() => HealthKitManager().invalidatePendingWrites()),
       markSynced =
           markSynced ??
           ((endMs) => HealthKitManager().markSessionAsSynced(endMs)),
       healthAvailable =
           healthAvailable ??
           (() => HealthKitManager().isHealthConnectAvailable()),
       pendingRuns = pendingRuns ?? _statsPendingRuns,
       clearPending =
           clearPending ??
           ((runId) => StatsManager().clearHealthPending(runId)),
       persist = persist ?? _persist,
       accountChanging =
           accountChanging ??
           _sessionClosedFor(currentAccountId ?? _verifiedAccountId);

  final Future<SharedPreferences> Function() prefs;

  /// Espera a que el historial esté cargado (cuenta verificada y marcas).
  final Future<void> Function() ready;

  /// Cuenta dueña de las sesiones: la cuenta verificada del historial, o `''`
  /// sin verificar. Es el mismo id que las sesiones del temporizador llevan
  /// como dueño (`ownerId`).
  final String Function(SharedPreferences prefs) currentAccountId;
  final bool isIOS;
  final HealthWrite write;

  /// Suelta las escrituras que esperan en el puente nativo de Salud.
  final void Function() invalidateWrites;
  final Future<void> Function(int endMs) markSynced;
  final Future<bool> Function() healthAvailable;
  final Future<List<HealthPendingRun>> Function() pendingRuns;
  final Future<bool> Function(String runId) clearPending;

  /// Guarda la lista ya codificada (`null` = sin entradas). Devuelve `false`
  /// si el guardado no se confirmó.
  final Future<bool> Function(SharedPreferences prefs, String? raw) persist;

  /// La cuenta está cambiando aunque nadie haya pausado la cola: la sesión ya
  /// se cerró (cierre de sesión, sesión vencida o eliminación), pero el
  /// historial todavía es de la cuenta anterior. Nada sale a Salud hasta que
  /// la nueva identidad quede asentada (REV-02).
  final bool Function(SharedPreferences prefs) accountChanging;

  static bool Function(SharedPreferences prefs) _sessionClosedFor(
    String Function(SharedPreferences prefs) account,
  ) =>
      (prefs) =>
          prefs.getBool(SharedPreferenceConstants.isLoggedIn) == false &&
          account(prefs).isNotEmpty;

  static Future<bool> _persist(SharedPreferences prefs, String? raw) {
    if (raw == null) {
      return prefs.remove(SharedPreferenceConstants.pendingHealthSessions);
    }
    return prefs.setString(
      SharedPreferenceConstants.pendingHealthSessions,
      raw,
    );
  }

  static Future<void> _statsReady() async {
    try {
      await StatsManager().initialize();
    } catch (error) {
      AppLogger.e('HEALTH_SYNC', 'No se pudo abrir el historial', error);
    }
  }

  static String _verifiedAccountId(SharedPreferences prefs) {
    final stats = StatsManager();
    if (stats.isInitialized) return stats.verifiedUserId ?? '';
    return prefs.getString(SharedPreferenceConstants.serverUserId) ?? '';
  }

  static Future<List<HealthPendingRun>> _statsPendingRuns() async {
    final stats = StatsManager();
    if (!stats.isInitialized) return const [];
    return stats.healthPendingRuns();
  }

  static Future<bool> _writeToHealth(
    HealthSyncEntry entry,
    bool Function() stillAllowed,
  ) {
    return HealthKitManager().writeMindfulnessData(
      DateTime.fromMillisecondsSinceEpoch(entry.startMs),
      DateTime.fromMillisecondsSinceEpoch(entry.endMs),
      clientRecordId: entry.key,
      stillAllowed: stillAllowed,
    );
  }
}

/// Cola de sesiones por escribir en Salud (Apple Salud / Health Connect).
///
/// Es el único camino de escritura: nada escribe directo. Solo escribe con el
/// permiso guardado de la cuenta actual, nunca pide permiso y reintenta lo
/// que falló en el siguiente envío sin duplicar.
class HealthSyncQueue {
  static const int maxEntries = 50;
  static const _tag = 'HEALTH_SYNC';

  static HealthSyncDependencies? _deps;
  static HealthSyncDependencies get _d => _deps ??= HealthSyncDependencies();

  @visibleForTesting
  static set dependencies(HealthSyncDependencies? value) => _deps = value;

  @visibleForTesting
  static void resetForTesting() {
    _deps = null;
    _flushing = null;
    _again = false;
    _lockTail = null;
    _generation = 0;
    _accountHolds = 0;
    _flushHeld = false;
  }

  // Sube con cada cambio de cuenta, eliminación o Salud apagada. Un envío que
  // empezó con otra generación ya no escribe ni guarda nada.
  static int _generation = 0;

  // También suelta la escritura que espera en el puente nativo (TMR-01).
  static void _bumpGeneration() {
    _generation++;
    try {
      _d.invalidateWrites();
    } catch (error) {
      AppLogger.e(_tag, 'No se pudo soltar la escritura pendiente', error);
    }
  }

  // Pausas activas por cambio de cuenta (cierre de sesión, eliminación).
  static int _accountHolds = 0;
  // Se pidió un envío durante la pausa: sale al soltarla.
  static bool _flushHeld = false;

  /// Detiene los envíos a Salud al EMPEZAR un cambio de cuenta (cierre de
  /// sesión, eliminación): suelta la escritura en curso y ningún envío nuevo
  /// sale hasta llamar a lo que devuelve, cuando la nueva identidad ya quedó
  /// asentada (REV-02). Todo pasa antes de la primera espera de quien llama.
  static HealthSyncRelease holdForAccountChange() {
    _accountHolds++;
    _bumpGeneration();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _accountHolds--;
      if (_accountHolds == 0 && _flushHeld) {
        _flushHeld = false;
        unawaited(flush());
      }
    };
  }

  /// Ningún envío ni guardado de la cuenta anterior mientras cambia la cuenta.
  static bool _accountChanging(SharedPreferences prefs) =>
      _accountHolds > 0 || _d.accountChanging(prefs);

  /// Invalida los envíos pendientes y vacía la cola bajo su propio bloqueo.
  /// Se llama al cambiar de cuenta o eliminarla: un envío en curso no manda
  /// la siguiente sesión ni vuelve a guardar la lista.
  static Future<void> invalidate() {
    _bumpGeneration();
    return _locked(() async {
      final prefs = await _d.prefs();
      if (!await _save(prefs, const [])) {
        AppLogger.w(_tag, 'No se pudo vaciar la cola de Salud');
      }
    });
  }

  // Un solo cambio a la vez sobre la lista guardada. Sin nada pendiente la
  // cadena vuelve a null, para no encadenarse a un futuro viejo.
  static Future<void>? _lockTail;

  static Future<T> _locked<T>(Future<T> Function() body) {
    final previous = _lockTail;
    final result = previous == null ? body() : previous.then((_) => body());
    final tail = result.then<void>((_) {}, onError: (_) {});
    _lockTail = tail;
    tail.whenComplete(() {
      if (identical(_lockTail, tail)) _lockTail = null;
    });
    return result;
  }

  /// Permiso explícito y guardado de la cuenta actual.
  static bool hasConsent(SharedPreferences prefs) {
    if (prefs.getBool(SharedPreferenceConstants.healthSyncEnabled) != true) {
      return false;
    }
    final consentAccount = prefs.getString(
      SharedPreferenceConstants.healthSyncAccountId,
    );
    return consentAccount != null &&
        consentAccount == _d.currentAccountId(prefs);
  }

  /// Guarda o quita el permiso. Al activarlo, la sesión que esperaba el
  /// permiso se libera y se envía; al quitarlo, se vacía la cola.
  static Future<void> setConsent(bool on) async {
    // Antes de cualquier espera: el envío en curso se detiene ya, no al
    // terminar toda la cola.
    if (!on) _bumpGeneration();
    await _d.ready();
    final prefs = await _d.prefs();
    if (!on) {
      await _locked(() async {
        await prefs.setBool(SharedPreferenceConstants.healthSyncEnabled, false);
        await prefs.remove(SharedPreferenceConstants.healthSyncAccountId);
        await _save(prefs, const []);
      });
      return;
    }
    final account = _d.currentAccountId(prefs);
    await _locked(() async {
      await prefs.setBool(SharedPreferenceConstants.healthSyncEnabled, true);
      await prefs.setString(
        SharedPreferenceConstants.healthSyncAccountId,
        account,
      );
      final entries = _read(prefs);
      if (entries.any((e) => e.awaitingConsent && e.accountId == account)) {
        await _save(prefs, [
          for (final e in entries)
            e.awaitingConsent && e.accountId == account
                ? e.copyWith(awaitingConsent: false)
                : e,
        ]);
      }
    });
    await flush();
  }

  /// «Ahora no»: quita la sesión que esperaba el permiso.
  static Future<void> dropAwaitingConsent() async {
    final prefs = await _d.prefs();
    await _locked(() async {
      final entries = _read(prefs);
      if (!entries.any((e) => e.awaitingConsent)) return;
      await _save(prefs, [
        for (final e in entries)
          if (!e.awaitingConsent) e,
      ]);
    });
  }

  /// Agrega una sesión. Una clave repetida no se agrega dos veces. Solo
  /// queda una sesión esperando el permiso: la más nueva reemplaza a la otra.
  /// Con más de [maxEntries], se quitan las más viejas.
  ///
  /// Devuelve `true` solo si la entrada quedó guardada en la cola. Si el
  /// guardado falla, la lista vuelve a como estaba y devuelve `false`.
  static Future<bool> add(HealthSyncEntry entry) async {
    final prefs = await _d.prefs();
    return _locked(() async {
      final entries = _read(prefs);
      final index = entries.indexWhere((e) => e.key == entry.key);
      if (index >= 0) {
        final existing = entries[index];
        if (existing.awaitingConsent && !entry.awaitingConsent) {
          entries[index] = existing.copyWith(awaitingConsent: false);
          return _save(prefs, entries);
        }
        return true;
      }
      if (entry.awaitingConsent) {
        entries.removeWhere((e) => e.awaitingConsent);
      }
      entries.add(entry);
      while (entries.length > maxEntries) {
        entries.removeAt(0);
      }
      return _save(prefs, entries);
    });
  }

  /// Agrega una sesión guiada si la cuenta actual dio permiso. Devuelve
  /// `true` si quedó en la cola.
  static Future<bool> addConsentedSession({
    required String key,
    required int startMs,
    required int endMs,
  }) async {
    await _d.ready();
    final prefs = await _d.prefs();
    // A mitad de un cambio de cuenta la sesión ya no es de nadie.
    if (_accountChanging(prefs) || !hasConsent(prefs)) return false;
    return add(
      HealthSyncEntry(
        key: key,
        startMs: startMs,
        endMs: endMs,
        accountId: _d.currentAccountId(prefs),
      ),
    );
  }

  static Future<void>? _flushing;
  static bool _again = false;

  /// Pasa las marcas de Salud del historial a la cola y luego escribe lo
  /// pendiente. Un solo envío a la vez: una llamada durante otro envío se une
  /// a él y pide una vuelta más al final.
  static Future<void> flush() {
    final running = _flushing;
    if (running != null) {
      _again = true;
      return running;
    }
    final done = Completer<void>();
    _flushing = done.future;
    _flushLoop(done);
    return done.future;
  }

  static Future<void> _flushLoop(Completer<void> done) async {
    do {
      _again = false;
      // Generación al empezar la vuelta, antes de cualquier espera.
      final generation = _generation;
      try {
        await _d.ready();
        final prefs = await _d.prefs();
        if (_accountChanging(prefs)) {
          // Sale cuando la nueva identidad quede asentada.
          _flushHeld = true;
          continue;
        }
        await _drainTimerMarks(prefs, generation);
        await _writePending(prefs, generation);
      } catch (error) {
        AppLogger.e(_tag, 'Falló el envío a Salud', error);
      }
    } while (_again);
    // Sin espera entre la última revisión y esto: ninguna llamada se pierde.
    _flushing = null;
    done.complete();
  }

  /// Sesiones del temporizador: llegan solo por la marca guardada junto con su
  /// runId (R78). Cada marca se pasa a la cola (o se descarta) y DESPUÉS se
  /// quita; así un cierre a la mitad deja la marca (se vuelve a agregar sin
  /// duplicar) o la entrada sin marca (se escribe una vez) (R85).
  ///
  /// La marca solo se quita cuando la cola confirmó el guardado; si falló,
  /// la marca queda para el siguiente envío.
  static Future<void> _drainTimerMarks(
    SharedPreferences prefs,
    int generation,
  ) async {
    final marks = await _d.pendingRuns();
    if (marks.isEmpty) return;
    for (final mark in marks) {
      // Cambió la cuenta o se apagó Salud: estas marcas ya no son de aquí.
      if (generation != _generation || _accountChanging(prefs)) return;
      final account = _d.currentAccountId(prefs);
      var queued = true;
      if (mark.accountId == account) {
        if (hasConsent(prefs)) {
          queued = await add(
            HealthSyncEntry(
              key: mark.runId,
              startMs: mark.startMs,
              endMs: mark.endMs,
              accountId: mark.accountId,
            ),
          );
        } else if (await _canAskForConsent(prefs)) {
          queued = await add(
            HealthSyncEntry(
              key: mark.runId,
              startMs: mark.startMs,
              endMs: mark.endMs,
              accountId: mark.accountId,
              awaitingConsent: true,
            ),
          );
        }
      }
      if (!queued) {
        AppLogger.w(_tag, 'No se guardó ${mark.runId}; la marca se conserva');
        continue;
      }
      if (!await _d.clearPending(mark.runId)) {
        AppLogger.w(_tag, 'No se pudo quitar la marca de ${mark.runId}');
      }
    }
  }

  /// La tarjeta del final puede ofrecer Salud: está disponible y la persona
  /// no la descartó.
  static Future<bool> _canAskForConsent(SharedPreferences prefs) async {
    if (prefs.getBool(SharedPreferenceConstants.healthPromptDismissed) ==
        true) {
      return false;
    }
    try {
      return await _d.healthAvailable();
    } catch (_) {
      return false;
    }
  }

  static Future<void> _writePending(
    SharedPreferences prefs,
    int generation,
  ) async {
    if (generation != _generation ||
        _accountChanging(prefs) ||
        !hasConsent(prefs)) {
      return;
    }
    final marked = {for (final run in await _d.pendingRuns()) run.runId};
    await _locked(() async {
      if (generation != _generation) return;
      final account = _d.currentAccountId(prefs);
      // Lo último que la cola guardó. Si cambia por fuera (la eliminación de
      // la cuenta borra la clave sin este bloqueo), no se vuelve a escribir.
      var stored = _raw(prefs);
      bool stillOurs() =>
          generation == _generation &&
          !_accountChanging(prefs) &&
          _raw(prefs) == stored;
      // Después de CADA espera y justo antes de llamar a Salud: la misma
      // generación (apagar Salud o cambiar de cuenta la sube al instante,
      // antes de tocar el permiso guardado), la misma cuenta dueña, el mismo
      // permiso y la misma lista (TIMER-REVIEW-02).
      bool maySend(HealthSyncEntry entry) =>
          stillOurs() && _maySend(prefs, entry);
      Future<bool> save(List<HealthSyncEntry> entries) async {
        if (!stillOurs()) return false;
        if (!await _save(prefs, entries)) return false;
        stored = _raw(prefs);
        return true;
      }

      var entries = _read(prefs);
      final own = [
        for (final e in entries)
          if (e.accountId == account) e,
      ];
      if (own.length != entries.length) {
        entries = own;
        if (!await save(entries)) return;
      }
      var i = 0;
      while (i < entries.length) {
        final entry = entries[i];
        // Sin permiso todavía, o su marca sigue en el historial: se salta.
        if (entry.awaitingConsent || marked.contains(entry.key)) {
          i++;
          continue;
        }
        // Justo antes de CADA envío: misma cuenta, mismo permiso y la cola
        // no se vació mientras se escribía la anterior.
        if (!maySend(entry)) return;
        if (_d.isIOS) {
          if (entry.attempting) {
            // Un intento anterior se cortó a la mitad y pudo haber llegado:
            // a lo más una vez, así que no se reintenta.
            AppLogger.w(_tag, 'Se descarta ${entry.key}: intento cortado');
            entries.removeAt(i);
            if (!await save(entries)) return;
            continue;
          }
          entries[i] = entry.copyWith(attempting: true);
          if (!await save(entries)) return;
        }
        // Sin ninguna espera entre esta revisión y la llamada a Salud.
        if (!maySend(entry)) return;
        // La misma revisión viaja con la escritura: el gestor de Salud la
        // repite tras consultar permisos y justo antes de enviar (TMR-01).
        final written = await _tryWrite(entry, () => maySend(entry));
        if (!written) {
          if (_d.isIOS) {
            // No se escribió nada: se puede reintentar después.
            entries[i] = entry.copyWith(attempting: false);
            await save(entries);
          }
          // Android conserva la entrada; el reintento usa el mismo
          // clientRecordId y no duplica.
          return;
        }
        entries.removeAt(i);
        if (!await save(entries)) return;
        try {
          await _d.markSynced(entry.endMs);
        } catch (error) {
          AppLogger.e(_tag, 'No se pudo anotar ${entry.key}', error);
        }
      }
    });
  }

  /// La cuenta actual es la dueña de la entrada y su permiso sigue vigente.
  static bool _maySend(SharedPreferences prefs, HealthSyncEntry entry) =>
      hasConsent(prefs) && _d.currentAccountId(prefs) == entry.accountId;

  static Future<bool> _tryWrite(
    HealthSyncEntry entry,
    bool Function() stillAllowed,
  ) async {
    try {
      return await _d.write(entry, stillAllowed);
    } catch (error) {
      AppLogger.e(_tag, 'Falló la escritura de ${entry.key}', error);
      return false;
    }
  }

  static String? _raw(SharedPreferences prefs) =>
      prefs.getString(SharedPreferenceConstants.pendingHealthSessions);

  static List<HealthSyncEntry> _read(SharedPreferences prefs) {
    final raw = _raw(prefs);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final entries = <HealthSyncEntry>[];
      for (final item in list) {
        try {
          entries.add(
            HealthSyncEntry.fromJson(Map<String, dynamic>.from(item as Map)),
          );
        } on Object {
          // Una entrada dañada no bloquea a las demás.
        }
      }
      return entries;
    } on Object {
      return [];
    }
  }

  /// Guarda la lista. Si el guardado no se confirma, devuelve la caché de
  /// preferencias a lo que había antes, para que nadie lea un cambio que no
  /// quedó guardado.
  static Future<bool> _save(
    SharedPreferences prefs,
    List<HealthSyncEntry> entries,
  ) async {
    final previous = _raw(prefs);
    final raw = entries.isEmpty
        ? null
        : jsonEncode([for (final e in entries) e.toJson()]);
    var saved = false;
    try {
      saved = await _d.persist(prefs, raw);
    } catch (error) {
      AppLogger.e(_tag, 'No se pudo guardar la cola de Salud', error);
    }
    if (saved) return true;
    AppLogger.w(_tag, 'La cola de Salud no se guardó; se deshace el cambio');
    if (_raw(prefs) != previous) {
      try {
        if (previous == null) {
          await prefs.remove(SharedPreferenceConstants.pendingHealthSessions);
        } else {
          await prefs.setString(
            SharedPreferenceConstants.pendingHealthSessions,
            previous,
          );
        }
      } catch (_) {
        // La caché ya volvió a su valor; el disco conserva el anterior.
      }
    }
    return false;
  }
}
