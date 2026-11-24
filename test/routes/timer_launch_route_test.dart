import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/app_globals.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/providers/providers.dart';
import 'package:medito/routes/routes.dart';
import 'package:medito/services/analytics/firebase_analytics_service.dart';
import 'package:medito/services/deep_link_service.dart';
import 'package:medito/views/timer/timer_view.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Analytics extends Mock implements FirebaseAnalyticsService {}

class _RouteObserver extends NavigatorObserver {
  MaterialPageRoute<bool>? lastPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is MaterialPageRoute<bool>) lastPush = route;
  }
}

void main() {
  test('lee solo rutas completas de arranque del temporizador', () {
    final launch = timerLaunchForRoute(TypeConstants.route, const [
      null,
      'timer/startup?minutes=20',
      'timer/start?minutes=10',
    ]);
    expect(launch?.minutes, 10);
    expect(timerLaunchForRoute(TypeConstants.route, ['timer']), isNull);
    expect(
      timerLaunchForRoute(TypeConstants.track, ['timer/start?minutes=10']),
      isNull,
    );
  });

  for (final path in ['timer/start?minutes=10', 'timer']) {
    testWidgets('abre TimerView con la ruta $path', (tester) async {
      final observer = _RouteObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [observer],
          home: const Scaffold(),
        ),
      );
      const source = AnalyticsEventConstants.sourceShortcut;

      final navigation = handleNavigation(
        TypeConstants.route,
        [path],
        tester.element(find.byType(Scaffold)),
        timerSource: source,
      );
      final route = observer.lastPush!;
      final timer = route.builder(navigatorKey.currentContext!) as TimerView;
      expect(timer.source, source);
      if (path == 'timer') {
        expect(timer.launch, isNull);
      } else {
        expect(timer.launch?.minutes, 10);
      }

      navigatorKey.currentState!.removeRoute(route);
      await navigation;
    });
  }

  for (final root in [
    'org.meditofoundation://medito/timer/start',
    'https://medito.app/timer/start',
    'org.meditofoundation://timer/start',
  ]) {
    testWidgets('espera la app y abre TimerView desde $root', (tester) async {
      final previousReady = appReadyCompleter;
      appReadyCompleter = Completer<void>();
      addTearDown(() => appReadyCompleter = previousReady);
      SharedPreferences.setMockInitialValues({});
      final analytics = _Analytics();
      final observer = _RouteObserver();
      late DeepLinkService service;
      var playerReads = 0;
      when(
        () => analytics.logEvent(
          name: AnalyticsEventConstants.homeWidgetTapped,
          parameters: any(named: 'parameters'),
        ),
      ).thenAnswer((_) async {});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            analyticsServiceProvider.overrideWithValue(analytics),
            playerProvider.overrideWith(() {
              playerReads++;
              throw StateError('El enlace intentó acceder al reproductor.');
            }),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            navigatorObservers: [observer],
            home: Consumer(
              builder: (context, ref, child) {
                service = DeepLinkService(context: context, ref: ref);
                return const Scaffold();
              },
            ),
          ),
        ),
      );

      final uri = Uri.parse('$root?minutes=10&source=home_widget&widget=timer');
      await service.handleDeepLink(uri);
      expect(observer.lastPush, isNull);
      appReadyCompleter.complete();
      await tester.idle();

      // Revisa el destino antes de montar la pantalla que inicia la sesión.
      final route = observer.lastPush!;
      final timer = route.builder(navigatorKey.currentContext!) as TimerView;
      expect(timer.source, AnalyticsEventConstants.sourceDeeplink);
      expect(timer.launch?.minutes, 10);
      expect(playerReads, 0);
      verify(
        () => analytics.logEvent(
          name: AnalyticsEventConstants.homeWidgetTapped,
          parameters: {
            AnalyticsEventConstants.paramWidgetType: 'timer',
            'platform': 'android',
          },
        ),
      ).called(1);
      navigatorKey.currentState!.removeRoute(route);
      service.dispose();
    });
  }
}
