import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/app_globals.dart' show appReadyCompleter;
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_house_content.dart';
import 'package:medito/models/timer/timer_launch.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/providers.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/providers/timer/timer_content_provider.dart';
import 'package:medito/repositories/track/track_repository.dart';
import 'package:medito/services/account/account_service.dart';
import 'package:medito/services/deep_link_service.dart';
import 'package:medito/services/timer/startup_timer_route.dart';
import 'package:medito/services/timer/timer_route_tracker.dart';
import 'package:medito/views/downloads/downloads_view.dart';
import 'package:medito/views/end_screen/end_screen_view.dart';
import 'package:medito/views/player/player_view.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/splash_view.dart';
import 'package:medito/views/timer/timer_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _firstScreen = Key('first-screen');
final _es = lookupAppLocalizations(const Locale('es'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    StartupTimerRoute.resetForTesting();
    TimerRouteTracker.openTimerViews = 0;
    SharedPreferences.setMockInitialValues({
      SharedPreferenceConstants.timerOpenOnTimer: true,
    });
  });

  tearDown(() => TimerRouteTracker.openTimerViews = 0);

  testWidgets('waits for the initial link and lets it win', (tester) async {
    final navigator = await _pumpApp(tester);
    final link = Completer<void>();
    final migration = Completer<void>();
    var migrationStarted = false;
    final decision = StartupTimerRoute.runOnce(
      navigator,
      initialLinkProcessed: link.future,
      hadInitialLink: () => true,
      migrateReminders: () {
        migrationStarted = true;
        return migration.future;
      },
      takeReminderLaunch: () async => fail('A deep link has priority'),
    );

    await tester.pump();
    expect(migrationStarted, isFalse);
    expect(find.byType(TimerView), findsNothing);
    link.complete();
    await decision;
    expect(migrationStarted, isTrue);
    expect(migration.isCompleted, isFalse);
    migration.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TimerView), findsNothing);
  });

  testWidgets('reminder launch wins over the timer preference', (tester) async {
    final navigator = await _pumpApp(tester);
    const launch = TimerLaunch(minutes: 3, minPrepSeconds: 10);
    await StartupTimerRoute.runOnce(
      navigator,
      initialLinkProcessed: Future.value(),
      hadInitialLink: () => false,
      migrateReminders: () async {},
      takeReminderLaunch: () async => launch,
    );
    await tester.pumpAndSettle();

    final timer = tester.widget<TimerView>(find.byType(TimerView));
    expect(timer.source, AnalyticsEventConstants.sourceReminderAction);
    expect(timer.launch, same(launch));
  });

  testWidgets(
    'timer preference opens once and back returns to the first screen',
    (tester) async {
      final navigator = await _pumpApp(tester);
      var reminderReads = 0;
      Future<void> decide() => StartupTimerRoute.runOnce(
        navigator,
        initialLinkProcessed: Future.value(),
        hadInitialLink: () => false,
        migrateReminders: () async {},
        takeReminderLaunch: () async {
          reminderReads++;
          return null;
        },
      );

      await Future.wait([decide(), decide()]);
      await tester.pumpAndSettle();
      final timer = tester.widget<TimerView>(find.byType(TimerView));
      expect(timer.source, AnalyticsEventConstants.sourceTimerOnly);
      expect(timer.launch, isNull);
      expect(reminderReads, 1);

      navigator.pop();
      await tester.pumpAndSettle();
      await decide();
      expect(reminderReads, 1);
      expect(find.byKey(_firstScreen), findsOneWidget);
      expect(find.byType(TimerView), findsNothing);
    },
  );

  testWidgets('timer preference leaves an existing timer alone', (
    tester,
  ) async {
    final navigator = await _pumpApp(tester);
    TimerRouteTracker.openTimerViews = 1;
    await StartupTimerRoute.runOnce(
      navigator,
      initialLinkProcessed: Future.value(),
      hadInitialLink: () => false,
      migrateReminders: () async {},
      takeReminderLaunch: () async => null,
    );
    await tester.pumpAndSettle();
    expect(find.byType(TimerView), findsNothing);
  });

  testWidgets('offline SplashView starts the timer above downloads', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const channels = [
      MethodChannel('com.llfbandit.app_links/messages'),
      MethodChannel('com.llfbandit.app_links/events'),
    ];
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    final originalReady = appReadyCompleter;
    appReadyCompleter = Completer<void>();
    addTearDown(() => appReadyCompleter = originalReady);

    DeepLinkService? links;
    final navigator = await _pumpApp(
      tester,
      email: 'app@example.test',
      home: Consumer(
        builder: (context, ref, _) {
          links ??= DeepLinkService(ref: ref, context: context)..initialize();
          return const SplashView();
        },
      ),
      overrides: [
        deviceAndAppInfoProvider.overrideWith(
          (_) async => throw StateError('Servicios sin conexión'),
        ),
        downloadedTracksProvider.overrideWith((_) async => []),
      ],
    );
    addTearDown(() => links?.dispose());

    final timer = tester.widget<TimerView>(find.byType(TimerView));
    expect(timer.source, AnalyticsEventConstants.sourceTimerOnly);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(
      tester.widget<DownloadsView>(find.byType(DownloadsView)).isRoot,
      isTrue,
    );
    expect(find.byType(SplashView), findsNothing);
  });

  testWidgets('failed account init opens the timer above downloads', (
    tester,
  ) async {
    DeepLinkService.resetInitialLinkForTesting();
    final messenger = tester.binding.defaultBinaryMessenger;
    const channels = [
      MethodChannel('com.llfbandit.app_links/messages'),
      MethodChannel('com.llfbandit.app_links/events'),
    ];
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    final originalReady = appReadyCompleter;
    appReadyCompleter = Completer<void>();
    addTearDown(() => appReadyCompleter = originalReady);

    DeepLinkService? links;
    final navigator = await _pumpApp(
      tester,
      email: 'app@example.test',
      home: Consumer(
        builder: (context, ref, _) {
          links ??= DeepLinkService(ref: ref, context: context)..initialize();
          return const SplashView();
        },
      ),
      overrides: [
        // Falla la inicialización de la cuenta: SplashView sale a Descargas
        // por su rama de error.
        accountServiceProvider.overrideWith(
          (_) => throw StateError('Cuenta sin inicializar'),
        ),
        downloadedTracksProvider.overrideWith((_) async => []),
      ],
    );
    addTearDown(() => links?.dispose());

    final timer = tester.widget<TimerView>(find.byType(TimerView));
    expect(timer.source, AnalyticsEventConstants.sourceTimerOnly);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(
      tester.widget<DownloadsView>(find.byType(DownloadsView)).isRoot,
      isFalse,
    );
  });

  for (final hasSetup in [false, true]) {
    testWidgets('skips timer end screen (setup below: $hasSetup)', (
      tester,
    ) async {
      final player = _Player(
        timerPlaybackRequest(
          mode: TimerMode.countdown,
          duration: const Duration(minutes: 1),
          filePath: '/tmp/timer.wav',
          title: _es.timerTitle,
        ),
      );
      final navigator = await _pumpApp(
        tester,
        player: player,
        home: hasSetup
            ? const TimerView(source: AnalyticsEventConstants.sourceTimerOnly)
            : const Scaffold(key: _firstScreen),
        prefs: {
          SharedPreferenceConstants.timerSkipEndScreen: true,
          SharedPreferenceConstants.timerBackground: 'black:negro',
        },
        overrides: [
          audioStateProvider.overrideWith(AudioStateNotifier.new),
          statsProvider.overrideWith(_Stats.new),
          backgroundSoundsNotifierProvider.overrideWith(_Sounds.new),
        ],
      );
      final originalSetup = hasSetup
          ? tester.element(find.byType(TimerView))
          : null;
      if (hasSetup) TimerRouteTracker.openTimerViews = 1;
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(builder: (_) => const PlayerView()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerView)),
      );
      final audio = container.read(audioStateProvider);
      container
          .read(audioStateProvider.notifier)
          .updatePlaybackState(
            audio.copyWith(
              isCompleted: true,
              position: player.request!.duration,
              runId: player.request!.timerRunId,
            ),
          );
      await tester.pumpAndSettle();

      expect(find.byType(PlayerView), findsNothing);
      expect(find.byType(EndScreenView), findsNothing);
      expect(
        find.text(_es.timerSavedSessionNoun('práctica', 1)),
        findsOneWidget,
      );
      expect(player.stops, 1);
      final setup = tester.element(find.byType(TimerView));
      if (originalSetup != null) {
        expect(setup, same(originalSetup));
      } else {
        expect(
          (setup.widget as TimerView).source,
          AnalyticsEventConstants.sourceTimerOnly,
        );
        navigator.pop();
        await tester.pumpAndSettle();
        expect(find.byKey(_firstScreen), findsOneWidget);
      }
    });
  }
}

Future<NavigatorState> _pumpApp(
  WidgetTester tester, {
  Widget home = const Scaffold(key: _firstScreen),
  String? email,
  _Player? player,
  Map<String, Object> prefs = const {},
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    PreviewShell(
      locale: const Locale('es'),
      prefs: {...prefsDark, ...prefs},
      email: email,
      overrides: [
        trackRepositoryProvider.overrideWithValue(_Tracks()),
        timerHouseContentProvider.overrideWith(_HouseContent.new),
        backgroundSoundsProvider.overrideWith((_) async => []),
        playerProvider.overrideWith(() => player ?? _Player()),
        ...overrides,
      ],
      child: home,
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<NavigatorState>(find.byType(Navigator).first);
}

class _Tracks extends Fake implements TrackRepository {
  @override
  Future<Never> fetchTrack(String trackId) =>
      Future.error(StateError('Sin conexión'));
}

class _HouseContent extends TimerHouseContentNotifier {
  @override
  TimerHouseContent build() => TimerHouseContent.fromJson({
    'words': {'session': 'práctica'},
  });
}

class _Player extends PlayerProvider {
  _Player([this.request]);

  final PlaybackRequest? request;
  int stops = 0;

  @override
  PlaybackRequest? build() => request;

  @override
  bool reserveStart(String runId) => false;

  @override
  Future<void> play(PlaybackRequest request) async {}

  @override
  void stop() => stops++;
}

class _Stats extends StatsNotifier {
  @override
  Future<LocalAllStats> build() async => LocalAllStats.empty();
}

class _Sounds extends BackgroundSoundsNotifier {
  @override
  void restoreTimerBackgroundSound(PlaybackRequest request) {}

  @override
  Future<void> stopTimerAmbient({
    required bool transportAlreadyStopped,
    Duration fade = Duration.zero,
  }) async {}
}
