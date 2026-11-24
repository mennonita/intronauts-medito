import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/app_globals.dart' show appReadyCompleter;
import 'package:medito/services/deep_link_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _messages = MethodChannel('com.llfbandit.app_links/messages');
const _events = MethodChannel('com.llfbandit.app_links/events');

/// Monta la app con el enlace inicial [initialLink] y devuelve el servicio.
Future<DeepLinkService> _pumpService(
  WidgetTester tester, {
  String? initialLink,
}) async {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    _messages,
    (call) async => call.method == 'getInitialLink' ? initialLink : null,
  );
  messenger.setMockMethodCallHandler(_events, (_) async => null);
  addTearDown(() {
    messenger.setMockMethodCallHandler(_messages, null);
    messenger.setMockMethodCallHandler(_events, null);
  });

  // El completer se crea dentro de la zona de esta prueba.
  DeepLinkService.resetInitialLinkForTesting();
  var processed = false;
  unawaited(DeepLinkService.initialLinkProcessed.then((_) => processed = true));

  late DeepLinkService service;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            service = DeepLinkService(ref: ref, context: context)..initialize();
            return const Scaffold();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(processed, isTrue, reason: 'El enlace inicial ya se revisó');
  return service;
}

/// Desmonta la pantalla y deja vencer la espera de la app lista, para que
/// ningún enlace navegue después de la prueba.
Future<void> _finish(WidgetTester tester, DeepLinkService service) async {
  service.dispose();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 16));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'un enlace inicial solo de campaña no gana sobre el temporizador',
    (tester) async {
      final originalReady = appReadyCompleter;
      appReadyCompleter = Completer<void>();
      addTearDown(() => appReadyCompleter = originalReady);

      final service = await _pumpService(
        tester,
        initialLink: 'https://medito.app/?utm_source=apple_search_ads',
      );

      expect(DeepLinkService.hadInitialLink, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('utm_source'), 'apple_search_ads');
      await _finish(tester, service);
    },
  );

  testWidgets('un enlace inicial que abre una pantalla sí gana', (
    tester,
  ) async {
    final originalReady = appReadyCompleter;
    appReadyCompleter = Completer<void>();
    addTearDown(() => appReadyCompleter = originalReady);

    final service = await _pumpService(
      tester,
      initialLink: 'org.meditofoundation://medito/timer/start?minutes=5',
    );

    expect(DeepLinkService.hadInitialLink, isTrue);
    await _finish(tester, service);
  });

  testWidgets('handleDeepLink dice si el enlace abre una pantalla', (
    tester,
  ) async {
    final originalReady = appReadyCompleter;
    appReadyCompleter = Completer<void>();
    addTearDown(() => appReadyCompleter = originalReady);

    final service = await _pumpService(tester);
    final timer = Uri.parse(
      'org.meditofoundation://medito/timer/start?minutes=5',
    );

    expect(
      await service.handleDeepLink(Uri.parse('https://medito.app/?utm_x=1')),
      isFalse,
    );
    expect(
      await service.handleDeepLink(Uri.parse('https://medito.app/otp/1234')),
      isFalse,
    );
    expect(
      await service.handleDeepLink(Uri.parse('mailto:someone@example.test')),
      isFalse,
    );
    expect(await service.handleDeepLink(timer), isTrue);
    // El mismo enlace repetido (Android lo entrega dos veces) responde igual.
    expect(await service.handleDeepLink(timer), isTrue);
    expect(
      await service.handleDeepLink(Uri.parse('https://medito.app/tracks/abc')),
      isTrue,
    );
    await _finish(tester, service);
  });
}
