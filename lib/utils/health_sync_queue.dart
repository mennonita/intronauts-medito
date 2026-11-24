import 'package:shared_preferences/shared_preferences.dart';

class HealthSyncEntry {
  const HealthSyncEntry({
    required this.key,
    required this.startMs,
    required this.endMs,
    required this.accountId,
    this.attempting = false,
  });

  final String key;
  final int startMs;
  final int endMs;
  final String accountId;
  final bool attempting;

  Map<String, dynamic> toJson() => {
    'key': key,
    'startMs': startMs,
    'endMs': endMs,
    'accountId': accountId,
    'attempting': attempting,
  };

  factory HealthSyncEntry.fromJson(Map<String, dynamic> json) =>
      HealthSyncEntry(
        key: json['key'] as String,
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        accountId: json['accountId'] as String,
        attempting: json['attempting'] as bool? ?? false,
      );
}

// Se implementa en la tarea W2-HEALTH.
class HealthSyncQueue {
  static Future<void> add(HealthSyncEntry entry) async {}

  static Future<void> flush() async {}

  static bool hasConsent(SharedPreferences prefs) => false;

  static Future<void> setConsent(bool on) async {}
}
