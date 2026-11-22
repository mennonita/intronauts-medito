import 'dart:convert';

import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/services/analytics/firebase_analytics_service.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/utils/audio_completion_tracker.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:medito/utils/stats_updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NativeTimerCloseRecovery {
  NativeTimerCloseRecovery({
    Future<bool> Function(Map<String, dynamic>) record = handleStats,
    Future<void> Function(Map<String, Object>)? logEnded,
  }) : _record = record,
       _logEnded = logEnded ?? _logTimerEnded;

  final Future<bool> Function(Map<String, dynamic>) _record;
  final Future<void> Function(Map<String, Object>) _logEnded;
  final _inFlight = <String, Future<bool>>{};
  final _sentEvents = <String>{};

  Future<bool> handle(CompletionData completion) {
    final key =
        '${completion.fileId}/${completion.trackId}@${completion.timestamp}';
    return _inFlight.putIfAbsent(
      key,
      () => _deliver(completion, key).whenComplete(() {
        _inFlight.remove(key);
      }),
    );
  }

  Future<bool> _deliver(CompletionData completion, String key) async {
    final ended = completion.timerEnded!;
    final prefs = await SharedPreferences.getInstance();
    const receiptKey = SharedPreferenceConstants.lastRecoveredTimerClose;
    if (prefs.getString(receiptKey) == key) {
      _sentEvents.add(key);
      return true;
    }

    if (ended.recorded) {
      if (_isRecorded(prefs, completion)) {
        await AudioSessionTracker.instance.onCompleted(
          fileId: completion.fileId,
        );
      } else if (!await _record({
        TypeConstants.trackIdKey: completion.trackId,
        TypeConstants.durationIdKey: completion.duration,
        TypeConstants.fileIdKey: completion.fileId,
        TypeConstants.guideIdKey: completion.guideId,
        TypeConstants.timestampIdKey: completion.timestamp,
      })) {
        return false;
      }
    } else {
      await AudioSessionTracker.instance.onStopped();
    }
    if (!_sentEvents.contains(key)) {
      await _logEnded({
        AnalyticsEventConstants.paramTimerMode: ended.mode,
        AnalyticsEventConstants.paramElapsedSeconds: ended.elapsedSeconds,
        AnalyticsEventConstants.paramRecorded: ended.recorded ? 1 : 0,
      });
      _sentEvents.add(key);
    }
    // Confirma a Android después de guardar el recibo del evento.
    return prefs.setString(receiptKey, key);
  }

  bool _isRecorded(SharedPreferences prefs, CompletionData completion) {
    final raw = prefs.getString(SharedPreferenceConstants.localAllStatsKey);
    if (raw == null) return false;
    final LocalAllStats stats;
    try {
      stats = LocalAllStats.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return false;
    }
    final crossedMidnight = AudioCompletionTracker.checkTrackCrossedMidnight(
      endTimestamp: completion.timestamp,
      duration: completion.duration,
    );
    final timestamp = crossedMidnight
        ? completion.timestamp - completion.duration
        : completion.timestamp;
    return stats.audioCompleted?.any(
          (entry) =>
              entry.id == completion.trackId && entry.timestamp == timestamp,
        ) ??
        false;
  }

  static Future<void> _logTimerEnded(Map<String, Object> parameters) =>
      FirebaseAnalyticsService().logEvent(
        name: AnalyticsEventConstants.timerEnded,
        parameters: parameters,
      );
}
