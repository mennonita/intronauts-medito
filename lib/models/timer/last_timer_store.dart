import 'dart:convert';

import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ajustes de la última sesión iniciada.
class LastTimerSnapshot {
  const LastTimerSnapshot({
    required this.settings,
    this.backgroundSoundId,
    required this.savedAtMs,
  });

  final Map<String, dynamic> settings;
  final String? backgroundSoundId;
  final int savedAtMs;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'settings': settings,
    'backgroundSoundId': backgroundSoundId,
    'savedAtMs': savedAtMs,
  };

  static LastTimerSnapshot? fromJson(Map<String, dynamic> json) {
    final settings = json['settings'];
    final backgroundSoundId = json['backgroundSoundId'];
    final savedAtMs = json['savedAtMs'];
    if (json['v'] != 1 ||
        settings is! Map<String, dynamic> ||
        (backgroundSoundId != null && backgroundSoundId is! String) ||
        savedAtMs is! int) {
      return null;
    }
    return LastTimerSnapshot(
      settings: settings,
      backgroundSoundId: backgroundSoundId as String?,
      savedAtMs: savedAtMs,
    );
  }
}

class LastTimerStore {
  static ({String runId, LastTimerSnapshot snapshot})? _staged;

  static void stage(String runId, LastTimerSnapshot snapshot) {
    _staged = (runId: runId, snapshot: snapshot);
  }

  static Future<bool> commitStaged(
    SharedPreferences prefs,
    String runId,
  ) async {
    final staged = _staged;
    if (staged == null || staged.runId != runId) return false;
    final saved = await prefs.setString(
      SharedPreferenceConstants.timerLastSettings,
      jsonEncode(staged.snapshot.toJson()),
    );
    // Conserva otro borrador si se preparó mientras se guardaba esta sesión.
    if (saved && _staged == staged) _staged = null;
    return saved;
  }

  static LastTimerSnapshot? read(SharedPreferences prefs) {
    final raw = prefs.get(SharedPreferenceConstants.timerLastSettings);
    if (raw is! String) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic>
          ? LastTimerSnapshot.fromJson(json)
          : null;
    } on FormatException {
      return null;
    }
  }
}
