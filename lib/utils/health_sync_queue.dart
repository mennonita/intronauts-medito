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

/// Lo que la cola necesita del resto de la app. Las pruebas lo reemplazan.
class HealthSyncDependencies {
  HealthSyncDependencies({
    Future<SharedPreferences> Function()? prefs,
    Future<void> Function()? ready,
    String Function(SharedPreferences prefs)? currentAccountId,
    bool? isIOS,
    Future<bool> Function(HealthSyncEntry entry)? write,
    Future<void> Function(int endMs)? markSynced,
    Future<bool> Function()? healthAvailable,
    Future<List<HealthPendingRun>> Function()? pendingRuns,
    Future<bool> Function(String runId)? clearPending,
  }) : prefs = prefs ?? SharedPreferences.getInstance,
       ready = ready ?? _statsReady,
       currentAccountId = currentAccountId ?? _verifiedAccountId,
       isIOS = isIOS ?? Platform.isIOS,
       write = write ?? _writeToHealth,
       markSynced =
           markSynced ??
           ((endMs) => HealthKitManager().markSessionAsSynced(endMs)),
       healthAvailable =
           healthAvailable ??
           (() => HealthKitManager().isHealthConnectAvailable()),
       pendingRuns = pendingRuns ?? _statsPendingRuns,
       clearPending =
           clearPending ??
           ((runId) => StatsManager().clearHealthPending(runId));

  final Future<SharedPreferences> Function() prefs;

  /// Espera a que el historial esté cargado (cuenta verificada y marcas).
  final Future<void> Function() ready;

  /// Cuenta dueña de las sesiones: la cuenta verificada del historial, o `''`
  /// sin verificar. Es el mismo id que las sesiones del temporizador llevan
  /// como dueño (`ownerId`).
  final String Function(SharedPreferences prefs) currentAccountId;
  final bool isIOS;
  final Future<bool> Function(HealthSyncEntry entry) write;
  final Future<void> Function(int endMs) markSynced;
  final Future<bool> Function() healthAvailable;
  final Future<List<HealthPendingRun>> Function() pendingRuns;
  final Future<bool> Function(String runId) clearPending;

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

  static Future<bool> _writeToHealth(HealthSyncEntry entry) {
    return HealthKitManager().writeMindfulnessData(
      DateTime.fromMillisecondsSinceEpoch(entry.startMs),
      DateTime.fromMillisecondsSinceEpoch(entry.endMs),
      clientRecordId: entry.key,
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
    await _d.ready();
    final prefs = await _d.prefs();
    if (!on) {
      await _locked(() async {
        await prefs.setBool(SharedPreferenceConstants.healthSyncEnabled, false);
        await prefs.remove(SharedPreferenceConstants.healthSyncAccountId);
        await prefs.remove(SharedPreferenceConstants.pendingHealthSessions);
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
  static Future<void> add(HealthSyncEntry entry) async {
    final prefs = await _d.prefs();
    await _locked(() async {
      final entries = _read(prefs);
      final index = entries.indexWhere((e) => e.key == entry.key);
      if (index >= 0) {
        final existing = entries[index];
        if (existing.awaitingConsent && !entry.awaitingConsent) {
          entries[index] = existing.copyWith(awaitingConsent: false);
          await _save(prefs, entries);
        }
        return;
      }
      if (entry.awaitingConsent) {
        entries.removeWhere((e) => e.awaitingConsent);
      }
      entries.add(entry);
      while (entries.length > maxEntries) {
        entries.removeAt(0);
      }
      await _save(prefs, entries);
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
    if (!hasConsent(prefs)) return false;
    await add(
      HealthSyncEntry(
        key: key,
        startMs: startMs,
        endMs: endMs,
        accountId: _d.currentAccountId(prefs),
      ),
    );
    return true;
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
      try {
        await _d.ready();
        final prefs = await _d.prefs();
        await _drainTimerMarks(prefs);
        await _writePending(prefs);
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
  static Future<void> _drainTimerMarks(SharedPreferences prefs) async {
    final marks = await _d.pendingRuns();
    if (marks.isEmpty) return;
    final account = _d.currentAccountId(prefs);
    for (final mark in marks) {
      if (mark.accountId == account) {
        if (hasConsent(prefs)) {
          await add(
            HealthSyncEntry(
              key: mark.runId,
              startMs: mark.startMs,
              endMs: mark.endMs,
              accountId: mark.accountId,
            ),
          );
        } else if (await _canAskForConsent(prefs)) {
          await add(
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

  static Future<void> _writePending(SharedPreferences prefs) async {
    if (!hasConsent(prefs)) return;
    final account = _d.currentAccountId(prefs);
    final marked = {for (final run in await _d.pendingRuns()) run.runId};
    await _locked(() async {
      var entries = _read(prefs);
      final own = [
        for (final e in entries)
          if (e.accountId == account) e,
      ];
      if (own.length != entries.length) {
        entries = own;
        if (!await _save(prefs, entries)) return;
      }
      var i = 0;
      while (i < entries.length) {
        final entry = entries[i];
        // Sin permiso todavía, o su marca sigue en el historial: se salta.
        if (entry.awaitingConsent || marked.contains(entry.key)) {
          i++;
          continue;
        }
        if (_d.isIOS) {
          if (entry.attempting) {
            // Un intento anterior se cortó a la mitad y pudo haber llegado:
            // a lo más una vez, así que no se reintenta.
            AppLogger.w(_tag, 'Se descarta ${entry.key}: intento cortado');
            entries.removeAt(i);
            if (!await _save(prefs, entries)) return;
            continue;
          }
          entries[i] = entry.copyWith(attempting: true);
          if (!await _save(prefs, entries)) return;
        }
        final written = await _tryWrite(entry);
        if (!written) {
          if (_d.isIOS) {
            // No se escribió nada: se puede reintentar después.
            entries[i] = entry.copyWith(attempting: false);
            await _save(prefs, entries);
          }
          // Android conserva la entrada; el reintento usa el mismo
          // clientRecordId y no duplica.
          return;
        }
        entries.removeAt(i);
        if (!await _save(prefs, entries)) return;
        try {
          await _d.markSynced(entry.endMs);
        } catch (error) {
          AppLogger.e(_tag, 'No se pudo anotar ${entry.key}', error);
        }
      }
    });
  }

  static Future<bool> _tryWrite(HealthSyncEntry entry) async {
    try {
      return await _d.write(entry);
    } catch (error) {
      AppLogger.e(_tag, 'Falló la escritura de ${entry.key}', error);
      return false;
    }
  }

  static List<HealthSyncEntry> _read(SharedPreferences prefs) {
    final raw = prefs.getString(
      SharedPreferenceConstants.pendingHealthSessions,
    );
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

  static Future<bool> _save(
    SharedPreferences prefs,
    List<HealthSyncEntry> entries,
  ) async {
    try {
      if (entries.isEmpty) {
        return await prefs.remove(
          SharedPreferenceConstants.pendingHealthSessions,
        );
      }
      return await prefs.setString(
        SharedPreferenceConstants.pendingHealthSessions,
        jsonEncode([for (final e in entries) e.toJson()]),
      );
    } catch (error) {
      AppLogger.e(_tag, 'No se pudo guardar la cola de Salud', error);
      return false;
    }
  }
}
