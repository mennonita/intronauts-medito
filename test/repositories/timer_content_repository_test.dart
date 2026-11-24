import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/http/http_constants.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/providers/timer/timer_content_provider.dart';
import 'package:medito/repositories/timer/timer_content_repository.dart';
import 'package:medito/services/network/http_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client extends Fake implements HttpApiService {
  Map<String, dynamic> response = {};
  Completer<Map<String, dynamic>>? pending;
  int getRequests = 0;
  Exception? error;
  String? path;
  Object? body;

  @override
  Future<Map<String, dynamic>> getRequest(
    String path, {
    Map<String, dynamic>? queryParams,
  }) async {
    this.path = path;
    getRequests++;
    final failure = error;
    if (failure != null) throw failure;
    return pending?.future ?? response;
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
  TestWidgetsFlutterBinding.ensureInitialized();

  const cacheKey = SharedPreferenceConstants.timerHouseContent;
  late _Client client;
  late SharedPreferences prefs;
  late TimerContentRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    client = _Client();
    repository = TimerContentRepository(client: client, prefs: prefs);
  });

  test('guarda el JSON de la respuesta sin filtrarlo', () async {
    client.response = {
      'openingText': ' Siéntate. ',
      'beadsPerRound': 54,
      'futuro': {'dato': 1},
    };
    final content = await repository.fetchHouseContent();
    expect(client.path, HTTPConstants.timerConfig);
    expect(prefs.getString(cacheKey), jsonEncode(client.response));
    expect(content.openingText, 'Siéntate.');
    expect(repository.cachedHouseContent().beadsPerRound, 54);
  });

  test('sin red, usa la copia guardada', () async {
    await prefs.setString(
      cacheKey,
      '{"closingText":"Gracias","beadsPerRound":54}',
    );
    client.error = Exception('sin red');
    expect((await repository.fetchHouseContent()).beadsPerRound, 54);
    expect(await repository.fetchClosingText(), 'Gracias');
  });

  test('dice si el contenido llegó del servidor', () async {
    client.response = {'beadsPerRound': 54};
    expect((await repository.fetchHouseContentWithStatus()).fresh, isTrue);
    client.error = Exception('sin red');
    final offline = await repository.fetchHouseContentWithStatus();
    expect(offline.fresh, isFalse);
    expect(offline.content.beadsPerRound, 54);
  });

  test('sin red ni copia válida, usa contenido vacío', () async {
    client.error = Exception('sin red');
    for (final raw in [null, '{', '[]', 54]) {
      if (raw is String) await prefs.setString(cacheKey, raw);
      if (raw is int) await prefs.setInt(cacheKey, raw);
      final content = await repository.fetchHouseContent();
      expect(content.closingText, isNull);
      expect(content.openingText, isNull);
      expect(content.words, isEmpty);
      expect(content.practiceDays, isEmpty);
      expect(content.practices, isEmpty);
      expect(content.beadsPerRound, 108);
    }
  });

  test('el proveedor muestra la copia y comparte una sola carga', () async {
    await prefs.setString(cacheKey, '{"closingText":"Copia"}');
    client.pending = Completer<Map<String, dynamic>>();
    final container = ProviderContainer(
      overrides: [timerContentRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final closing = container.listen(timerClosingTextProvider, (_, _) {});

    expect(container.read(timerHouseContentProvider).closingText, 'Copia');
    expect(closing.read().requireValue, 'Copia');
    expect(client.getRequests, 1);

    client.pending!.complete({'closingText': 'Actual', 'beadsPerRound': 54});
    await Future<void>.delayed(Duration.zero);
    expect(container.read(timerHouseContentProvider).beadsPerRound, 54);
    expect(closing.read().requireValue, 'Actual');
    expect(client.getRequests, 1);
  });

  for (final sharesContent in [false, true]) {
    testWidgets(
      'actualiza al volver al temporizador (comparte: $sharesContent)',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        client.response = {'closingText': 'Copia'};
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              timerContentRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              home: Consumer(
                builder: (context, ref, _) {
                  final content = ref.watch(timerHouseContentProvider);
                  return Text(content.closingText ?? 'Sin contenido');
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Copia'), findsOneWidget);

        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => Consumer(
                builder: (context, ref, _) {
                  if (sharesContent) ref.watch(timerHouseContentProvider);
                  return const Text('Otra pantalla');
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final requests = client.getRequests;
        client.pending = Completer<Map<String, dynamic>>();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(client.getRequests, requests + 1);
        expect(find.text('Copia'), findsOneWidget);

        client.pending!.complete({'closingText': 'Nuevo contenido'});
        await tester.pumpAndSettle();
        expect(find.text('Nuevo contenido'), findsOneWidget);
      },
    );
  }

  testWidgets('actualiza al volver a la app y al recuperar la red', (
    tester,
  ) async {
    final previousLifecycle = tester.binding.lifecycleState;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      if (previousLifecycle != null) {
        tester.binding.handleAppLifecycleStateChanged(previousLifecycle);
      }
    });
    await prefs.setString(cacheKey, '{"closingText":"Copia"}');
    client.error = Exception('sin red');
    final container = ProviderContainer(
      overrides: [timerContentRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final closing = container.listen(timerHouseContentProvider, (_, _) {});
    await tester.pump();
    expect(closing.read().closingText, 'Copia');
    expect(client.getRequests, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 1));
    expect(client.getRequests, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(client.getRequests, 2);
    expect(closing.read().closingText, 'Copia');

    client.error = null;
    client.pending = Completer<Map<String, dynamic>>();
    await tester.pump(const Duration(seconds: 30));
    expect(client.getRequests, 3);
    expect(closing.read().closingText, 'Copia');
    client.pending!.complete({'closingText': 'Con red'});
    await tester.pump();
    expect(closing.read().closingText, 'Con red');

    closing.close();
    await tester.pump(const Duration(minutes: 1));
    expect(client.getRequests, 3);
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

  test(
    'distingue una nota confirmada de un conflicto o una respuesta antigua',
    () async {
      const sessionId = '0123456789abcdef0123456789abcdef';
      client.response = {'entryId': 'timer-note-$sessionId'};
      expect(
        await repository.submitNote(sessionId: sessionId, note: 'Mi nota.'),
        TimerNoteSaveResult.unconfirmed,
      );
      client.response['note'] = 'Mi nota.';
      expect(
        await repository.submitNote(sessionId: sessionId, note: '  Mi nota. '),
        TimerNoteSaveResult.saved,
      );
      expect(
        await repository.submitNote(sessionId: sessionId, note: 'Otra nota.'),
        TimerNoteSaveResult.conflict,
      );
    },
  );
}
