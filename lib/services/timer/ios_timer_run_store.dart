import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_timeline.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:medito/utils/stats_updater.dart' show handleTimerRun;
import 'package:shared_preferences/shared_preferences.dart';

/// Sesión recuperada y guardada, para el aviso «Guardamos tu sesión…».
class RecoveredTimerSession {
  const RecoveredTimerSession({required this.minutes, required this.elapsedMs});

  final int minutes;
  final int elapsedMs;
}

/// Datos de una sesión del temporizador al empezar (iOS).
class TimerRunStart {
  const TimerRunStart({
    required this.runId,
    required this.ownerId,
    required this.fileId,
    required this.trackId,
    this.guideId = '',
    required this.prepMs,
    required this.plannedMs,
    required this.extraTime,
    required this.isStopwatch,
  });

  factory TimerRunStart.fromRequest(PlaybackRequest request) => TimerRunStart(
    runId: request.timerRunId,
    ownerId: request.timerOwnerId,
    fileId: request.fileId,
    trackId: request.trackId,
    prepMs: request.timerPrepMs,
    plannedMs: request.plannedDurationMs,
    extraTime: request.hasExtraTime,
    isStopwatch: request.timerMode == TimerMode.stopwatch,
  );

  final String runId;
  final String ownerId;
  final String fileId;
  final String trackId;
  final String guideId;
  final int prepMs;
  final int plannedMs;
  final bool extraTime;
  final bool isStopwatch;
}

/// Registro de sesiones del temporizador en iOS (R75), con la misma forma que
/// el de Android: `active` es la sesión en curso y `finished` las sesiones
/// cerradas que esperan guardarse en las estadísticas.
///
/// Cada cambio es una sola escritura comprobada; la memoria solo cambia si la
/// escritura funcionó. Todo corre bajo un mismo candado, también [clear], y
/// cada escritura se descarta si la cuenta cambió desde su evento (R76, R82).
typedef _RunState = ({
  Map<String, dynamic>? active,
  List<Map<String, dynamic>> finished,
});

class IosTimerRunStore {
  IosTimerRunStore({
    Future<TimerRecordResult> Function(Map<String, dynamic> payload)? record,
    int Function()? clock,
    int Function()? elapsed,
    Future<SharedPreferences> Function()? prefs,
  }) : _record = record ?? handleTimerRun,
       _clock = clock ?? _now,
       _elapsed = elapsed ?? _monotonicNow,
       _prefs = prefs ?? SharedPreferences.getInstance;

  static IosTimerRunStore instance = IosTimerRunStore();

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  // Reloj que solo avanza: un cambio de hora del teléfono no lo mueve (REV-04).
  static final _monotonic = Stopwatch()..start();
  static int _monotonicNow() => _monotonic.elapsedMilliseconds;

  /// Cada cuánto se guarda la posición mientras suena.
  static const positionInterval = Duration(seconds: 3);

  final Future<TimerRecordResult> Function(Map<String, dynamic>) _record;
  // Hora del teléfono: solo para fechar las sesiones.
  final int Function() _clock;
  // Reloj monotónico: solo para medir el intervalo entre escrituras.
  final int Function() _elapsed;
  final Future<SharedPreferences> Function() _prefs;

  Future<void> _queue = Future.value();
  String? _liveRunId;
  int? _lastPositionWriteMs;
  Map<String, dynamic>? _active;
  List<Map<String, dynamic>> _finished = const [];
  // Último estado CONFIRMADO por el almacenamiento. La caché de
  // SharedPreferences cambia aunque la escritura falle, así que los reintentos
  // nunca la leen.
  _RunState? _confirmed;
  // Una sola decisión por sesión: true = cerrada con guardado, false =
  // descartada. Un cierre posterior nunca la cambia ni la reconstruye.
  final _closed = <String, bool>{};
  // Cierres naturales cuyo guardado falló: se conservan con su tiempo final y
  // viajan en la siguiente escritura que funcione.
  final _unsaved = <String, Map<String, dynamic>>{};
  // El borrado por cambio de cuenta falló: el disco aún tiene datos viejos.
  bool _clearPending = false;
  Future<RecoveredTimerSession?>? _recovering;
  Future<RecoveredTimerSession?>? _delivering;

  /// Copia en memoria de la sesión en curso, tal como quedó guardada.
  Map<String, dynamic>? get active =>
      _active == null ? null : Map.unmodifiable(_active!);

  /// Sesiones cerradas que todavía no se guardan en las estadísticas.
  List<Map<String, dynamic>> get finished => List.unmodifiable(_finished);

  /// La sesión que suena en este proceso, si hay una.
  String? get liveRunId => _liveRunId;

  /// Indica si la campana final ya empezó o la posición pasó el final.
  bool endPassed(String runId) =>
      _active?['runId'] == runId && _active?['endPassed'] == true;

  Future<T> _locked<T>(Future<T> Function() body) {
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    return previous.then((_) => body()).whenComplete(done.complete);
  }

  _RunState _state(SharedPreferences prefs) {
    final state = _confirmed ??= _read(prefs);
    final unsaved = _unsaved.values.toList();
    if (unsaved.isEmpty) return state;
    final active = state.active;
    return (
      active: active != null && _unsaved.containsKey(active['runId'])
          ? null
          : active,
      finished: [
        ...state.finished,
        for (final item in unsaved)
          if (!state.finished.any((other) => other['runId'] == item['runId']))
            item,
      ],
    );
  }

  _RunState _read(SharedPreferences prefs) {
    final raw = prefs.get(SharedPreferenceConstants.iosTimerRuns);
    if (raw is! String) return (active: null, finished: const []);
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return (active: null, finished: const []);
      final active = json['active'];
      return (
        active: active is Map && active['runId'] is String
            ? Map<String, dynamic>.of(active.cast())
            : null,
        finished: [
          for (final item in (json['finished'] as List? ?? const []))
            if (item is Map && item['runId'] is String)
              Map<String, dynamic>.of(item.cast()),
        ],
      );
    } on FormatException {
      return (active: null, finished: const []);
    }
  }

  /// Una sola escritura con el estado completo; la memoria cambia solo si se
  /// guardó y la cuenta sigue siendo la del evento.
  Future<bool> _write(
    SharedPreferences prefs,
    Map<String, dynamic>? active,
    List<Map<String, dynamic>> finished,
    int generation,
  ) async {
    if (!PlaybackAccount.isCurrent(generation)) return false;
    bool saved;
    try {
      saved = await prefs.setString(
        SharedPreferenceConstants.iosTimerRuns,
        jsonEncode({'active': active, 'finished': finished}),
      );
    } catch (error) {
      AppLogger.e('TIMER', 'No se pudo guardar la sesión en curso', error);
      saved = false;
    }
    if (saved) {
      _confirmed = (active: active, finished: finished);
      _active = active;
      _finished = finished;
      _unsaved.clear();
      // La escritura completa reemplazó cualquier dato viejo en disco.
      _clearPending = false;
    }
    return saved;
  }

  Future<bool> _transition(
    int generation,
    ({Map<String, dynamic>? active, List<Map<String, dynamic>> finished})?
    Function(
      ({Map<String, dynamic>? active, List<Map<String, dynamic>> finished})
      state,
    )
    change,
  ) => _locked(() async {
    if (!PlaybackAccount.isCurrent(generation)) return false;
    final prefs = await _prefs();
    final next = change(_state(prefs));
    if (next == null) return true;
    return _write(prefs, next.active, next.finished, generation);
  });

  /// Empieza una sesión. Si el registro guarda otra sesión que ya no suena, la
  /// pasa primero a `finished` como recuperada, en la misma escritura (R81).
  /// Nunca quita un elemento de `finished`.
  Future<bool> start(TimerRunStart run, {int? generation}) {
    final event = generation ?? PlaybackAccount.generation;
    _liveRunId = run.runId;
    _lastPositionWriteMs = null;
    final now = _clock();
    return _transition(event, (state) {
      final finished = [...state.finished];
      final stale = state.active;
      if (stale != null && stale['runId'] != run.runId) {
        final recovered = _recoveredItem(stale);
        if (recovered != null &&
            !finished.any((item) => item['runId'] == stale['runId'])) {
          finished.add(recovered);
        }
      }
      return (
        active: {
          'runId': run.runId,
          'ownerId': run.ownerId,
          'fileId': run.fileId,
          'trackId': run.trackId,
          'guideId': run.guideId,
          'startEpochMs': now,
          'prepMs': run.prepMs,
          'plannedMs': run.plannedMs,
          'extraTime': run.extraTime,
          'isStopwatch': run.isStopwatch,
          'lastPositionMs': 0,
          'updatedAtMs': now,
          'endPassed': false,
        },
        finished: finished,
      );
    });
  }

  /// Guarda la posición cada [positionInterval], o de inmediato con [force]
  /// (pausa). Ignora eventos de otra sesión.
  Future<bool> updatePosition(
    String runId,
    int positionMs, {
    bool force = false,
    bool? endPassed,
    int? generation,
  }) {
    final event = generation ?? PlaybackAccount.generation;
    final now = _clock();
    final tick = _elapsed();
    final last = _lastPositionWriteMs;
    // Cruzar el final se guarda una vez; después vuelve el intervalo normal.
    final crossing = endPassed == true && _active?['endPassed'] != true;
    // El intervalo se mide con el reloj monotónico: atrasar la hora del
    // teléfono no congela el registro (REV-04).
    if (!force &&
        !crossing &&
        last != null &&
        tick - last < positionInterval.inMilliseconds) {
      return Future.value(true);
    }
    _lastPositionWriteMs = tick;
    return _transition(event, (state) {
      final active = state.active;
      if (active == null || active['runId'] != runId) return null;
      return (
        active: {
          ...active,
          'lastPositionMs': positionMs,
          'updatedAtMs': now,
          if (endPassed == true || active['endPassed'] == true)
            'endPassed': true,
        },
        finished: state.finished,
      );
    });
  }

  /// La campana final empezó o la posición pasó el final (R79).
  Future<bool> markEndPassed(String runId, {int? generation}) {
    final event = generation ?? PlaybackAccount.generation;
    return _transition(event, (state) {
      final active = state.active;
      if (active == null ||
          active['runId'] != runId ||
          active['endPassed'] == true) {
        return null;
      }
      return (active: {...active, 'endPassed': true}, finished: state.finished);
    });
  }

  /// Cierre con guardado (final natural o «Guardar y salir»): pasa `active` a
  /// `finished` con el tiempo final (≥ 60 s; si no, solo lo borra). Se llama
  /// ANTES de detener el audio.
  ///
  /// La decisión se revisa y se registra dentro del mismo candado que la
  /// escritura: si «Salir sin guardar» ganó la carrera, el final natural
  /// nunca reconstruye la sesión descartada (REV-02).
  Future<bool> finish({
    required String runId,
    required int durationMs,
    int? timestampMs,
    TimerRunStart? fallback,
    int? generation,
    bool keepForRetry = false,
  }) async {
    final event = generation ?? PlaybackAccount.generation;
    final timestamp = timestampMs ?? _clock();
    for (var attempt = 0; attempt < 2; attempt++) {
      final lastAttempt = attempt == 1;
      final saved = await _locked(() async {
        // La primera decisión gana: una sesión descartada o ya cerrada no vuelve.
        if (_closed.containsKey(runId)) return true;
        if (!PlaybackAccount.isCurrent(event)) return false;
        final prefs = await _prefs();
        final next = _finishState(
          _state(prefs),
          runId,
          durationMs,
          timestamp,
          fallback,
        );
        final written =
            next == null ||
            await _write(prefs, next.active, next.finished, event);
        if (written) {
          _closed[runId] = true;
        } else if (lastAttempt &&
            keepForRetry &&
            PlaybackAccount.isCurrent(event)) {
          // El audio ya terminó: conserva el tiempo final para el siguiente
          // guardado en vez de perderlo.
          final item = _pendingItem(runId, durationMs, timestamp, fallback);
          if (item != null) _unsaved[runId] = item;
          _closed[runId] = true;
        }
        if (_liveRunId == runId && _closed.containsKey(runId)) {
          _liveRunId = null;
        }
        return written;
      });
      if (saved || !PlaybackAccount.isCurrent(event)) return saved;
    }
    return false;
  }

  Map<String, dynamic>? _pendingItem(
    String runId,
    int durationMs,
    int timestamp,
    TimerRunStart? fallback,
  ) {
    if (durationMs < kMinRecordedTimerSession.inMilliseconds) return null;
    final active = _confirmed?.active;
    final source = active != null && active['runId'] == runId
        ? active
        : fallback == null
        ? null
        : _fallbackSource(fallback);
    return source == null
        ? null
        : _item(source, durationMs, timestamp, recovered: false);
  }

  static Map<String, dynamic> _fallbackSource(TimerRunStart fallback) => {
    'runId': fallback.runId,
    'ownerId': fallback.ownerId,
    'fileId': fallback.fileId,
    'guideId': fallback.guideId,
  };

  ({Map<String, dynamic>? active, List<Map<String, dynamic>> finished})?
  _finishState(
    ({Map<String, dynamic>? active, List<Map<String, dynamic>> finished}) state,
    String runId,
    int durationMs,
    int timestamp,
    TimerRunStart? fallback,
  ) {
    final active = state.active;
    final owned = active != null && active['runId'] == runId;
    final listed = state.finished.any((item) => item['runId'] == runId);
    final source = owned
        ? active
        : fallback == null
        ? null
        : _fallbackSource(fallback);
    if (source == null && !owned) return null;
    final recorded = durationMs >= kMinRecordedTimerSession.inMilliseconds;
    return (
      active: owned ? null : active,
      finished: [
        ...state.finished,
        if (recorded && !listed && source != null)
          _item(source, durationMs, timestamp, recovered: false),
      ],
    );
  }

  /// «Salir sin guardar» (R52): borra `active` antes de detener el audio.
  /// Reintenta una vez; `false` significa que hay que seguir sonando. La
  /// decisión se revisa y se registra dentro del candado (REV-02).
  Future<bool> discard(String runId, {int? generation}) async {
    final event = generation ?? PlaybackAccount.generation;
    for (var attempt = 0; attempt < 2; attempt++) {
      final cleared = await _locked(() async {
        // Ya decidida: «Salir sin guardar» no deshace un cierre que ya se guardó.
        if (_closed.containsKey(runId)) return true;
        if (!PlaybackAccount.isCurrent(event)) return false;
        final prefs = await _prefs();
        final state = _state(prefs);
        final written =
            state.active?['runId'] != runId ||
            await _write(prefs, null, state.finished, event);
        if (written) {
          _closed[runId] = false;
          if (_liveRunId == runId) _liveRunId = null;
        }
        return written;
      });
      if (cleared || !PlaybackAccount.isCurrent(event)) return cleared;
    }
    return false;
  }

  /// Una sesión que deja de sonar en este proceso (otra la reemplazó) ya no
  /// es la viva: la recuperación puede volver a verla (REV-05).
  void releaseLiveRun(String runId) {
    if (_liveRunId == runId) _liveRunId = null;
  }

  /// Vacía el registro al cambiar o borrar la cuenta. Corre bajo el mismo
  /// candado que las escrituras, así que ninguna se intercala (R82).
  Future<void> clear() => _locked(() async {
    _liveRunId = null;
    _lastPositionWriteMs = null;
    _active = null;
    _finished = const [];
    _closed.clear();
    _unsaved.clear();
    // Desde ahora nada se lee del disco viejo, aunque el borrado falle.
    _confirmed = (active: null, finished: const []);
    _clearPending = true;
    await _removeStale();
  });

  Future<void> _removeStale() async {
    final prefs = await _prefs();
    if (!await prefs.remove(SharedPreferenceConstants.iosTimerRuns)) {
      throw StateError('No se pudo borrar el registro del temporizador');
    }
    _clearPending = false;
  }

  /// Al abrir la app y al volver a ella: una sesión en `active` que ya no
  /// suena se pasa a `finished` como recuperada (< 60 s se borra), y luego se
  /// entregan todas las pendientes. Devuelve la sesión recuperada y aceptada.
  Future<RecoveredTimerSession?> recoverTimerRuns() =>
      _recovering ??= _recover().whenComplete(() => _recovering = null);

  Future<RecoveredTimerSession?> _recover() async {
    final event = PlaybackAccount.generation;
    if (_clearPending) {
      try {
        await _locked(_removeStale);
      } catch (error) {
        AppLogger.e('TIMER', 'El registro viejo sigue sin borrarse', error);
      }
    }
    await _transition(event, (state) {
      final stale = state.active;
      if (stale == null || stale['runId'] == _liveRunId) return null;
      final recovered = _recoveredItem(stale);
      return (
        active: null,
        finished: [
          ...state.finished,
          if (recovered != null &&
              !state.finished.any((item) => item['runId'] == stale['runId']))
            recovered,
        ],
      );
    });
    return deliver();
  }

  /// Entrega cada sesión de `finished`, en orden, a las estadísticas. Quita la
  /// que tenga cualquier resultado salvo `failed`; con `failed` se detiene y se
  /// reintenta en la siguiente apertura (TECH-17).
  Future<RecoveredTimerSession?> deliver() =>
      _delivering ??= _deliver().whenComplete(() => _delivering = null);

  Future<RecoveredTimerSession?> _deliver() async {
    final event = PlaybackAccount.generation;
    RecoveredTimerSession? shown;
    while (PlaybackAccount.isCurrent(event)) {
      final prefs = await _prefs();
      final pending = _state(prefs).finished;
      if (pending.isEmpty) break;
      final item = pending.first;
      final runId = item['runId'] as String;
      final durationMs = item['durationMs'] as int? ?? 0;
      TimerRecordResult result;
      try {
        result = await _record({
          TypeConstants.trackIdKey: item['trackId'],
          TypeConstants.durationIdKey: durationMs,
          TypeConstants.fileIdKey: item['fileId'],
          TypeConstants.guideIdKey: item['guideId'] ?? '',
          TypeConstants.timestampIdKey: item['timestamp'],
          TypeConstants.runIdKey: runId,
          timerOwnerIdKey: item['ownerId'] ?? '',
        });
      } catch (error) {
        AppLogger.e('TIMER', 'No se pudo entregar la sesión $runId', error);
        result = TimerRecordResult.failed;
      }
      if (result == TimerRecordResult.failed) break;
      if (result == TimerRecordResult.accepted ||
          result == TimerRecordResult.duplicate) {
        _closed[runId] = true;
      }
      final removed = await _transition(
        event,
        (state) => (
          active: state.active,
          finished: [
            for (final other in state.finished)
              if (other['runId'] != runId) other,
          ],
        ),
      );
      if (result == TimerRecordResult.accepted && item['recovered'] == true) {
        shown = RecoveredTimerSession(
          minutes: durationMs ~/ Duration.millisecondsPerMinute,
          elapsedMs: durationMs,
        );
      }
      if (!removed) break;
    }
    return shown;
  }

  /// Convierte una sesión que dejó de sonar en un cierre recuperado, con el
  /// tiempo meditado hasta la última posición guardada; null si < 60 s.
  Map<String, dynamic>? _recoveredItem(Map<String, dynamic> stale) {
    final elapsed = TimerTimeline(
      prepMs: stale['prepMs'] as int? ?? 0,
      plannedMs: stale['plannedMs'] as int? ?? 0,
      extraTime: stale['extraTime'] == true,
      isStopwatch: stale['isStopwatch'] == true,
    ).elapsedMs(stale['lastPositionMs'] as int? ?? 0);
    if (elapsed < kMinRecordedTimerSession.inMilliseconds) return null;
    return _item(
      stale,
      elapsed,
      stale['updatedAtMs'] as int? ?? _clock(),
      recovered: true,
    );
  }

  static Map<String, dynamic> _item(
    Map<String, dynamic> source,
    int durationMs,
    int timestamp, {
    required bool recovered,
  }) => {
    'runId': source['runId'],
    'ownerId': source['ownerId'] ?? '',
    'trackId': timerSessionId(Duration(milliseconds: durationMs)),
    'fileId': source['fileId'] ?? '',
    'guideId': source['guideId'] ?? '',
    'durationMs': durationMs,
    'timestamp': timestamp,
    'recovered': recovered,
  };

  @visibleForTesting
  void resetLiveRunForTesting() => _liveRunId = null;
}
