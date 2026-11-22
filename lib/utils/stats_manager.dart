import 'dart:async';
import 'dart:convert';

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
  static final _uuidPattern = RegExp(
    r'^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$',
  );

  late StatsService _statsService;
  late SharedPreferences _prefs;
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
  final _postsInFlight = <int, Future<void>>{};
  Future<void>? _localWrite;

  Duration _dayBoundaryOffset = Duration.zero;

  // Bumped by clearAllStats. A sync that was already fetching when the stats
  // were cleared (sign-out, account deletion) drops its result instead of
  // writing the old account's history back.
  int _clearGeneration = 0;

  StatsManager._internal();

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

  Future<void> _saveLastSyncedAt() async {
    try {
      var prefs = _prefs;
      if (_lastSyncedAt != null) {
        await prefs.setInt(
          SharedPreferenceConstants.statsLastSyncedAt,
          _lastSyncedAt!.millisecondsSinceEpoch,
        );
      } else {
        await prefs.remove(SharedPreferenceConstants.statsLastSyncedAt);
      }
    } catch (e) {
      // Handle case where SharedPreferences isn't initialized (e.g., in some tests)
      // Silently fail - this is OK in test scenarios
    }
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
    if (_verifiedUserId == null) return;
    if (_dirty) {
      await flushPendingPost();
      return;
    }

    final generation = _clearGeneration;
    final startedSeq = _localSeq;
    final remote = await _statsService.fetchAllStats();
    if (generation != _clearGeneration || startedSeq != _localSeq) return;
    if (remote == null) return;

    _synced = remote;
    // Conserva el historial local creado antes de guardar la secuencia.
    if (_localSeq == 0 && remote.clientSeq == 0) {
      _merge(remote.stats);
    } else {
      _allStats = remote.stats;
    }
    if (remote.clientSeq > _localSeq) _localSeq = remote.clientSeq;
    final savedSeq = _localSeq;
    final score = _updateDerivedStats();
    _lastSyncedAt = _getCurrentDate();
    await _saveLocalAllStatsToSharedPrefs();
    if (generation != _clearGeneration || savedSeq != _localSeq) return;
    await saveConsistencyScoreHistory(score);
    await _saveLastSyncedAt();
    if (generation == _clearGeneration) _updateHomeWidget();
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

  void _merge(LocalAllStats remoteStats) {
    // Check if remote stats contain recent dummy data
    var now = _getCurrentDate();
    var today = DateTime(now.year, now.month, now.day);

    // Check if any dummy tracks are from today
    var hasRecentDummyTracks =
        remoteStats.audioCompleted?.any((audio) {
          if (!audio.id.startsWith('dummy-track')) return false;

          var trackDate = DateTime.fromMillisecondsSinceEpoch(audio.timestamp);
          var trackDay = DateTime(
            trackDate.year,
            trackDate.month,
            trackDate.day,
          );

          // Consider tracks from today as recent
          return trackDay.isAtSameMomentAs(today);
        }) ??
        false;

    // If remote stats contain recent dummy data, prefer remote data completely
    if (hasRecentDummyTracks) {
      //dev.log
      //'StatsManager: Remote stats contain recent dummy data, using remote stats only');
      _allStats = remoteStats.copyWith(
        updated: _getCurrentDate().millisecondsSinceEpoch,
      );
      return;
    }

    // Use the current _allStats as localAllStats if available
    LocalAllStats? localAllStats = _allStats;

    // If _allStats is null, try to load from SharedPreferences
    if (localAllStats == null) {
      var prefs = _prefs;
      var localAllStatsJson = prefs.getString(
        SharedPreferenceConstants.localAllStatsKey,
      );

      if (localAllStatsJson != null && localAllStatsJson != 'null') {
        localAllStats = _loadLocalAllStats();
        //dev.log
        //'StatsManager: Loaded local stats from SharedPreferences: ${localAllStats.totalTracksCompleted}');
      } else {
        //dev.log'StatsManager: No local stats found in SharedPreferences');
      }
    } else {
      //dev.log
      //'StatsManager: Using existing _allStats as local stats: ${localAllStats.totalTracksCompleted}');
    }

    // If we have no remote stats but have local stats, use local
    if (remoteStats.totalTracksCompleted == 0) {
      if (localAllStats != null && localAllStats.totalTracksCompleted > 0) {
        //dev.log'StatsManager: Using local stats');
        _allStats = localAllStats.copyWith(
          updated: _getCurrentDate().millisecondsSinceEpoch,
        );
        return;
      }
    }

    // If we have no local stats but have remote stats, use remote
    if (localAllStats == null || localAllStats.totalTracksCompleted == 0) {
      if (remoteStats.totalTracksCompleted > 0) {
        _allStats = remoteStats.copyWith(
          updated: _getCurrentDate().millisecondsSinceEpoch,
        );
        return;
      }
    }

    // If both exist, merge them properly
    if (localAllStats != null) {
      //dev.log'DEBUG - MERGING:');
      //dev.log
      // 'Local audio: ${localAllStats.audioCompleted?.map((a) => a.id).toList()}');
      //dev.log
      // 'Remote audio: ${remoteStats.audioCompleted?.map((a) => a.id).toList()}');

      // Create a combined list of tracks checked
      var combinedTracksChecked = {
        ...localAllStats.tracksChecked ?? [],
        ...remoteStats.tracksChecked ?? [],
      }.toList();

      // Deduplicate audio completed entries by ID and timestamp
      final audioCompletedMap = <String, LocalAudioCompleted>{};

      // Process local entries first
      for (final audio in localAllStats.audioCompleted ?? []) {
        final key = '${audio.id}_${audio.timestamp}';
        audioCompletedMap[key] = audio;
      }

      // Process remote entries, overwriting local entries if they exist
      for (final audio in remoteStats.audioCompleted ?? []) {
        final key = '${audio.id}_${audio.timestamp}';
        audioCompletedMap[key] = audio;
      }

      // Convert back to list
      final deduplicatedAudioCompleted = audioCompletedMap.values.toList();

      //dev.log
      //'Deduplicated audio: ${deduplicatedAudioCompleted.map((a) => a.id).toList()}');

      // Create a combined list of freeze usage dates, removing duplicates
      var deduplicatedFreezeUsageDates = {
        ...localAllStats.freezeUsageDates,
        ...remoteStats.freezeUsageDates,
      }.toList();

      // Determine which base to use for other properties
      var areRemoteStatsNewer = remoteStats.updated > localAllStats.updated;
      var baseStats = areRemoteStatsNewer ? remoteStats : localAllStats;

      // Lifetime counters are monotonic, so never let a freshly-created copy
      // (e.g. a completion recorded before the local history was loaded)
      // win just because it has the newer `updated` stamp. Take the larger
      // value from either side, and never report fewer completions than we
      // actually hold in the merged history.
      // Legacy streak-freeze entries and the manual-edit form's dummy entries
      // live in the history but are not completed tracks, so they do not
      // count toward the floor.
      final realCompletions = deduplicatedAudioCompleted
          .where(
            (a) =>
                a.id != TypeConstants.streakFreeze &&
                !a.id.startsWith('dummy-track'),
          )
          .length;
      final mergedTotalTracks = [
        localAllStats.totalTracksCompleted,
        remoteStats.totalTracksCompleted,
        realCompletions,
      ].reduce((a, b) => a > b ? a : b);
      final mergedTimeListened =
          localAllStats.totalTimeListened > remoteStats.totalTimeListened
          ? localAllStats.totalTimeListened
          : remoteStats.totalTimeListened;
      final mergedLongestStreak =
          localAllStats.streakLongest > remoteStats.streakLongest
          ? localAllStats.streakLongest
          : remoteStats.streakLongest;

      // Update with combined data
      _allStats = baseStats.copyWith(
        audioCompleted: deduplicatedAudioCompleted,
        freezeUsageDates: deduplicatedFreezeUsageDates,
        tracksChecked: combinedTracksChecked,
        totalTracksCompleted: mergedTotalTracks,
        totalTimeListened: mergedTimeListened,
        streakLongest: mergedLongestStreak,
        updated: _getCurrentDate().millisecondsSinceEpoch,
      );
    } else {
      _allStats = remoteStats;
    }
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
    if (_verifiedUserId != null &&
        _legacyPending == null &&
        record?.containsKey(_changesKey) == false &&
        !_dirty &&
        _localSeq > 0) {
      _synced = (stats: _loadLocalAllStats(), clientSeq: _localSeq);
    }
  }

  void _loadRecordState(Map<String, dynamic>? record) {
    _localSeq = record?[_localSeqKey] as int? ?? 0;
    _dirty = record?[_pendingSyncKey] == true;
    _needsResync = record?[_resyncKey] == true;
    final attempt = record?[_attemptKey] as Map<String, dynamic>?;
    _attempt = attempt == null
        ? null
        : (
            seq: attempt['seq'] as int,
            changes: attempt['changes'] as int,
            digest: attempt['digest'] as String,
          );
    final legacy = record?[_legacyPendingKey] as Map<String, dynamic>?;
    _legacyPending = legacy != null
        ? LocalAllStats.fromJson(legacy)
        : record != null &&
              !record.containsKey(_changesKey) &&
              (_dirty || record.containsKey('stats'))
        ? LocalAllStats.fromJson(
            record['stats'] as Map<String, dynamic>? ?? record,
          )
        : null;
    final synced = record?[_syncedStatsKey] as Map<String, dynamic>?;
    _synced = synced == null
        ? null
        : (
            stats: LocalAllStats.fromJson(synced),
            clientSeq: record![_syncedSeqKey] as int,
          );
    _changes = [
      for (final change in (record?[_changesKey] as List? ?? const []))
        StatsChange(change as Map<String, dynamic>),
    ];
  }

  Map<String, dynamic> _recordState() => {
    _ownerKey: _verifiedUserId,
    _localSeqKey: _localSeq,
    _pendingSyncKey: _dirty,
    _resyncKey: _needsResync,
    if (_attempt case final attempt?)
      _attemptKey: {
        'seq': attempt.seq,
        'changes': attempt.changes,
        'digest': attempt.digest,
      },
    if (_synced case final synced?) ...{
      _syncedStatsKey: synced.stats.toJson(),
      _syncedSeqKey: synced.clientSeq,
    },
    if (_legacyPending case final legacy?) _legacyPendingKey: legacy.toJson(),
    _changesKey: [for (final change in _changes) change.json],
  };

  Future<void> _saveLocalAllStatsToSharedPrefs() async {
    // Una sola escritura guarda el historial y el estado de sincronización.
    final saved = await _prefs.setString(
      SharedPreferenceConstants.localAllStatsKey,
      jsonEncode({..._allStats!.toJson(), ..._recordState()}),
    );
    if (!saved) throw StateError('Could not save local stats');
  }

  LocalAllStats _loadLocalAllStats() {
    final record = _readStatsRecord(SharedPreferenceConstants.localAllStatsKey);
    return record == null
        ? LocalAllStats.empty()
        : LocalAllStats.fromJson(record);
  }

  List<Map<String, dynamic>> _pendingOwners() {
    final record = _readStatsRecord(_pendingOwnerKey);
    if (record == null) return [];
    final others = record.remove('other_owners') as List? ?? [];
    return [record, ...others.cast<Map<String, dynamic>>()];
  }

  Future<void> _savePendingOwners(List<Map<String, dynamic>> owners) async {
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

  Map<String, dynamic>? _archiveActiveStats() {
    if (!_dirty && (_verifiedUserId == null || _synced == null)) return null;
    return {
      ..._recordState(),
      'stats': (_allStats ?? _loadLocalAllStats()).toJson(),
    };
  }

  Future<void> _ensureStatsLoaded() async {
    if (!_isInitialized) await initialize();
    _allStats ??= _loadLocalAllStats();
  }

  double _updateDerivedStats() {
    _allStats = calculateStreak(_allStats!);
    final score = calculateConsistencyScore(_allStats!);
    _allStats = _allStats!.copyWith(consistencyScore: score);
    return score;
  }

  Future<void> _saveLocalChange({
    StatsChange? change,
    double? score,
    bool skipPost = false,
  }) async {
    final generation = _clearGeneration;
    _localSeq++;
    _dirty = true;
    if (change != null) _changes.add(change);
    final write = _localWrite = _saveLocalAllStatsToSharedPrefs();
    await write;
    if (generation != _clearGeneration) return;
    if (score != null) await saveConsistencyScoreHistory(score);
    if (!skipPost && generation == _clearGeneration) await flushPendingPost();
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
    if (generation != _clearGeneration) return;

    final completedAt = audioCompleted.timestamp;
    if (AudioCompletionTracker.checkTrackCrossedMidnight(
      endTimestamp: audioCompleted.timestamp,
      duration: duration,
    )) {
      audioCompleted = audioCompleted.copyWith(
        timestamp: audioCompleted.timestamp - duration,
      );
    }

    final change = StatsChange.completion(audioCompleted, duration);
    _allStats = change.apply(
      _allStats!,
      _getCurrentDate().millisecondsSinceEpoch,
    );
    PracticeHistory.read(
      _allStats!,
      prefs: _prefs,
      now: _getCurrentDate(),
      offset: _dayBoundaryOffset,
      storedSession: audioCompleted,
      completedAt: completedAt,
    );
    await _saveLocalChange(
      change: change,
      score: _updateDerivedStats(),
      skipPost: skipPost,
    );
    if (!skipPost) _updateHomeWidget();
  }

  /// Adds the listening time of a repeated play-through without recording a
  /// new session. See [AudioCompletionTracker.addRepeatListeningTime].
  Future<void> addRepeatListeningTime(int duration) async {
    final generation = _clearGeneration;
    if (!_isInitialized) {
      await initialize();
    }
    await _ensureStatsLoaded();
    if (generation != _clearGeneration) return;

    final change = StatsChange.repeat(duration);
    _allStats = change.apply(
      _allStats!,
      _getCurrentDate().millisecondsSinceEpoch,
    );
    await _saveLocalChange(change: change);
    _updateHomeWidget();
  }

  Future<void> flushPendingPost() {
    if (!_dirty || _allStats == null || _verifiedUserId == null) {
      return Future.value();
    }

    final generation = _clearGeneration;
    return _postsInFlight.putIfAbsent(
      generation,
      () => _postPendingChanges(generation).whenComplete(() {
        _postsInFlight.remove(generation);
      }),
    );
  }

  Future<void> _postPendingChanges(int generation) async {
    var retried = false;
    while (generation == _clearGeneration && _dirty) {
      await _localWrite;
      if (generation != _clearGeneration) return;
      if (_synced == null || _needsResync) {
        final startedSeq = _localSeq;
        final remote = await _statsService.fetchAllStats();
        if (generation != _clearGeneration) return;
        if (startedSeq != _localSeq) continue;
        if (remote == null) return;
        await _rebasePendingChanges(remote);
        if (generation != _clearGeneration) return;
      }

      final sent = _allStats!;
      final seq = _localSeq;
      final changeCount = _changes.length;
      // Si se pierde la respuesta, el GET puede identificar el envío exacto.
      _attempt = (seq: seq, changes: changeCount, digest: _statsDigest(sent));
      _needsResync = true;
      await _saveLocalAllStatsToSharedPrefs();
      if (generation != _clearGeneration) return;

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

      _synced = (stats: sent, clientSeq: result.clientSeq);
      _attempt = null;
      _needsResync = false;
      _changes.removeRange(0, changeCount);
      _dirty = seq != _localSeq;
      _legacyPending = null;
      if (result.clientSeq >= _localSeq) {
        _localSeq = result.clientSeq + (_dirty ? 1 : 0);
      }
      await _saveLocalAllStatsToSharedPrefs();
      if (generation != _clearGeneration) return;
      _lastSyncedAt = _getCurrentDate();
      await _saveLastSyncedAt();
    }
  }

  String _statsDigest(LocalAllStats stats) {
    final wire = LocalAllStats.fromAllStats(stats.toAllStats()).toAllStats();
    return sha256.convert(utf8.encode(jsonEncode(wire.toJson()))).toString();
  }

  Future<void> _rebasePendingChanges(StatsSnapshot remote) async {
    final attempt = _attempt;
    if (attempt != null &&
        attempt.seq == remote.clientSeq &&
        attempt.digest == _statsDigest(remote.stats)) {
      // El servidor ya guardó estos cambios. Conserva los que llegaron después.
      _changes.removeRange(0, attempt.changes);
      _legacyPending = null;
    }
    _attempt = null;
    _synced = remote;
    final now = _getCurrentDate().millisecondsSinceEpoch;
    if (_legacyPending case final legacy?) {
      // Las versiones anteriores solo guardaban la copia sin el detalle de los cambios.
      _allStats = legacy;
      _merge(remote.stats);
    } else {
      _allStats = remote.stats;
    }
    for (final change in _changes) {
      _allStats = change.apply(_allStats!, now, replay: true);
    }
    _updateDerivedStats();
    if (remote.clientSeq >= _localSeq) _localSeq = remote.clientSeq + 1;
    _needsResync = false;
    await _saveLocalAllStatsToSharedPrefs();
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
    if (generation != _clearGeneration) return;

    PracticeHistory.read(
      _allStats ?? _loadLocalAllStats(),
      prefs: _prefs,
      now: _getCurrentDate(),
      offset: _dayBoundaryOffset,
    );
    final change = StatsChange.restore(snapshot);
    _allStats = change.apply(
      snapshot,
      _getCurrentDate().millisecondsSinceEpoch,
    );
    await _saveLocalChange(change: change, score: _updateDerivedStats());
    _updateHomeWidget();
  }

  Future<void> removeAudioCompleted(LocalAudioCompleted session) async {
    final generation = _clearGeneration;
    await _ensureStatsLoaded();
    if (generation != _clearGeneration) return;

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
    if (identical(updated, _allStats)) return;
    _allStats = updated;
    await _saveLocalChange(change: change, score: _updateDerivedStats());
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
    if (generation != _clearGeneration) return;

    final change = StatsChange.check(ids, checked);
    final updated = change.apply(
      _allStats!,
      _getCurrentDate().millisecondsSinceEpoch,
    );
    if (identical(updated, _allStats)) return;
    _allStats = updated;
    await _saveLocalChange(change: change);
  }

  Future<void> removeTrackChecked(String trackId) =>
      setTracksChecked([trackId], checked: false);

  Future<void> acceptServerUser(String userId) async {
    final generation = _clearGeneration;
    await initialize();
    if (generation != _clearGeneration ||
        _prefs.getBool(SharedPreferenceConstants.isLoggedIn) != true ||
        !_uuidPattern.hasMatch(userId) ||
        _verifiedUserId == userId) {
      return;
    }

    final active = _archiveActiveStats();
    final owners = _pendingOwners();
    // Solo /me puede confirmar el UUID de una copia guardada.
    final matching = owners
        .where((owner) => owner[_ownerKey] == userId)
        .firstOrNull;
    final transition = ++_clearGeneration;
    _verifiedUserId = userId;
    _allStats = matching == null
        ? LocalAllStats.empty()
        : LocalAllStats.fromJson(matching['stats'] as Map<String, dynamic>);
    _loadRecordState(matching);
    // Los registros de la versión anterior solo se guardaban si había cambios.
    if (matching != null && !matching.containsKey(_pendingSyncKey)) {
      _dirty = true;
    }
    _lastSyncedAt = null;

    if (active != null) {
      owners.removeWhere(
        (owner) =>
            active[_ownerKey] != null && active[_ownerKey] == owner[_ownerKey],
      );
      owners.add(active);
      await _savePendingOwners(owners);
    }
    if (transition != _clearGeneration) return;

    _localWrite = _saveLocalAllStatsToSharedPrefs();
    await _localWrite;
    if (transition != _clearGeneration) return;
    await _prefs.setString(SharedPreferenceConstants.serverUserId, userId);
    if (transition != _clearGeneration) return;
    if (matching != null) {
      owners.remove(matching);
      await _savePendingOwners(owners);
    }
    await _saveLastSyncedAt();
    if (transition == _clearGeneration) flushPendingPost().ignore();
  }

  Future<void> clearAllStats({bool preservePending = true}) async {
    await initialize();
    _clearGeneration++;
    final active = preservePending ? _archiveActiveStats() : null;
    _verifiedUserId = null;
    _allStats = LocalAllStats.empty();
    _loadRecordState(null);
    _lastSyncedAt = null;
    if (active != null) {
      final others = _pendingOwners().where(
        (owner) =>
            active[_ownerKey] == null || active[_ownerKey] != owner[_ownerKey],
      );
      await _savePendingOwners([active, ...others]);
    }

    _localWrite = _saveLocalAllStatsToSharedPrefs();
    await _localWrite;
    if (!preservePending) await _savePendingOwners([]);
    await _prefs.remove(SharedPreferenceConstants.serverUserId);
    await _saveLastSyncedAt();
  }

  bool get isInitialized => _isInitialized;

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
    var daysSinceFirstSession = today.difference(firstSessionDate).inDays + 1;

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

    var day29 = firstSessionDate.add(const Duration(days: 28));
    var activeDaysAtDay29 = allActivityDates
        .where((d) => !d.isAfter(day29))
        .length;
    var ema = activeDaysAtDay29 / 29.0;

    var day30 = firstSessionDate.add(const Duration(days: 29));
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
        var prevDay = currentDay.subtract(const Duration(days: 1));
        var nextDay = currentDay.add(const Duration(days: 1));
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
      currentDay = currentDay.add(const Duration(days: 1));
    }

    return ema.clamp(0.0, 1.0);
  }

  // Test helpers
  @visibleForTesting
  void setStatsForTesting(LocalAllStats stats) {
    _allStats = stats;
  }

  @visibleForTesting
  void setStatsServiceForTesting(StatsService service) {
    _statsService = service;
  }

  @visibleForTesting
  LocalAllStats? get currentStats => _allStats;

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

    _allStats = calculateStreak(_allStats!);
    final newConsistencyScore = calculateConsistencyScore(_allStats!);
    _allStats = _allStats!.copyWith(consistencyScore: newConsistencyScore);
    await _saveLocalChange(skipPost: true);
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
    _verifiedUserId = null;
    _loadRecordState(null);
    _postsInFlight.clear();
    _localWrite = null;
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
