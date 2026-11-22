import 'dart:convert';
import 'dart:math';

import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/utils/day_boundary.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PracticeHistory {
  PracticeHistory._({
    required this.today,
    required this.days,
    required this.lifetimeDays,
    required this.returns,
    required this.sessionsByDay,
    required this.timestamps,
  });

  final DateTime today;
  final Set<DateTime> days;
  final Set<DateTime> lifetimeDays;
  final int returns;
  final Set<int> timestamps;
  final Map<DateTime, List<LocalAudioCompleted>> sessionsByDay;

  int get daysThisWeek {
    final firstDay = DateTime(today.year, today.month, today.day - 6);
    return days.where((day) => !day.isBefore(firstDay)).length;
  }

  int? get pauseDays => pauseDaysBefore(today);

  int? pauseDaysBefore(DateTime day) {
    if (days.contains(day)) return null;
    final previous = days
        .where((practiceDay) => practiceDay.isBefore(day))
        .fold<DateTime?>(null, (latest, practiceDay) {
          return latest == null || practiceDay.isAfter(latest)
              ? practiceDay
              : latest;
        });
    if (previous == null) return null;
    // Las fechas UTC conservan la distancia entre días aunque cambie la hora local.
    final gap = DateTime.utc(day.year, day.month, day.day)
        .difference(DateTime.utc(previous.year, previous.month, previous.day))
        .inDays;
    return gap >= 2 ? gap : null;
  }

  static bool isPracticeSession(LocalAudioCompleted session) =>
      session.id != TypeConstants.streakFreeze &&
      !session.id.startsWith('dummy-track');

  static String _entryKey(LocalAudioCompleted session) =>
      '${session.id}@${session.timestamp}';

  static String _storageKey(String? owner) => 'practice_history:${owner ?? ''}';

  static Future<void> clear(SharedPreferences prefs, String? owner) async {
    await prefs.remove(_storageKey(owner));
  }

  static Map<String, dynamic> _readRecord(
    SharedPreferences? prefs,
    String key,
  ) {
    final stored = prefs?.getString(key);
    return stored == null ? {} : jsonDecode(stored) as Map<String, dynamic>;
  }

  static PracticeHistory read(
    LocalAllStats stats, {
    SharedPreferences? prefs,
    required DateTime now,
    required Duration offset,
    bool remember = true,
    LocalAudioCompleted? storedSession,
    int? completedAt,
  }) {
    final key = _storageKey(
      prefs?.getString(SharedPreferenceConstants.serverUserId),
    );
    final record = _readRecord(prefs, key);
    final pastTimestamps = (record['timestamps'] as List?)?.cast<int>() ?? [];
    final endTimes = Map<String, int>.from(record['endTimes'] as Map? ?? {});
    final corrected =
        storedSession != null &&
        completedAt != null &&
        storedSession.timestamp != completedAt &&
        isPracticeSession(storedSession) &&
        endTimes[_entryKey(storedSession)] != completedAt;
    // El servidor conserva la hora de inicio de sesiones que cruzan medianoche.
    if (corrected) endTimes[_entryKey(storedSession)] = completedAt;

    final today = dayOf(now, offset);
    DateTime dayFor(int timestamp) =>
        dayOf(DateTime.fromMillisecondsSinceEpoch(timestamp), offset);
    final timestamps = <int>{};
    final sessionsByDay = <DateTime, List<LocalAudioCompleted>>{};
    for (final session in stats.audioCompleted ?? <LocalAudioCompleted>[]) {
      if (!isPracticeSession(session)) continue;
      final timestamp = endTimes[_entryKey(session)] ?? session.timestamp;
      final day = dayFor(timestamp);
      if (day.isAfter(today)) continue;
      timestamps.add(timestamp);
      (sessionsByDay[day] ??= []).add(session);
    }

    // Una sesión borrada deja de aparecer en el calendario y conserva su regreso.
    final pastDays = pastTimestamps.map(dayFor).toSet();
    final days = sessionsByDay.keys.toSet();
    final newDays = days.difference(pastDays).length;
    // Cambiar el inicio del día puede agrupar fechas sin reducir los regresos.
    final previousCount = record['count'] as int? ?? 0;
    final returns = max(previousCount, pastDays.length) + newDays;
    if (remember &&
        prefs != null &&
        (returns != previousCount ||
            corrected ||
            !pastTimestamps.toSet().containsAll(timestamps))) {
      prefs
          .setString(
            key,
            jsonEncode({
              'timestamps': {...pastTimestamps, ...timestamps}.toList(),
              'count': returns,
              'endTimes': endTimes,
            }),
          )
          .ignore();
    }

    return PracticeHistory._(
      today: today,
      timestamps: timestamps,
      sessionsByDay: sessionsByDay,
      days: days,
      lifetimeDays: {...pastDays, ...days},
      returns: returns,
    );
  }
}
