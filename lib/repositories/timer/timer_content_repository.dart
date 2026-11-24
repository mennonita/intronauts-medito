import 'package:medito/constants/http/http_constants.dart';
import 'package:medito/services/network/http_api_service.dart';

class TimerContentRepository {
  const TimerContentRepository({required HttpApiService client})
    : _client = client;

  final HttpApiService _client;

  Future<String?> fetchClosingText() async {
    try {
      final response = await _client.getRequest(HTTPConstants.timerConfig);
      final text = response['closingText'];
      if (text is! String) return null;
      final trimmed = text.trim();
      return trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  Future<bool> saveNote({
    required String sessionId,
    required String note,
  }) async {
    try {
      final response = await _client.postRequest(
        HTTPConstants.timerJournal,
        body: {'sessionId': sessionId, 'note': note.trim()},
      );
      // El cliente entrega el cuerpo sin el código HTTP. Tanto 200 como 201
      // confirman el guardado con el identificador de la nota.
      return response['entryId'] is String;
    } catch (_) {
      return false;
    }
  }
}
