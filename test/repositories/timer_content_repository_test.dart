import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/http/http_constants.dart';
import 'package:medito/repositories/timer/timer_content_repository.dart';
import 'package:medito/services/network/http_api_service.dart';

class _Client extends Fake implements HttpApiService {
  Map<String, dynamic> response = {};
  Exception? error;
  String? path;
  Object? body;

  @override
  Future<Map<String, dynamic>> getRequest(
    String path, {
    Map<String, dynamic>? queryParams,
  }) async {
    this.path = path;
    final failure = error;
    if (failure != null) throw failure;
    return response;
  }

  @override
  Future<Map<String, dynamic>> postRequest(String path, {dynamic body}) async {
    this.path = path;
    this.body = body;
    final failure = error;
    if (failure != null) throw failure;
    return response;
  }
}

void main() {
  late _Client client;
  late TimerContentRepository repository;

  setUp(() {
    client = _Client();
    repository = TimerContentRepository(client: client);
  });

  test('carga y recorta el texto de cierre', () async {
    client.response = {'closingText': '  Que estés bien.\n'};
    expect(await repository.fetchClosingText(), 'Que estés bien.');
    expect(client.path, HTTPConstants.timerConfig);
  });

  test('el texto ausente, vacío o de otro tipo devuelve null', () async {
    for (final value in [null, '', ' \n ', 3, <String>[]]) {
      client.response = {'closingText': value};
      expect(await repository.fetchClosingText(), isNull);
    }
    client.response = {};
    expect(await repository.fetchClosingText(), isNull);
  });

  test('el JSON inválido y los errores de red devuelven null', () async {
    client.error = const FormatException('JSON inválido');
    expect(await repository.fetchClosingText(), isNull);
    client.error = Exception('sin red');
    expect(await repository.fetchClosingText(), isNull);
  });

  test('envía solo el id de sesión y la nota recortada', () async {
    const sessionId = '0123456789abcdef0123456789abcdef';
    for (final timestampField in ['createdAt', 'updatedAt']) {
      client.response = {
        'entryId': 'timer-note-$sessionId',
        timestampField: '2026-11-24T12:00:00Z',
      };
      expect(
        await repository.saveNote(sessionId: sessionId, note: '  Mi nota.\n'),
        isTrue,
      );
      expect(client.path, HTTPConstants.timerJournal);
      expect(client.body, {'sessionId': sessionId, 'note': 'Mi nota.'});
    }
  });

  test('un error o una respuesta sin confirmación devuelve false', () async {
    expect(await repository.saveNote(sessionId: 'a', note: 'Nota'), isFalse);
    client.error = Exception('no se pudo guardar');
    expect(await repository.saveNote(sessionId: 'a', note: 'Nota'), isFalse);
  });
}
