import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/services/analytics/firebase_analytics_service.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/utils/audio_completion_tracker.dart';
import 'package:medito/scaffold_messenger_key.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:medito/utils/current_localizations.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:medito/utils/stats_updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NativeTimerCloseRecovery {
  NativeTimerCloseRecovery({
    Future<bool> Function(Map<String, dynamic>) record = handleStats,
    Future<TimerRecordResult> Function(Map<String, dynamic>) recordRun =
        handleTimerRun,
    Future<void> Function(Map<String, Object>)? logEnded,
    void Function(int minutes)? showRecovered,
  }) : _record = record,
       _recordRun = recordRun,
       _logEnded = logEnded ?? _logTimerEnded,
       _showRecovered = showRecovered ?? _showRecoveredSnackBar;

  final Future<bool> Function(Map<String, dynamic>) _record;
  final Future<TimerRecordResult> Function(Map<String, dynamic>) _recordRun;
  final Future<void> Function(Map<String, Object>) _logEnded;
  final void Function(int minutes) _showRecovered;
  final _inFlight = <String, Future<bool>>{};
  final _sentEvents = <String>{};

  /// Una sesión del registro nativo de Android (con `runId`). El servicio es
  /// la única fuente: Dart solo la guarda una vez por `runId` en el historial
  /// de su dueño. `false` solo si la escritura falló (Android reintenta).
  Future<bool> handleRun(CompletionData completion) {
    final runId = completion.runId!;
    return _inFlight.putIfAbsent(
      'run:$runId',
      () => _deliverRun(completion, runId).whenComplete(() {
        _inFlight.remove('run:$runId');
      }),
    );
  }

  Future<bool> _deliverRun(CompletionData completion, String runId) async {
    final result = await _recordRun({
      TypeConstants.trackIdKey: completion.trackId,
      TypeConstants.durationIdKey: completion.duration,
      TypeConstants.fileIdKey: completion.fileId,
      TypeConstants.guideIdKey: completion.guideId ?? '',
      TypeConstants.timestampIdKey: completion.timestamp,
      TypeConstants.runIdKey: runId,
      timerOwnerIdKey: completion.ownerId ?? '',
    });
    if (result == TimerRecordResult.failed) return false;
    if (result == TimerRecordResult.accepted && completion.recovered == true) {
      _showRecovered(completion.duration ~/ Duration.millisecondsPerMinute);
    }
    final ended = completion.timerEnded;
    if (ended != null && _sentEvents.add('run:$runId')) {
      await _logEnded({
        AnalyticsEventConstants.paramTimerMode: ended.mode,
        AnalyticsEventConstants.paramElapsedSeconds: ended.elapsedSeconds,
        AnalyticsEventConstants.paramRecorded: ended.recorded ? 1 : 0,
      });
    }
    return true;
  }

  static void _showRecoveredSnackBar(int minutes) {
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(currentLocalizations().timerRecoveredSession(minutes)),
      ),
    );
  }

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
