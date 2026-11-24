import 'dart:convert';

import 'package:medito/constants/http/http_constants.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/timer/timer_house_content.dart';
import 'package:medito/services/network/http_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TimerNoteSaveResult { saved, conflict, unconfirmed, failed }

class TimerContentRepository {
  const TimerContentRepository({
    required HttpApiService client,
    SharedPreferences? prefs,
  }) : _client = client,
       _prefs = prefs;

  final HttpApiService _client;
  final SharedPreferences? _prefs;

  TimerHouseContent cachedHouseContent() => _readCache(_prefs);

  Future<TimerHouseContent> fetchHouseContent() async =>
      (await fetchHouseContentWithStatus()).content;

  /// Igual que [fetchHouseContent]; `fresh` dice si llegó del servidor.
  Future<({TimerHouseContent content, bool fresh})>
  fetchHouseContentWithStatus() async {
    final prefs = _prefs ?? await _loadPreferences();
    TimerHouseContent? cachedBeforeWrite;
    try {
      final response = await _client.getRequest(HTTPConstants.timerConfig);
      final content = TimerHouseContent.fromJson(response);
      if (prefs == null) return (content: content, fresh: true);
      final raw = jsonEncode(response);
      cachedBeforeWrite = _readCache(prefs);
      final saved = await prefs.setString(
        SharedPreferenceConstants.timerHouseContent,
        raw,
      );
      return (content: saved ? content : cachedBeforeWrite, fresh: true);
    } catch (_) {
      return (content: cachedBeforeWrite ?? _readCache(prefs), fresh: false);
    }
  }

  Future<String?> fetchClosingText() async =>
      (await fetchHouseContent()).closingText;

  static Future<SharedPreferences?> _loadPreferences() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static TimerHouseContent _readCache(SharedPreferences? prefs) {
    try {
      final raw = prefs?.getString(SharedPreferenceConstants.timerHouseContent);
      if (raw != null) return TimerHouseContent.fromJson(jsonDecode(raw));
    } catch (_) {
      // Una copia dañada se trata igual que una copia ausente.
    }
    return const TimerHouseContent.empty();
  }

  Future<bool> saveNote({
    required String sessionId,
    required String note,
  }) async {
    final result = await submitNote(sessionId: sessionId, note: note);
    return result == TimerNoteSaveResult.saved ||
        result == TimerNoteSaveResult.unconfirmed;
  }

  Future<TimerNoteSaveResult> submitNote({
    required String sessionId,
    required String note,
  }) async {
    try {
      final text = note.trim();
      final response = await _client.postRequest(
        HTTPConstants.timerJournal,
        body: {'sessionId': sessionId, 'note': text},
      );
      if (response['entryId'] is! String) return TimerNoteSaveResult.failed;
      // Un identificador por sí solo también puede corresponder a una nota anterior.
      final storedNote = response['note'];
      if (storedNote is! String) return TimerNoteSaveResult.unconfirmed;
      return storedNote == text
          ? TimerNoteSaveResult.saved
          : TimerNoteSaveResult.conflict;
    } catch (_) {
      return TimerNoteSaveResult.failed;
    }
  }
}
