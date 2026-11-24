import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/services/network/http_api_service.dart';
import 'package:medito/services/stats_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/utils/practice_history.dart';
import 'package:medito/utils/audio_completion_tracker.dart';
import 'package:medito/utils/calendar_days.dart';
import 'package:medito/services/home_widget_service.dart';
import 'package:medito/utils/consistency_score_history.dart';
import 'package:medito/utils/day_boundary.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/utils/stats_change.dart';

// Key Rules for a Normal Streak (Without Streak Freezes)
// 1.	Meditating every day increases the streak by 1. Each consecutive day of meditation adds to the streak.
// 2.	Missing a day resets the streak to 0. If the user skips meditation for a full calendar day, the next time they open the app, the streak will be reset.
// 3.	The streak only updates when the app is opened. If the user misses a day but does not open the app, the streak does not reset until they next launch it.
// 4.	Meditation must be completed before midnight. The streak is based on calendar days, so meditating after midnight will count as the next day's session.
// 5.	A new streak starts from 1 after a reset. If the streak is broken, meditating again starts a fresh streak from 1.

// Key Rules for Streak Freezes
// 	1.	Streak freezes prevent a reset but must be activated manually. If a user opens the app after missing a day, they will have the option to use a streak freeze before the streak resets.
// 	2.	Each streak freeze covers only one missed day. If a user misses multiple days, they need an equal number of streak freezes to restore their streak.
// 	3.	Streak freezes apply to specific missed days. If a freeze is used, it bridges the gap so the streak is not broken, but does not add to the streak counter since no meditation was completed.
// 	4.	The app only suggests a streak restoration if the user has enough streak freezes. If a user misses multiple days but does not have enough streak freezes to cover all of them, the app does not offer a partial restoration.
// 	5.	Streak freezes do not apply automatically. Users must choose to use them when they open the app after missing a day.
// 	6.	After using a streak freeze, meditating that day continues the streak. If a streak freeze is applied and the user meditates, the streak progresses as if no days were missed.
//  7. The streak applies to the days before today. The user can use multiple streak freezes to cover multiple days, but it will never restore a previously broken streak, only the current streak can be restored.

typedef _StatsAttempt = ({int seq, int changes, String digest});

/// Clave del dueño de una sesión del temporizador en su registro de entrega.
const String timerOwnerIdKey = 'ownerId';

/// Resultado de guardar una sesión del temporizador por su `runId`.
enum TimerRecordResult { accepted, duplicate, rejected, failed }

/// Sesión aceptada que todavía debe exportarse a Salud (R78).
class HealthPendingRun {
  const HealthPendingRun({
    required this.runId,
    required this.startMs,
    required this.endMs,
    required this.accountId,
  });

  final String runId;
  final int startMs;
  final int endMs;
  final String accountId;
}

/// Resumen de solo lectura del historial guardado antes de verificar la cuenta.
class PreVerificationSummary {
  const PreVerificationSummary({required this.sessions, required this.minutes});

  final int sessions;
  final int minutes;
}

typedef _MemoryState = ({
  LocalAllStats? allStats,
  int localSeq,
  bool dirty,
  bool needsResync,
  _StatsAttempt? attempt,
  StatsSnapshot? synced,
  LocalAllStats? legacyPending,
  String? verifiedUserId,
  List<StatsChange> changes,
  List<Map<String, dynamic>> recordedRuns,
  String? historyId,
  bool historyIdOnDisk,
});

class StatsManager {
  static final StatsManager _instance = StatsManager._internal();
  factory StatsManager() => _instance;

  static const _syncLockKey = 'stats_sync_lock';
  static const _syncLockTimeout = Duration(seconds: 30);
  static const _syncTtl = Duration(seconds: 60);
  static const _localSeqKey = 'stats_local_seq';
  static const _pendingSyncKey = 'stats_pending_sync';
  static const _pendingOwnerKey = 'stats_pending_owner';
  static const _syncedStatsKey = 'stats_synced';
  static const _syncedSeqKey = 'stats_synced_seq';
  static const _changesKey = 'stats_changes';
  static const _legacyPendingKey = 'stats_legacy_pending';
  static const _resyncKey = 'stats_needs_resync';
  static const _attemptKey = 'stats_post_attempt';
  static const _ownerKey = 'user_id';
  static const _recordedRunsKey = 'recorded_runs';
  // Identidad estable de un historial: sus copias archivadas se reconocen
  // y un archivado repetido no suma dos veces sus minutos (REV-09).
  static const _historyIdKey = 'history_id';
  static const _archivedHistoriesKey = 'archived_histories';
  static const _maxRecordedRuns = 200;
  static final _uuidPattern = RegExp(
    r'^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$',
  );

  late StatsService _statsService;
  late SharedPreferences _prefs;
  // Última lista de copias guardadas confirmada por el almacenamiento.
  List<Map<String, dynamic>>? _confirmedOwners;
  LocalAllStats? _allStats;
  bool _isInitialized = false;
  Completer<void>? _initCompleter;
  DateTime? _testDate;
  DateTime? _lastSyncedAt;
  bool _dirty = false;
  int _localSeq = 0;
  String? _verifiedUserId;
  StatsSnapshot? _synced;
  List<StatsChange> _changes = [];
  bool _needsResync = false;
  _StatsAttempt? _attempt;
  LocalAllStats? _legacyPending;
  List<Map<String, dynamic>> _recordedRuns = [];
  String? _historyId;
  // El registro activo en disco ya guarda [_historyId].
  bool _historyIdOnDisk = false;
  final _postsInFlight = <int, Future<void>>{};
  // `runId` de cada sesión del temporizador que el historial confirma.
  final _confirmedRuns = StreamController<String?>.broadcast();
  bool _changingAccount = false;

  // Un solo escritor a la vez para el registro de estadísticas y el de
  // dueños pendientes (R63).
  Future<void> _writeQueue = Future.value();
  static final _lockZoneKey = Object();

  Duration _dayBoundaryOffset = Duration.zero;

  // Bumped by clearAllStats. A sync that was already fetching when the stats
  // were cleared (sign-out, account deletion) drops its result instead of
  // writing the old account's history back.
  int _clearGeneration = 0;

  StatsManager._internal();

  /// Ejecuta [body] cuando termina la escritura anterior. Una llamada anidada
  /// dentro del mismo candado corre de inmediato.
  Future<T> _locked<T>(Future<T> Function() body) {
    if (identical(Zone.current[_lockZoneKey], this)) return body();
    final previous = _writeQueue;
    final done = Completer<void>();
    _writeQueue = done.future;
    return previous
        .then((_) {
          return runZoned(body, zoneValues: {_lockZoneKey: this});
        })
        .whenComplete(done.complete);
  }

  _MemoryState _captureState() => (
    allStats: _allStats,
    localSeq: _localSeq,
    dirty: _dirty,
    needsResync: _needsResync,
    attempt: _attempt,
    synced: _synced,
    legacyPending: _legacyPending,
    verifiedUserId: _verifiedUserId,
    changes: List.of(_changes),
    recordedRuns: [for (final run in _recordedRuns) Map.of(run)],
    historyId: _historyId,
    historyIdOnDisk: _historyIdOnDisk,
  );

  void _restoreState(_MemoryState state, {String? savedHistoryId}) {
    _allStats = state.allStats;
    _localSeq = state.localSeq;
    _dirty = state.dirty;
    _needsResync = state.needsResync;
    _attempt = state.attempt;
    _synced = state.synced;
    _legacyPending = state.legacyPending;
    _verifiedUserId = state.verifiedUserId;
    _changes = state.changes;
    _recordedRuns = state.recordedRuns;
    _historyId = savedHistoryId ?? state.historyId;
    _historyIdOnDisk = savedHistoryId != null || state.historyIdOnDisk;
  }

  /// Corre [body] dentro del candado. Si la escritura falla o lanza un error,
  /// la memoria vuelve a lo que había antes: nunca queda un cambio sin guardar.
  Future<T> _transaction<T>(Future<T> Function() body) => _locked(() async {
    final before = _captureState();
    try {
      return await body();
    } catch (_) {
      _restoreState(before);
      rethrow;
    }
  });

  Future<bool> _acquireLock() async {
    var prefs = _prefs;
    var lastLockTime = prefs.getInt(_syncLockKey) ?? 0;
    var now = _getCurrentDate().millisecondsSinceEpoch;

    if (now - lastLockTime > _syncLockTimeout.inMilliseconds) {
      var success = await prefs.setInt(_syncLockKey, now);
      if (!success) return false;

      var checkLock = prefs.getInt(_syncLockKey);
      return checkLock == now;
    }
    return false;
  }

  Future<void> _releaseLock() async {
    await _prefs.remove(_syncLockKey);
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }
    _initCompleter = Completer<void>();
    try {
      _prefs = await SharedPreferences.getInstance();
      _statsService = StatsService(
        httpApiService: HttpApiService(),
        prefs: _prefs,
      );
      await _loadLastSyncedAt(_prefs);
      _loadDayBoundaryOffset(_prefs);
      _loadSyncState();
      _isInitialized = true;
      _initCompleter!.complete();
    } catch (e) {
      AppLogger.e('STATS_MANAGER', 'Initialization failed', e);
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  Future<void> _loadLastSyncedAt([SharedPreferences? prefsArg]) async {
    try {
      var prefs = prefsArg ?? _prefs;
      var lastSyncedTimestamp = prefs.getInt(
        SharedPreferenceConstants.statsLastSyncedAt,
      );
      if (lastSyncedTimestamp != null && lastSyncedTimestamp > 0) {
        _lastSyncedAt = DateTime.fromMillisecondsSinceEpoch(
          lastSyncedTimestamp,
        );
      } else {
        _lastSyncedAt = null;
      }
    } catch (e) {
      // Handle case where SharedPreferences isn't initialized (e.g., in some tests)
      // In this case, we just leave _lastSyncedAt as null
      _lastSyncedAt = null;
    }
  }

  Future<bool> _saveLastSyncedAt(DateTime? value) async {
    try {
      const key = SharedPreferenceConstants.statsLastSyncedAt;
      return value == null
          ? await _prefs.remove(key)
          : await _prefs.setInt(key, value.millisecondsSinceEpoch);
    } catch (e) {
      AppLogger.w(
        'STATS_MANAGER',
        'No se pudo guardar la fecha de sincronización',
      );
      return false;
    }
  }

  Future<void> _markSynced() async {
    final now = _getCurrentDate();
    if (await _saveLastSyncedAt(now)) _lastSyncedAt = now;
  }

  Future<void> sync({bool force = false}) async {
    //dev.log'StatsManager: Starting sync (force: $force)');
    if (!_isInitialized) {
      await initialize();
    }

    // Early return if not forced and not dirty and within TTL
    if (!force) {
      final now = _getCurrentDate();
      final withinTtl =
          _lastSyncedAt != null && now.difference(_lastSyncedAt!) < _syncTtl;
      if (!_dirty && withinTtl) {
        //dev.log'StatsManager: Skipping sync - within TTL and not dirty');
        // Callers use sync() to populate _allStats. Skipping the network
        // round-trip must not leave the in-memory copy empty, otherwise the
        // next mutation starts from scratch and wipes the local history.
        _allStats ??= _loadLocalAllStats();
        return;
      }
    }

    for (var i = 0; i < 3; i++) {
      if (await _acquireLock()) {
        try {
          await _doSync();
          return;
        } finally {
          await _releaseLock();
        }
      }
      if (i < 2) await Future.delayed(Duration(milliseconds: 100));
    }

    //dev.log'StatsManager: Failed to acquire sync lock after retries');
  }

  Future<void> _doSync() async {
    _allStats ??= _loadLocalAllStats();
    if (_verifiedUserId == null || _changingAccount) return;
    if (_dirty) {
      await flushPendingPost();
      return;
    }

    final generation = _clearGeneration;
    final startedSeq = _localSeq;
    final remote = await _statsService.fetchAllStats();
    if (generation != _clearGeneration || startedSeq != _localSeq) return;
    if (remote == null) return;

    final saved = await _locked(() async {
      // Otra escritura pudo llegar mientras se descargaba la copia remota.
      if (generation != _clearGeneration || startedSeq != _localSeq) {
        return false;
      }
      final before = _captureState();
      // Conserva el historial local creado antes de guardar la secuencia.
      final stats = _withDerivedStats(
        before.localSeq == 0 && remote.clientSeq == 0
            ? _merge(before.allStats!, remote.stats)
            : remote.stats,
      );
      final _MemoryState next = (
        allStats: stats,
        localSeq: max(before.localSeq, remote.clientSeq),
        dirty: before.dirty,
        needsResync: before.needsResync,
        attempt: before.attempt,
        synced: remote,
        legacyPending: before.legacyPending,
        verifiedUserId: before.verifiedUserId,
        changes: before.changes,
        recordedRuns: before.recordedRuns,
        historyId: before.historyId,
        historyIdOnDisk: before.historyIdOnDisk,
      );
      final historyId = await _writeActiveRecord(next);
      _restoreState(next, savedHistoryId: historyId);
      await saveConsistencyScoreHistory(stats.consistencyScore);
      await _markSynced();
      return true;
    });
    if (saved && generation == _clearGeneration) _updateHomeWidget();
  }

  Future<LocalAllStats> get localAllStats async {
    await initialize();
    if (_allStats == null) {
      _allStats = _loadLocalAllStats();
      if (!_prefs.containsKey(SharedPreferenceConstants.localAllStatsKey)) {
        await sync();
      }
    }
    return _allStats!;
  }

  Future<int> get returns async => PracticeHistory.read(
    await localAllStats,
    prefs: _prefs,
    now: _getCurrentDate(),
    offset: _dayBoundaryOffset,
  ).returns;

  LocalAllStats _merge(LocalAllStats local, LocalAllStats remote) {
    final now = _getCurrentDate();
    final updated = now.millisecondsSinceEpoch;
    final today = DateTime(now.year, now.month, now.day);
    final hasRecentDummyTracks =
        remote.audioCompleted?.any((audio) {
          if (!audio.id.startsWith('dummy-track')) return false;
          final date = DateTime.fromMillisecondsSinceEpoch(audio.timestamp);
          return DateTime(
            date.year,
            date.month,
            date.day,
          ).isAtSameMomentAs(today);
        }) ??
        false;

    if (hasRecentDummyTracks ||
        (local.totalTracksCompleted == 0 && remote.totalTracksCompleted > 0)) {
      return remote.copyWith(updated: updated);
    }
    if (remote.totalTracksCompleted == 0 && local.totalTracksCompleted > 0) {
      return local.copyWith(updated: updated);
    }

    // Si la sesión está en ambas copias, conserva la del servidor.
    final sessions = {
      for (final audio in [...?local.audioCompleted, ...?remote.audioCompleted])
        '${audio.id}_${audio.timestamp}': audio,
    }.values.toList();
    // Las entradas manuales antiguas y de pausa de racha no cuentan aquí.
    final realCompletions = sessions
        .where(
          (audio) =>
              audio.id != TypeConstants.streakFreeze &&
              !audio.id.startsWith('dummy-track'),
        )
        .length;
    final base = remote.updated > local.updated ? remote : local;

    return base.copyWith(
      audioCompleted: sessions,
      freezeUsageDates: {
        ...local.freezeUsageDates,
        ...remote.freezeUsageDates,
      }.toList(),
      tracksChecked: {
        ...?local.tracksChecked,
        ...?remote.tracksChecked,
      }.toList(),
      totalTracksCompleted: max(
        realCompletions,
        max(local.totalTracksCompleted, remote.totalTracksCompleted),
      ),
      totalTimeListened: max(local.totalTimeListened, remote.totalTimeListened),
      streakLongest: max(local.streakLongest, remote.streakLongest),
      updated: updated,
    );
  }

  // Conserva el cálculo histórico que usa el servidor.
  LocalAllStats calculateStreak(LocalAllStats allStats) {
    final offset = _dayBoundaryOffset;
    final now = _getCurrentDate();
    final today = dayOf(now, offset);
    var longestStreak = allStats.streakLongest;

    // Any day with an entry (real session, freeze audio entry, or legacy
    // freeze date) counts toward the streak. The freeze feature is retired, so
    // we no longer distinguish freeze vs real — preserving legacy streaks for
    // users who accrued them under the old "freeze = +1" rule.
    final activityDates = <DateTime>{};

    for (final entry in allStats.audioCompleted ?? []) {
      final date = DateTime.fromMillisecondsSinceEpoch(entry.timestamp);
      final day = dayOf(date, offset);
      if (day.isAfter(today)) continue;
      activityDates.add(day);
    }

    for (final ts in allStats.freezeUsageDates) {
      final date = DateTime.fromMillisecondsSinceEpoch(ts);
      final day = dayOf(date, offset);
      if (!day.isAfter(today)) activityDates.add(day);
    }

    if (activityDates.isEmpty) {
      return allStats.copyWith(streakCurrent: 0, streakLongest: longestStreak);
    }

    final yesterday = DateTime(today.year, today.month, today.day - 1);
    final hasActivityToday = activityDates.contains(today);
    final hasActivityYesterday = activityDates.contains(yesterday);

    if (!hasActivityToday && !hasActivityYesterday) {
      return allStats.copyWith(streakCurrent: 0, streakLongest: longestStreak);
    }

    var streak = hasActivityToday ? 1 : 0;
    var checkDate = yesterday;

    while (activityDates.contains(checkDate)) {
      streak++;
      checkDate = DateTime(checkDate.year, checkDate.month, checkDate.day - 1);
    }

    if (streak > longestStreak) longestStreak = streak;

    return allStats.copyWith(
      streakCurrent: streak,
      streakLongest: longestStreak,
    );
  }

  Map<String, dynamic>? _readStatsRecord(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>?;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  void _loadSyncState() {
    final record = _readStatsRecord(SharedPreferenceConstants.localAllStatsKey);
    final savedUserId = record?.containsKey(_ownerKey) == true
        ? record![_ownerKey] as String?
        : _prefs.getString(SharedPreferenceConstants.serverUserId);
    if (savedUserId != null && _uuidPattern.hasMatch(savedUserId)) {
      _verifiedUserId = savedUserId;
    }
    _loadRecordState(record);
    _historyIdOnDisk = _historyId != null;
    if (_verifiedUserId != null &&
        _legacyPending == null &&
        record?.containsKey(_changesKey) == false &&
        !_dirty &&
        _localSeq > 0) {
      _synced = (stats: _loadLocalAllStats(), clientSeq: _localSeq);
    }
  }

  void _loadRecordState(Map<String, dynamic>? record) => _restoreState(
    _readRecordState(record, stats: _allStats, owner: _verifiedUserId),
  );

  _MemoryState _readRecordState(
    Map<String, dynamic>? record, {
    required LocalAllStats? stats,
    required String? owner,
    bool archived = false,
  }) {
    final dirty =
        record?[_pendingSyncKey] == true ||
        (archived && record != null && !record.containsKey(_pendingSyncKey));
    final attempt = record?[_attemptKey] as Map<String, dynamic>?;
    final legacy = record?[_legacyPendingKey] as Map<String, dynamic>?;
    final synced = record?[_syncedStatsKey] as Map<String, dynamic>?;
    final historyId = record?[_historyIdKey];
    return (
      allStats: stats,
      verifiedUserId: owner,
      localSeq: record?[_localSeqKey] as int? ?? 0,
      dirty: dirty,
      needsResync: record?[_resyncKey] == true,
      attempt: attempt == null
          ? null
          : (
              seq: attempt['seq'] as int,
              changes: attempt['changes'] as int,
              digest: attempt['digest'] as String,
            ),
      legacyPending: legacy != null
          ? LocalAllStats.fromJson(legacy)
          : record != null &&
                !record.containsKey(_changesKey) &&
                (dirty || record.containsKey('stats'))
          ? LocalAllStats.fromJson(
              record['stats'] as Map<String, dynamic>? ?? record,
            )
          : null,
      synced: synced == null
          ? null
          : (
              stats: LocalAllStats.fromJson(synced),
              clientSeq: record![_syncedSeqKey] as int,
            ),
      changes: [
        for (final change in (record?[_changesKey] as List? ?? const []))
          StatsChange(change as Map<String, dynamic>),
      ],
      recordedRuns: _readRecordedRuns(record),
      historyId: historyId is String && historyId.isNotEmpty ? historyId : null,
      historyIdOnDisk: false,
    );
  }

  static String _newHistoryId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  static List<Map<String, dynamic>> _readRecordedRuns(
    Map<String, dynamic>? record,
  ) => [
    for (final run in (record?[_recordedRunsKey] as List? ?? const []))
      if (run is Map && run['runId'] is String)
        Map<String, dynamic>.of(run.cast()),
  ];

  Map<String, dynamic> _recordState(
    _MemoryState state,
    String historyId, {
    List<Map<String, dynamic>>? recordedRuns,
    int? localSeq,
    bool? dirty,
    List<StatsChange>? changes,
  }) => {
    _ownerKey: state.verifiedUserId,
    _localSeqKey: localSeq ?? state.localSeq,
    _pendingSyncKey: dirty ?? state.dirty,
    _resyncKey: state.needsResync,
    if (state.attempt case final attempt?)
      _attemptKey: {
        'seq': attempt.seq,
        'changes': attempt.changes,
        'digest': attempt.digest,
      },
    if (state.synced case final synced?) ...{
      _syncedStatsKey: synced.stats.toJson(),
      _syncedSeqKey: synced.clientSeq,
    },
    if (state.legacyPending case final legacy?)
      _legacyPendingKey: legacy.toJson(),
    _changesKey: [for (final change in changes ?? state.changes) change.json],
    _recordedRunsKey: recordedRuns ?? state.recordedRuns,
    _historyIdKey: historyId,
  };

  /// Una sola escritura guarda el historial y el estado de sincronización.
  /// Con [stats], [recordedRuns], [localSeq], [dirty] o [changes] se escriben
  /// esas copias; la memoria las recibe quien llama, solo después de
  /// confirmar el guardado (TIMER-03, TMR-04).
  Future<void> _saveLocalAllStatsToSharedPrefs({
    LocalAllStats? stats,
    List<Map<String, dynamic>>? recordedRuns,
    int? localSeq,
    bool? dirty,
    List<StatsChange>? changes,
  }) async {
    _historyId = await _writeActiveRecord(
      _captureState(),
      stats: stats,
      recordedRuns: recordedRuns,
      localSeq: localSeq,
      dirty: dirty,
      changes: changes,
    );
    _historyIdOnDisk = true;
  }

  Future<String> _writeActiveRecord(
    _MemoryState state, {
    LocalAllStats? stats,
    List<Map<String, dynamic>>? recordedRuns,
    int? localSeq,
    bool? dirty,
    List<StatsChange>? changes,
  }) async {
    final historyId = state.historyId ?? _newHistoryId();
    final saved = await _prefs.setString(
      SharedPreferenceConstants.localAllStatsKey,
      jsonEncode({
        ...(stats ?? state.allStats!).toJson(),
        ..._recordState(
          state,
          historyId,
          recordedRuns: recordedRuns,
          localSeq: localSeq,
          dirty: dirty,
          changes: changes,
        ),
      }),
    );
    if (!saved) throw StateError('Could not save local stats');
    return historyId;
  }

  LocalAllStats _loadLocalAllStats() {
    final record = _readStatsRecord(SharedPreferenceConstants.localAllStatsKey);
    return record == null
        ? LocalAllStats.empty()
        : LocalAllStats.fromJson(record);
  }

  /// Copias guardadas de otras cuentas y el historial sin dueño. Se leen de
  /// la última escritura CONFIRMADA, no de la caché de SharedPreferences, que
  /// cambia aunque la escritura falle. Las entradas sin dueño se juntan en una.
  List<Map<String, dynamic>> _pendingOwners() {
    final confirmed = _confirmedOwners ??= _readPendingOwners();
    final owners = <Map<String, dynamic>>[];
    Map<String, dynamic>? ownerless;
    for (final owner in _deepCopy(confirmed)) {
      if (owner[_ownerKey] != null) {
        owners.add(owner);
      } else {
        ownerless = ownerless == null
            ? owner
            : _mergeOwnerless(ownerless, owner);
      }
    }
    return [...owners, ?ownerless];
  }

  List<Map<String, dynamic>> _readPendingOwners() {
    final record = _readStatsRecord(_pendingOwnerKey);
    if (record == null) return [];
    final others = record.remove('other_owners') as List? ?? [];
    return [record, ...others.cast<Map<String, dynamic>>()];
  }

  static List<Map<String, dynamic>> _deepCopy(
    List<Map<String, dynamic>> owners,
  ) => (jsonDecode(jsonEncode(owners)) as List).cast<Map<String, dynamic>>();

  Future<void> _writePendingOwners(List<Map<String, dynamic>> owners) async {
    final saved = owners.isEmpty
        ? await _prefs.remove(_pendingOwnerKey)
        : await _prefs.setString(
            _pendingOwnerKey,
            jsonEncode({
              ...owners.first,
              'other_owners': owners.skip(1).toList(),
            }),
          );
    if (!saved) throw StateError('Could not preserve pending stats');
  }

  Future<void> _savePendingOwners(List<Map<String, dynamic>> owners) async {
    await _writePendingOwners(owners);
    _confirmedOwners = _deepCopy(owners);
  }

  /// Agrega [entry] a la lista; si no tiene dueño, lo junta con el único
  /// historial sin dueño (nunca hay dos).
  List<Map<String, dynamic>> _withPendingOwner(
    List<Map<String, dynamic>> owners,
    Map<String, dynamic> entry,
  ) {
    if (entry[_ownerKey] != null) {
      return [
        for (final owner in owners)
          if (owner[_ownerKey] != entry[_ownerKey]) owner,
        entry,
      ];
    }
    final index = owners.indexWhere((owner) => owner[_ownerKey] == null);
    if (index < 0) return [...owners, entry];
    return [
      for (var i = 0; i < owners.length; i++)
        if (i != index) owners[i],
      _mergeOwnerless(owners[index], entry),
    ];
  }

  /// Aporte de cada historial a una copia sin dueño: minutos y número de
  /// cambios locales, por su identificador (REV-09).
  static Map<String, Map<String, dynamic>> _historyContributions(
    Map<String, dynamic> entry,
  ) {
    final listed = entry[_archivedHistoriesKey];
    if (listed is Map) {
      return {
        for (final item in listed.entries)
          if (item.key is String && item.value is Map)
            item.key as String: Map<String, dynamic>.of(
              (item.value as Map).cast(),
            ),
      };
    }
    final id = entry[_historyIdKey];
    if (id is! String || id.isEmpty) return {};
    final stats = LocalAllStats.fromJson(
      entry['stats'] as Map<String, dynamic>? ?? const {},
    );
    return {
      id: {
        'time': stats.totalTimeListened,
        'seq': entry[_localSeqKey] as int? ?? 0,
      },
    };
  }

  /// Quita de [older] los cambios que [newer] repite (el mismo historial
  /// archivado otra vez solo agrega cambios al final).
  static List<Object?> _changesWithoutRepeats(List older, List newer) {
    final repeated = <String, int>{};
    for (final change in newer) {
      final key = jsonEncode(change);
      repeated[key] = (repeated[key] ?? 0) + 1;
    }
    return [
      for (final change in older)
        if (() {
          final key = jsonEncode(change);
          final left = repeated[key] ?? 0;
          if (left == 0) return true;
          repeated[key] = left - 1;
          return false;
        }())
          change,
    ];
  }

  /// Junta dos historiales sin dueño sin repetir sesiones ni `runId`. Si
  /// [newer] es otra copia de un historial que [older] ya incluye (la
  /// verificación se cortó entre sus dos escrituras), reemplaza su aporte en
  /// vez de sumarlo otra vez: repetir el archivado da el mismo resultado
  /// (REV-09).
  Map<String, dynamic> _mergeOwnerless(
    Map<String, dynamic> older,
    Map<String, dynamic> newer,
  ) {
    LocalAllStats statsOf(Map<String, dynamic> entry) => LocalAllStats.fromJson(
      entry['stats'] as Map<String, dynamic>? ?? const {},
    );
    final a = statsOf(older);
    final b = statsOf(newer);
    final olderHistories = _historyContributions(older);
    final newerHistories = _historyContributions(newer);
    var repeatedTime = 0;
    var repeatedSeq = 0;
    for (final id in newerHistories.keys) {
      final previous = olderHistories[id];
      if (previous == null) continue;
      repeatedTime += previous['time'] as int? ?? 0;
      repeatedSeq += previous['seq'] as int? ?? 0;
    }
    final seen = <String>{};
    var duplicated = 0;
    final completed = <LocalAudioCompleted>[];
    for (final session in [...?a.audioCompleted, ...?b.audioCompleted]) {
      if (seen.add('${session.id}@${session.timestamp}')) {
        completed.add(session);
      } else {
        duplicated++;
      }
    }
    var merged = a.copyWith(
      audioCompleted: completed,
      totalTimeListened: max(
        0,
        a.totalTimeListened + b.totalTimeListened - repeatedTime,
      ),
      totalTracksCompleted: max(
        0,
        a.totalTracksCompleted + b.totalTracksCompleted - duplicated,
      ),
      tracksChecked: {...?a.tracksChecked, ...?b.tracksChecked}.toList(),
      updated: max(a.updated, b.updated),
    );
    merged = calculateStreak(merged);
    merged = merged.copyWith(
      consistencyScore: calculateConsistencyScore(merged),
    );
    final runIds = <String>{};
    final olderChanges = older[_changesKey] as List? ?? const [];
    final newerChanges = newer[_changesKey] as List? ?? const [];
    return {
      ...newer,
      _ownerKey: null,
      'stats': jsonDecode(jsonEncode(merged.toJson())),
      _localSeqKey: max(
        0,
        (older[_localSeqKey] as int? ?? 0) +
            (newer[_localSeqKey] as int? ?? 0) -
            repeatedSeq,
      ),
      _pendingSyncKey: true,
      _changesKey: [
        ...(repeatedTime > 0 || repeatedSeq > 0
            ? _changesWithoutRepeats(olderChanges, newerChanges)
            : olderChanges),
        ...newerChanges,
      ],
      _recordedRunsKey: [
        for (final run in [
          ..._readRecordedRuns(older),
          ..._readRecordedRuns(newer),
        ])
          if (runIds.add(run['runId'] as String)) run,
      ],
      _archivedHistoriesKey: {...olderHistories, ...newerHistories},
    };
  }

  /// Copia del historial activo para archivarla. Antes se asegura de que el
  /// registro activo en disco guarde su identificador: si el proceso muere
  /// después de archivar, el siguiente intento reconoce la misma copia
  /// (REV-09).
  Future<Map<String, dynamic>?> _archiveActiveStats() async {
    if (!_dirty && (_verifiedUserId == null || _synced == null)) return null;
    _allStats ??= _loadLocalAllStats();
    if (!_historyIdOnDisk) await _saveLocalAllStatsToSharedPrefs();
    // Copia en JSON puro: la unión con otra copia sin dueño la vuelve a leer.
    return {
      ..._recordState(_captureState(), _historyId!),
      'stats': jsonDecode(jsonEncode(_allStats!.toJson())),
    };
  }

  Future<void> _ensureStatsLoaded() async {
    if (!_isInitialized) await initialize();
    _allStats ??= _loadLocalAllStats();
  }

  /// Racha y constancia calculadas sobre una copia: la memoria no cambia.
  LocalAllStats _withDerivedStats(LocalAllStats stats) {
    final withStreak = calculateStreak(stats);
    return withStreak.copyWith(
      consistencyScore: calculateConsistencyScore(withStreak),
    );
  }

  /// Guarda un cambio local en una sola escritura. Se llama dentro del candado;
  /// el envío al servidor lo hace quien llama, ya fuera del candado.
  ///
  /// [stats] es la copia ya calculada del historial nuevo. Todo se escribe
  /// desde copias y la memoria las publica solo cuando el guardado se
  /// confirmó: una lectura durante la espera (por ejemplo `returns`) nunca ve
  /// una sesión que luego puede no guardarse (TMR-04).
  Future<void> _commitLocalChange({
    StatsChange? change,
    LocalAllStats? stats,
    double? score,
    List<Map<String, dynamic>>? recordedRuns,
  }) async {
    final generation = _clearGeneration;
    final localSeq = _localSeq + 1;
    final changes = change == null ? _changes : [..._changes, change];
    await _saveLocalAllStatsToSharedPrefs(
      stats: stats,
      recordedRuns: recordedRuns,
      localSeq: localSeq,
      dirty: true,
      changes: changes,
    );
    _localSeq = localSeq;
    _dirty = true;
    _changes = changes;
    if (stats != null) _allStats = stats;
    // Las marcas de Salud se publican solo con el guardado confirmado.
    if (recordedRuns != null) _recordedRuns = recordedRuns;
    if (generation != _clearGeneration) return;
    if (score != null) await saveConsistencyScoreHistory(score);
  }

  void _updateHomeWidget() {
    final stats = _allStats;
    if (stats != null) HomeWidgetService.updateWidgetFromStats(stats).ignore();
  }

  Future<void> addAudioCompleted(
    LocalAudioCompleted audioCompleted,
    int duration, {
    bool skipPost = false,
  }) async {
    final generation = _clearGeneration;
    if (!_isInitialized) {
      await initialize();
    }
    await _ensureStatsLoaded();
    final saved = await _transaction(() async {
      if (generation != _clearGeneration) return false;
      _allStats ??= _loadLocalAllStats();
      final change = _completionChange(audioCompleted, duration);
      final stats = _withDerivedStats(_applyCompletion(_allStats!, change));
      await _commitLocalChange(
        change: change,
        stats: stats,
        score: stats.consistencyScore,
      );
      if (generation == _clearGeneration) {
        _rememberPracticeDay(change, completedAt: audioCompleted.timestamp);
      }
      return true;
    });
    if (!saved || skipPost || generation != _clearGeneration) return;
    await flushPendingPost();
    _updateHomeWidget();
  }

  /// Cambio de una sesión terminada; si cruzó el inicio del día de la persona
  /// (medianoche más su desfase) cuenta en el día en que empezó.
  StatsChange _completionChange(
    LocalAudioCompleted audioCompleted,
    int duration,
  ) {
    if (AudioCompletionTracker.checkTrackCrossedMidnight(
      endTimestamp: audioCompleted.timestamp,
      duration: duration,
      dayBoundaryOffset: _dayBoundaryOffset,
    )) {
      audioCompleted = audioCompleted.copyWith(
        timestamp: audioCompleted.timestamp - duration,
      );
    }
    return StatsChange.completion(audioCompleted, duration);
  }

  LocalAllStats _applyCompletion(LocalAllStats stats, StatsChange change) =>
      change.apply(stats, _getCurrentDate().millisecondsSinceEpoch);

  /// Publica el día de práctica (y el «regreso») de una sesión nueva. Se
  /// llama solo DESPUÉS de confirmar el guardado de la sesión: si el guardado
  /// falla, no queda un regreso sin su sesión (TIMER-REVIEW-04).
  void _rememberPracticeDay(StatsChange change, {required int completedAt}) {
    final stats = _allStats;
    if (stats == null) return;
    try {
      PracticeHistory.read(
        stats,
        prefs: _prefs,
        now: _getCurrentDate(),
        offset: _dayBoundaryOffset,
        storedSession: LocalAudioCompleted.fromJson(
          change.json['session'] as Map<String, dynamic>,
        ),
        completedAt: completedAt,
      );
    } catch (error) {
      // La sesión ya quedó guardada; el historial se repone en la siguiente
      // lectura.
      AppLogger.e(
        'STATS_MANAGER',
        'No se pudo anotar el día de práctica',
        error,
      );
    }
  }

  /// Guarda una sesión del temporizador una sola vez por su `runId`, en el
  /// historial de su dueño (R77): la cuenta activa, o el historial de antes de
  /// verificar cuando la sesión empezó sin cuenta. Una sesión de otra cuenta
  /// verificada se rechaza sin escribir nada.
  Future<TimerRecordResult> recordTimerRun(Map<String, dynamic> payload) async {
    final runId = payload[TypeConstants.runIdKey] as String?;
    if (runId == null || runId.isEmpty) return TimerRecordResult.rejected;
    final ownerId = payload[timerOwnerIdKey] as String? ?? '';
    final generation = _clearGeneration;
    try {
      await initialize();
      await _ensureStatsLoaded();
    } catch (error) {
      AppLogger.e('STATS_MANAGER', 'No se pudo abrir el historial', error);
      return TimerRecordResult.failed;
    }
    final completion = LocalAudioCompleted(
      id: payload[TypeConstants.trackIdKey] as String,
      timestamp: payload[TypeConstants.timestampIdKey] as int,
    );
    final duration = payload[TypeConstants.durationIdKey] as int;
    final endMs = completion.timestamp;
    TimerRecordResult result;
    try {
      result = await _transaction(() async {
        if (generation != _clearGeneration) return TimerRecordResult.failed;
        _allStats ??= _loadLocalAllStats();
        final current = _verifiedUserId ?? '';
        if (ownerId == current) {
          if (_recordedRuns.any((run) => run['runId'] == runId)) {
            return TimerRecordResult.duplicate;
          }
          final change = _completionChange(completion, duration);
          // La sesión se calcula en una copia: la memoria la publica solo
          // cuando el guardado se confirmó (TMR-04).
          final stats = _withDerivedStats(
            _applyCompletion(_allStats!, change),
          );
          // La marca de Salud viaja en la MISMA escritura, pero la memoria
          // solo la publica cuando el guardado se confirmó (TIMER-03).
          final runs = _appendRun(_recordedRuns, {
            'runId': runId,
            if (ownerId.isNotEmpty)
              'healthPending': {
                'startMs': endMs - duration,
                'endMs': endMs,
                'accountId': ownerId,
              },
          });
          await _commitLocalChange(
            change: change,
            stats: stats,
            score: stats.consistencyScore,
            recordedRuns: runs,
          );
          if (generation == _clearGeneration) {
            _rememberPracticeDay(change, completedAt: endMs);
          }
          return TimerRecordResult.accepted;
        }
        if (ownerId.isNotEmpty) {
          AppLogger.w(
            'STATS_MANAGER',
            'Sesión $runId de otra cuenta; no se guarda',
          );
          return TimerRecordResult.rejected;
        }
        return _recordPreVerificationRun(runId, completion, duration);
      });
    } catch (error) {
      AppLogger.e('STATS_MANAGER', 'No se pudo guardar la sesión', error);
      return TimerRecordResult.failed;
    }
    if ((result == TimerRecordResult.accepted ||
            result == TimerRecordResult.duplicate) &&
        generation == _clearGeneration) {
      _confirmedRuns.add(runId);
    }
    if (result == TimerRecordResult.accepted &&
        ownerId == (_verifiedUserId ?? '') &&
        generation == _clearGeneration) {
      flushPendingPost().ignore();
      _updateHomeWidget();
    }
    return result;
  }

  /// Verdadero cuando el historial ya tiene guardada la sesión [runId] (la
  /// cuenta activa o el historial de antes de verificar). Si aún no está,
  /// espera como máximo [timeout] a que llegue. Falso = el guardado sigue
  /// pendiente: nadie debe decir «Guardamos tu sesión» (END-01).
  Future<bool> confirmTimerRun(
    String runId, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (runId.isEmpty || _changingAccount) return false;
    if (_hasRecordedRun(runId)) return true;
    // Se escucha en el mismo paso que la consulta: ningún aviso se pierde.
    final generation = _clearGeneration;
    final arrived = Completer<bool>();
    final subscription = _confirmedRuns.stream.listen((id) {
      if (arrived.isCompleted) return;
      if (id == null || generation != _clearGeneration || _changingAccount) {
        arrived.complete(false);
      } else if (id == runId) {
        arrived.complete(true);
      }
    });
    try {
      return await arrived.future.timeout(
        timeout,
        onTimeout: () =>
            generation == _clearGeneration &&
            !_changingAccount &&
            _hasRecordedRun(runId),
      );
    } finally {
      await subscription.cancel();
    }
  }

  bool _hasRecordedRun(String runId) {
    if (_recordedRuns.any((run) => run['runId'] == runId)) return true;
    if (!_isInitialized) return false;
    try {
      return _pendingOwners().any(
        (owner) =>
            owner[_ownerKey] == null &&
            _readRecordedRuns(owner).any((run) => run['runId'] == runId),
      );
    } catch (_) {
      AppLogger.w('STATS_MANAGER', 'No se pudo leer el historial previo');
      return false;
    }
  }

  /// Escribe la sesión en el historial de antes de verificar (la copia
  /// archivada sin dueño), sin mezclarla con la cuenta. Una sola escritura.
  Future<TimerRecordResult> _recordPreVerificationRun(
    String runId,
    LocalAudioCompleted completion,
    int duration,
  ) async {
    final owners = _pendingOwners();
    final index = owners.indexWhere((owner) => owner[_ownerKey] == null);
    final entry = index < 0
        ? <String, dynamic>{
            _ownerKey: null,
            _localSeqKey: 0,
            _pendingSyncKey: true,
            _changesKey: <Object>[],
            'stats': LocalAllStats.empty().toJson(),
          }
        : Map<String, dynamic>.of(owners[index]);
    final runs = _readRecordedRuns(entry);
    if (runs.any((run) => run['runId'] == runId)) {
      return TimerRecordResult.duplicate;
    }
    final change = _completionChange(completion, duration);
    final stats = LocalAllStats.fromJson(
      entry['stats'] as Map<String, dynamic>? ?? const {},
    );
    var updated = change.apply(stats, _getCurrentDate().millisecondsSinceEpoch);
    updated = calculateStreak(updated);
    updated = updated.copyWith(
      consistencyScore: calculateConsistencyScore(updated),
    );
    entry['stats'] = updated.toJson();
    entry[_localSeqKey] = (entry[_localSeqKey] as int? ?? 0) + 1;
    entry[_pendingSyncKey] = true;
    entry[_changesKey] = [
      ...(entry[_changesKey] as List? ?? const []),
      change.json,
    ];
    entry[_recordedRunsKey] = _appendRun(runs, {'runId': runId});
    final next = List.of(owners);
    if (index < 0) {
      next.add(entry);
    } else {
      next[index] = entry;
    }
    await _savePendingOwners(next);
    return TimerRecordResult.accepted;
  }

  /// Agrega [run] y respeta el límite quitando los más viejos, pero nunca
  /// uno que aún espera su entrega a Salud.
  static List<Map<String, dynamic>> _appendRun(
    List<Map<String, dynamic>> runs,
    Map<String, dynamic> run,
  ) {
    final next = [...runs, run];
    var excess = next.length - _maxRecordedRuns;
    if (excess <= 0) return next;
    final kept = <Map<String, dynamic>>[];
    for (final entry in next) {
      if (excess > 0 &&
          !identical(entry, run) &&
          !entry.containsKey('healthPending')) {
        excess--;
        continue;
      }
      kept.add(entry);
    }
    return kept;
  }

  /// Sesiones de la cuenta activa que siguen pendientes de exportar a Salud.
  /// Se leen bajo el mismo candado del historial: nunca se ve la marca de un
  /// guardado que sigue en curso o que falló (TIMER-03).
  Future<List<HealthPendingRun>> healthPendingRuns() => _locked(
    () async => [
      for (final run in _recordedRuns)
        if (run['healthPending'] case {
          'startMs': final int startMs,
          'endMs': final int endMs,
          'accountId': final String accountId,
        })
          HealthPendingRun(
            runId: run['runId'] as String,
            startMs: startMs,
            endMs: endMs,
            accountId: accountId,
          ),
    ],
  );

  /// Quita la marca de Salud de [runId]; `false` si no se pudo guardar.
  Future<bool> clearHealthPending(String runId) async {
    await initialize();
    await _ensureStatsLoaded();
    try {
      return await _transaction(() async {
        final index = _recordedRuns.indexWhere(
          (run) => run['runId'] == runId && run.containsKey('healthPending'),
        );
        if (index < 0) return true;
        final runs = [
          for (var i = 0; i < _recordedRuns.length; i++)
            i == index
                ? (Map.of(_recordedRuns[i])..remove('healthPending'))
                : _recordedRuns[i],
        ];
        await _saveLocalAllStatsToSharedPrefs(recordedRuns: runs);
        _recordedRuns = runs;
        return true;
      });
    } catch (error) {
      AppLogger.e(
        'STATS_MANAGER',
        'No se pudo quitar la marca de Salud',
        error,
      );
      return false;
    }
  }

  /// Sesiones y minutos guardados en este teléfono antes de verificar la
  /// cuenta. Solo lectura; nunca se sincroniza ni se mezcla con la cuenta.
  Future<PreVerificationSummary?> preVerificationSummary() async {
    await initialize();
    if (_verifiedUserId == null) return null;
    final entry = _pendingOwners().firstWhere(
      (owner) => owner[_ownerKey] == null,
      orElse: () => const {},
    );
    final raw = entry['stats'];
    if (raw is! Map<String, dynamic>) return null;
    final stats = LocalAllStats.fromJson(raw);
    final sessions = (stats.audioCompleted ?? const <LocalAudioCompleted>[])
        .where(
          (session) =>
              session.id != TypeConstants.streakFreeze &&
              !session.id.startsWith('dummy-track'),
        )
        .length;
    if (sessions == 0) return null;
    return PreVerificationSummary(
      sessions: sessions,
      minutes: stats.totalTimeListened ~/ Duration.millisecondsPerMinute,
    );
  }

  /// Sesiones del historial de este teléfono antes de verificar la cuenta.
  Future<List<LocalAudioCompleted>> preVerificationCompletions() async {
    await initialize();
    final raw = _pendingOwners()
        .where((owner) => owner[_ownerKey] == null)
        .firstOrNull?['stats'];
    if (raw is! Map<String, dynamic>) return const [];
    return LocalAllStats.fromJson(raw).audioCompleted ?? const [];
  }

  /// Adds the listening time of a repeated play-through without recording a
  /// new session. See [AudioCompletionTracker.addRepeatListeningTime].
  Future<void> addRepeatListeningTime(int duration) async {
    final generation = _clearGeneration;
    if (!_isInitialized) {
      await initialize();
    }
    await _ensureStatsLoaded();
    final saved = await _transaction(() async {
      if (generation != _clearGeneration) return false;
      _allStats ??= _loadLocalAllStats();
      final change = StatsChange.repeat(duration);
      await _commitLocalChange(
        change: change,
        stats: change.apply(
          _allStats!,
          _getCurrentDate().millisecondsSinceEpoch,
        ),
      );
      return true;
    });
    if (!saved || generation != _clearGeneration) return;
    await flushPendingPost();
    _updateHomeWidget();
  }

  Future<void> flushPendingPost() {
    if (!_dirty ||
        _allStats == null ||
        _verifiedUserId == null ||
        _changingAccount) {
      return Future.value();
    }

    final generation = _clearGeneration;
    return _postsInFlight.putIfAbsent(
      generation,
      // El envío vive fuera del candado: solo sus escrituras lo toman.
      () =>
          runZoned(
            () => _postPendingChanges(generation),
            zoneValues: {_lockZoneKey: null},
          ).whenComplete(() {
            _postsInFlight.remove(generation);
          }),
    );
  }

  Future<void> _postPendingChanges(int generation) async {
    var retried = false;
    while (generation == _clearGeneration && _dirty && !_changingAccount) {
      if (_synced == null || _needsResync) {
        final startedSeq = _localSeq;
        final remote = await _statsService.fetchAllStats();
        if (generation != _clearGeneration) return;
        if (startedSeq != _localSeq) continue;
        if (remote == null) return;
        final rebased = await _locked(() async {
          if (generation != _clearGeneration || startedSeq != _localSeq) {
            return false;
          }
          await _rebasePendingChanges(remote);
          return true;
        });
        if (generation != _clearGeneration) return;
        if (!rebased) continue;
      }

      final attempt = await _transaction(() async {
        if (generation != _clearGeneration) return null;
        final sent = _allStats!;
        final seq = _localSeq;
        final changeCount = _changes.length;
        // Si se pierde la respuesta, el GET puede identificar el envío exacto.
        _attempt = (seq: seq, changes: changeCount, digest: _statsDigest(sent));
        _needsResync = true;
        await _saveLocalAllStatsToSharedPrefs();
        return (sent: sent, seq: seq, changeCount: changeCount);
      });
      if (attempt == null ||
          generation != _clearGeneration ||
          _changingAccount) {
        return;
      }
      final (:sent, :seq, :changeCount) = attempt;

      StatsPostResult? result;
      try {
        result = await _statsService.postStats(sent, clientSeq: seq);
      } catch (error) {
        AppLogger.e('STATS_MANAGER', 'Stats post failed', error);
      }
      if (generation != _clearGeneration || result == null) return;

      if (!result.applied) {
        if (retried) return;
        retried = true;
        continue;
      }
      if (result.clientSeq < seq) return;

      final accepted = result;
      final saved = await _transaction(() async {
        if (generation != _clearGeneration) return false;
        _synced = (stats: sent, clientSeq: accepted.clientSeq);
        _attempt = null;
        _needsResync = false;
        _changes.removeRange(0, changeCount);
        _dirty = seq != _localSeq;
        _legacyPending = null;
        if (accepted.clientSeq >= _localSeq) {
          _localSeq = accepted.clientSeq + (_dirty ? 1 : 0);
        }
        await _saveLocalAllStatsToSharedPrefs();
        await _markSynced();
        return true;
      });
      if (!saved || generation != _clearGeneration) return;
    }
  }

  String _statsDigest(LocalAllStats stats) {
    final wire = LocalAllStats.fromAllStats(stats.toAllStats()).toAllStats();
    return sha256.convert(utf8.encode(jsonEncode(wire.toJson()))).toString();
  }

  // Se llama dentro del candado.
  Future<void> _rebasePendingChanges(StatsSnapshot remote) async {
    final before = _captureState();
    final attempt = before.attempt;
    final changes = before.changes;
    var legacy = before.legacyPending;
    if (attempt != null &&
        attempt.seq == remote.clientSeq &&
        attempt.digest == _statsDigest(remote.stats)) {
      // El servidor ya guardó estos cambios. Conserva los que llegaron después.
      changes.removeRange(0, attempt.changes);
      legacy = null;
    }
    // Las versiones anteriores solo guardaban la copia sin el detalle de los cambios.
    var stats = legacy == null ? remote.stats : _merge(legacy, remote.stats);
    final now = _getCurrentDate().millisecondsSinceEpoch;
    for (final change in changes) {
      stats = change.apply(stats, now, replay: true);
    }
    final _MemoryState next = (
      allStats: _withDerivedStats(stats),
      localSeq: max(before.localSeq, remote.clientSeq + 1),
      dirty: before.dirty,
      needsResync: false,
      attempt: null,
      synced: remote,
      legacyPending: legacy,
      verifiedUserId: before.verifiedUserId,
      changes: changes,
      recordedRuns: before.recordedRuns,
      historyId: before.historyId,
      historyIdOnDisk: before.historyIdOnDisk,
    );
    final historyId = await _writeActiveRecord(next);
    _restoreState(next, savedHistoryId: historyId);
    _updateHomeWidget();
  }

  /// Replaces the current stats with the given snapshot, recalculates
  /// derived fields, persists locally, and syncs to the server.
  ///
  /// Used by the Settings → Advanced → Restore previous stats flow so a
  /// user who logged into a different account can recover an earlier
  /// snapshot taken from any account on this device.
  Future<void> restoreFromBackup(LocalAllStats snapshot) async {
    final generation = _clearGeneration;
    if (!_isInitialized) await initialize();
    final saved = await _transaction(() async {
      if (generation != _clearGeneration) return false;
      PracticeHistory.read(
        _allStats ?? _loadLocalAllStats(),
        prefs: _prefs,
        now: _getCurrentDate(),
        offset: _dayBoundaryOffset,
      );
      final change = StatsChange.restore(snapshot);
      final stats = _withDerivedStats(
        change.apply(snapshot, _getCurrentDate().millisecondsSinceEpoch),
      );
      await _commitLocalChange(
        change: change,
        stats: stats,
        score: stats.consistencyScore,
      );
      return true;
    });
    if (!saved || generation != _clearGeneration) return;
    await flushPendingPost();
    _updateHomeWidget();
  }

  Future<void> removeAudioCompleted(LocalAudioCompleted session) async {
    final generation = _clearGeneration;
    await _ensureStatsLoaded();
    final saved = await _transaction(() async {
      if (generation != _clearGeneration) return false;
      _allStats ??= _loadLocalAllStats();
      PracticeHistory.read(
        _allStats!,
        prefs: _prefs,
        now: _getCurrentDate(),
        offset: _dayBoundaryOffset,
      );
      final change = StatsChange.remove(session);
      final updated = change.apply(
        _allStats!,
        _getCurrentDate().millisecondsSinceEpoch,
      );
      if (identical(updated, _allStats)) return false;
      final stats = _withDerivedStats(updated);
      await _commitLocalChange(
        change: change,
        stats: stats,
        score: stats.consistencyScore,
      );
      return true;
    });
    if (!saved || generation != _clearGeneration) return;
    await flushPendingPost();
    _updateHomeWidget();
  }

  Future<void> addTrackChecked(String? id) async {
    assert(id != null, 'Track ID cannot be null');
    await setTracksChecked([id!], checked: true);
  }

  Future<void> setTracksChecked(
    List<String> ids, {
    required bool checked,
  }) async {
    final generation = _clearGeneration;
    await _ensureStatsLoaded();
    final saved = await _transaction(() async {
      if (generation != _clearGeneration) return false;
      _allStats ??= _loadLocalAllStats();
      final change = StatsChange.check(ids, checked);
      final updated = change.apply(
        _allStats!,
        _getCurrentDate().millisecondsSinceEpoch,
      );
      if (identical(updated, _allStats)) return false;
      await _commitLocalChange(change: change, stats: updated);
      return true;
    });
    if (!saved || generation != _clearGeneration) return;
    await flushPendingPost();
  }

  Future<void> removeTrackChecked(String trackId) =>
      setTracksChecked([trackId], checked: false);

  Future<void> _writeServerUserId(String? userId) async {
    const key = SharedPreferenceConstants.serverUserId;
    final saved = userId == null
        ? await _prefs.remove(key)
        : await _prefs.setString(key, userId);
    if (!saved) throw StateError('Could not save the stats owner');
  }

  Future<void> acceptServerUser(String userId) async {
    final generation = _clearGeneration;
    await initialize();
    final accepted = await _locked(() async {
      if (generation != _clearGeneration ||
          _prefs.getBool(SharedPreferenceConstants.isLoggedIn) != true ||
          !_uuidPattern.hasMatch(userId)) {
        return null;
      }
      if (_verifiedUserId == userId) {
        // Repara la otra preferencia si el proceso se cerró entre escrituras.
        if (_prefs.getString(SharedPreferenceConstants.serverUserId) !=
            userId) {
          await _writeServerUserId(userId);
        }
        return null;
      }

      _changingAccount = true;
      // Invalida los envíos de la cuenta anterior mientras cambia el dueño.
      _clearGeneration++;
      _confirmedRuns.add(null);
      try {
        _allStats ??= _loadLocalAllStats();
        final active = await _archiveActiveStats();
        final owners = _pendingOwners();
        // Solo /me puede confirmar el UUID de una copia guardada.
        final matching = owners
            .where((owner) => owner[_ownerKey] == userId)
            .firstOrNull;
        final next = _readRecordState(
          matching,
          stats: matching == null
              ? LocalAllStats.empty()
              : LocalAllStats.fromJson(
                  matching['stats'] as Map<String, dynamic>,
                ),
          owner: userId,
          archived: true,
        );
        final archivedOwners = active == null
            ? owners
            : _withPendingOwner(owners, active);
        if (active != null) await _writePendingOwners(archivedOwners);

        // Guarda el dueño anterior en el registro si era de una versión vieja.
        // Así, un reinicio entre escrituras aún puede identificar el historial.
        final currentRecord = _readStatsRecord(
          SharedPreferenceConstants.localAllStatsKey,
        );
        if (currentRecord?.containsKey(_ownerKey) != true) {
          await _saveLocalAllStatsToSharedPrefs();
        }

        final previousUser = _prefs.getString(
          SharedPreferenceConstants.serverUserId,
        );
        final String historyId;
        try {
          await _writeServerUserId(userId);
          if (!await _saveLastSyncedAt(null)) {
            throw StateError('Could not clear the stats sync date');
          }
          historyId = await _writeActiveRecord(next);
        } catch (_) {
          try {
            await _writeServerUserId(previousUser);
          } catch (error) {
            AppLogger.e(
              'STATS_MANAGER',
              'No se pudo restaurar el dueño anterior',
              error,
            );
          }
          await _saveLastSyncedAt(_lastSyncedAt);
          rethrow;
        }

        var confirmedOwners = archivedOwners;
        if (matching != null) {
          final remaining = [
            for (final owner in archivedOwners)
              if (owner[_ownerKey] != userId) owner,
          ];
          try {
            await _writePendingOwners(remaining);
            confirmedOwners = remaining;
          } catch (error) {
            // El historial activo ya se guardó. La copia extra sigue en disco.
            AppLogger.e(
              'STATS_MANAGER',
              'No se pudo quitar la copia archivada',
              error,
            );
          }
        }
        _confirmedOwners = confirmedOwners;
        _restoreState(next, savedHistoryId: historyId);
        _lastSyncedAt = null;
        // También invalida las operaciones que llegaron durante el cambio.
        return ++_clearGeneration;
      } finally {
        _changingAccount = false;
      }
    });
    if (accepted != null && accepted == _clearGeneration) {
      flushPendingPost().ignore();
    }
  }

  Future<void> clearAllStats({bool preservePending = true}) async {
    await initialize();
    await _transaction(() async {
      _changingAccount = true;
      _clearGeneration++;
      _confirmedRuns.add(null);
      try {
        final active = preservePending ? await _archiveActiveStats() : null;
        _verifiedUserId = null;
        _allStats = LocalAllStats.empty();
        _loadRecordState(null);
        _lastSyncedAt = null;
        if (active != null) {
          await _savePendingOwners(_withPendingOwner(_pendingOwners(), active));
        }

        await _saveLocalAllStatsToSharedPrefs();
        if (!preservePending) await _savePendingOwners([]);
        await _prefs.remove(SharedPreferenceConstants.serverUserId);
        await _saveLastSyncedAt(null);
      } finally {
        _changingAccount = false;
      }
    });
  }

  bool get isInitialized => _isInitialized;

  /// Cuenta verificada dueña del historial activo, o null sin verificar.
  String? get verifiedUserId => _verifiedUserId;

  int get localGeneration => _clearGeneration;

  Future<bool> hasLocalStats() async {
    if (!_isInitialized) {
      await initialize();
    }
    _allStats ??= _loadLocalAllStats();

    return _allStats?.audioCompleted?.isNotEmpty == true;
  }

  // ⚠️ KEEP IN SYNC: ported to Kotlin in
  // android/app/src/main/kotlin/meditofoundation/medito/widget/ConsistencyWidget.kt
  // (calculateConsistencyScore) so the Android home-screen widget can recompute
  // the percentage on-device. If this algorithm changes, update that copy too.
  double calculateConsistencyScore(LocalAllStats allStats) {
    // MUST bucket days the same way `calculateStreak` does (via `dayOf` with
    // the day-boundary offset), otherwise the score and the calendar disagree
    // with the streak for users with a nonzero offset who meditate inside the
    // offset window.
    final offset = _dayBoundaryOffset;
    var now = _getCurrentDate();
    var today = dayOf(now, offset);

    if (allStats.audioCompleted == null || allStats.audioCompleted!.isEmpty) {
      return 0.0;
    }

    var audioDates = allStats.audioCompleted!.map((audio) {
      var date = DateTime.fromMillisecondsSinceEpoch(audio.timestamp);
      return dayOf(date, offset);
    }).toList();

    audioDates = audioDates
        .where((date) => !date.isAfter(today))
        .toSet()
        .toList();

    var freezeDates = allStats.freezeUsageDates.map((timestamp) {
      var date = DateTime.fromMillisecondsSinceEpoch(timestamp);
      return dayOf(date, offset);
    }).toList();

    freezeDates = freezeDates
        .where((date) => !date.isAfter(today) && !audioDates.contains(date))
        .toSet()
        .toList();

    var allActivityDates = {...audioDates, ...freezeDates}.toList();

    if (allActivityDates.isEmpty) {
      return 0.0;
    }

    allActivityDates.sort();
    var firstSessionDate = allActivityDates.first;
    // Días de calendario: un cambio de horario no quita ni suma un día.
    var daysSinceFirstSession =
        calendarDaysBetween(firstSessionDate, today) + 1;

    if (daysSinceFirstSession == 1) {
      return allActivityDates.any((date) => date.isAtSameMomentAs(today))
          ? 1.0
          : 0.0;
    }

    // Bootstrap phase: simple ratio for the first 30 days
    if (daysSinceFirstSession < 30) {
      return (allActivityDates.length / daysSinceFirstSession).clamp(0.0, 1.0);
    }

    // EMA phase: replay history day by day starting from day 30,
    // seeding with the ratio at day 29.
    const alpha = 0.1;
    const gracePenalty = 0.5; // value used for a single isolated missed day

    var day29 = addCalendarDays(firstSessionDate, 28);
    var activeDaysAtDay29 = allActivityDates
        .where((d) => !d.isAfter(day29))
        .length;
    var ema = activeDaysAtDay29 / 29.0;

    var day30 = addCalendarDays(firstSessionDate, 29);
    var currentDay = day30;

    while (!currentDay.isAfter(today)) {
      var hadActivity = allActivityDates.any(
        (d) =>
            d.year == currentDay.year &&
            d.month == currentDay.month &&
            d.day == currentDay.day,
      );

      double dayValue;
      if (hadActivity) {
        dayValue = 1.0;
      } else {
        var prevDay = addCalendarDays(currentDay, -1);
        var nextDay = addCalendarDays(currentDay, 1);
        var prevActive = allActivityDates.any(
          (d) =>
              d.year == prevDay.year &&
              d.month == prevDay.month &&
              d.day == prevDay.day,
        );
        var nextActive = nextDay.isAfter(today)
            ? false
            : allActivityDates.any(
                (d) =>
                    d.year == nextDay.year &&
                    d.month == nextDay.month &&
                    d.day == nextDay.day,
              );
        // Single isolated miss gets half penalty; consecutive misses get full penalty
        dayValue = (prevActive || nextActive) ? gracePenalty : 0.0;
      }

      ema = alpha * dayValue + (1 - alpha) * ema;
      currentDay = addCalendarDays(currentDay, 1);
    }

    return ema.clamp(0.0, 1.0);
  }

  // Test helpers
  @visibleForTesting
  void setStatsForTesting(LocalAllStats stats) {
    _allStats = stats;
  }

  @visibleForTesting
  void setPrefsForTesting(SharedPreferences prefs) {
    _prefs = prefs;
    _confirmedOwners = null;
  }

  @visibleForTesting
  void setStatsServiceForTesting(StatsService service) {
    _statsService = service;
  }

  @visibleForTesting
  LocalAllStats? get currentStats => _allStats;

  @visibleForTesting
  bool get hasTimerRunConfirmationListeners => _confirmedRuns.hasListener;

  void setCurrentDateForTesting(DateTime date) {
    _testDate = date;
  }

  /// Sets the day-boundary offset used by `calculateStreak` and persists it.
  /// `Duration.zero` (default) preserves legacy midnight behaviour.
  ///
  /// If stats are already loaded and the offset actually changed, the streak
  /// and consistency score are recomputed straight away. The calendar
  /// re-buckets from the raw sessions as soon as the offset changes, so
  /// leaving the stored streak until the next sync made the two disagree.
  Future<void> setDayBoundaryOffset(Duration offset) async {
    final changed = offset != _dayBoundaryOffset;
    _dayBoundaryOffset = offset;
    try {
      await _prefs.setInt(
        SharedPreferenceConstants.dayBoundaryOffsetHours,
        offset.inHours,
      );
    } catch (e) {
      AppLogger.e('STATS_MANAGER', 'Failed to persist day boundary offset', e);
    }

    if (!changed || _allStats == null) return;

    await _transaction(() async {
      if (_allStats == null) return;
      await _commitLocalChange(stats: _withDerivedStats(_allStats!));
    });
  }

  void _loadDayBoundaryOffset(SharedPreferences prefs) {
    try {
      final hours = prefs.getInt(
        SharedPreferenceConstants.dayBoundaryOffsetHours,
      );
      if (hours != null) _dayBoundaryOffset = Duration(hours: hours);
    } catch (e) {
      _dayBoundaryOffset = Duration.zero;
    }
  }

  Duration get dayBoundaryOffset => _dayBoundaryOffset;

  @visibleForTesting
  void setDayBoundaryOffsetForTesting(Duration offset) {
    _dayBoundaryOffset = offset;
  }

  @visibleForTesting
  void resetForTesting() {
    _allStats = null;
    _isInitialized = false;
    _initCompleter = null;
    _testDate = null;
    _lastSyncedAt = null;
    _clearGeneration++;
    _confirmedRuns.add(null);
    _changingAccount = false;
    _verifiedUserId = null;
    _loadRecordState(null);
    _postsInFlight.clear();
    _writeQueue = Future.value();
    _confirmedOwners = null;
    _dayBoundaryOffset = Duration.zero;
  }

  @visibleForTesting
  Future<void> setLastSyncedAtForTesting(DateTime? dateTime) async {
    _lastSyncedAt = dateTime;
    if (dateTime != null) {
      await _prefs.setInt(
        SharedPreferenceConstants.statsLastSyncedAt,
        dateTime.millisecondsSinceEpoch,
      );
    } else {
      await _prefs.remove(SharedPreferenceConstants.statsLastSyncedAt);
    }
  }

  DateTime _getCurrentDate() {
    return _testDate ?? DateTime.now();
  }

  /// Honours [setCurrentDateForTesting]. Callers outside of StatsManager
  /// should prefer this over `DateTime.now()` for any logic that interacts
  /// with stats (streak math, manual-session backfills, etc.) so tests can
  /// pin the clock.
  DateTime get currentDate => _getCurrentDate();

  // Test helpers
  @visibleForTesting
  Future<void> initializeForTesting({
    StatsService? statsService,
    bool requireVerifiedUser = false,
  }) async {
    if (!_isInitialized) {
      _prefs = await SharedPreferences.getInstance();
      _statsService =
          statsService ??
          StatsService(httpApiService: HttpApiService(), prefs: _prefs);
      await _loadLastSyncedAt(_prefs);
      _loadDayBoundaryOffset(_prefs);
      _loadSyncState();
      if (!requireVerifiedUser) {
        _verifiedUserId ??= '00000000-0000-4000-8000-000000000001';
        _synced ??= (stats: _loadLocalAllStats(), clientSeq: _localSeq);
      }
      _isInitialized = true;
    }
  }
}
