import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/events/donation/donation_page_model.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/me/me_model.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/stripe/paywall_config_model.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/donation/donation_page_provider.dart';
import 'package:medito/providers/providers.dart';
import 'package:medito/providers/review_service_provider.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/providers/stripe/payment_service_provider.dart';
import 'package:medito/services/review_service.dart';
import 'package:medito/src/audio_pigeon.g.dart' show Track;
import 'package:medito/views/background_sound/background_sound_view.dart';
import 'package:medito/views/end_screen/end_screen_view.dart';
import 'package:medito/views/home/previews/home_previews.dart';
import 'package:medito/views/player/player_view.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/timer/session/timer_background_picker.dart';
import 'package:medito/views/timer/session/timer_session_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/firebase_analytics_test_helper.dart';
import '../../../helpers/firebase_test_helper.dart';

final _request = timerPlaybackRequest(
  mode: TimerMode.countdown,
  duration: const Duration(minutes: 2),
  filePath: '/tmp/timer.wav',
  title: 'Temporizador',
);
const _home = Key('home');

class _Player extends PlayerProvider {
  int stops = 0;
  VoidCallback? onStop;

  @override
  PlaybackRequest build() => _request;

  @override
  Future<void> play(PlaybackRequest request) async {}

  @override
  void stop() {
    stops++;
    onStop?.call();
  }
}

class _Sounds extends BackgroundSoundsNotifier {
  @override
  void stopBackgroundSound() {}

  @override
  void restoreTimerBackgroundSound(PlaybackRequest request) {}
}

class _Dnd extends DndNotifier {
  Completer<void>? pending;
  int disableCalls = 0;

  @override
  Future<void> setDndMode(bool enable) async {
    if (enable) return;
    disableCalls++;
    await pending?.future;
  }
}

class _Stats extends StatsNotifier {
  @override
  Future<LocalAllStats> build() async => previewStats;
}

class _Review implements ReviewService {
  @override
  Future<void> checkAndRequestReview() async {}
}

Future<ProviderContainer> _openPlayer(
  WidgetTester tester,
  _Player player,
  _Dnd dnd,
) async {
  await tester.pumpWidget(
    PreviewShell(
      locale: const Locale('es'),
      prefs: {
        ...prefsDark,
        SharedPreferenceConstants.timerBackground: 'black:negro',
      },
      overrides: [
        playerProvider.overrideWith(() => player),
        dndProvider.overrideWith(() => dnd),
        audioStateProvider.overrideWith(AudioStateNotifier.new),
        backgroundSoundsProvider.overrideWith((ref) async => []),
        backgroundSoundsNotifierProvider.overrideWith(_Sounds.new),
        statsProvider.overrideWith(_Stats.new),
        endScreenPaywallConfigProvider.overrideWith(
          (_) => Completer<PaywallConfigModel>().future,
        ),
        reviewServiceProvider.overrideWithValue(_Review()),
        meProvider.overrideWith((_) async => const MeModel(id: 'test-user')),
        fetchDonationPageProvider.overrideWith(
          (_) async => const DonationPageModel(
            title: 'Apoya a Medito',
            text: 'Tu apoyo mantiene Medito gratis.',
            buttons: [],
          ),
        ),
      ],
      child: const Scaffold(key: _home),
    ),
  );
  final homeContext = tester.element(find.byKey(_home));
  final container = ProviderScope.containerOf(homeContext);
  unawaited(
    Navigator.of(
      homeContext,
    ).push<void>(MaterialPageRoute(builder: (_) => const PlayerView())),
  );
  await tester.pumpAndSettle();
  expect(find.byType(TimerSessionLayout), findsOneWidget);
  expect(find.byType(PlayerScreenLayout), findsNothing);
  return container;
}

void _update(ProviderContainer container, {required bool completed}) {
  container
      .read(audioStateProvider.notifier)
      .updatePlaybackState(
        container
            .read(audioStateProvider)
            .copyWith(
              position: completed ? _request.duration : 6000,
              duration: _request.duration,
              isPlaying: !completed,
              isCompleted: completed,
              track: Track(
                id: _request.trackId,
                fileId: _request.fileId,
                title: '',
                description: '',
                imageUrl: '',
              ),
            ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (_) async => 0,
    );
    await FirebaseTestHelper.initializeFirebaseForTest();
    FirebaseAnalyticsTestHelper.setupFirebaseAnalyticsMocks();
  });

  testWidgets(
    'Cerrar quita la hoja antes de detener y salir del temporizador',
    (tester) async {
      final player = _Player();
      final dnd = _Dnd();
      final container = await _openPlayer(tester, player, dnd);
      _update(container, completed: false);
      await tester.pumpAndSettle();

      final session = find.byType(TimerSessionLayout);
      final route = ModalRoute.of(tester.element(session))!;
      var playerWasCurrentAtStop = false;
      player.onStop = () => playerWasCurrentAtStop = route.isCurrent;
      await tester.tap(find.text('Fondo'));
      await tester.pumpAndSettle();
      expect(find.byType(TimerBackgroundPicker), findsOneWidget);

      tester.widget<TimerSessionLayout>(session).onClosePressed();
      expect(playerWasCurrentAtStop, isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(TimerBackgroundPicker), findsNothing);
      expect(find.byType(PlayerView), findsNothing);
      expect(find.byKey(_home), findsOneWidget);
      expect(player.stops, 1);
      expect(dnd.disableCalls, 1);
    },
  );

  testWidgets('Cerrar bloquea hojas mientras espera a No molestar', (
    tester,
  ) async {
    final player = _Player();
    final dnd = _Dnd()..pending = Completer<void>();
    final container = await _openPlayer(tester, player, dnd);
    _update(container, completed: false);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Cerrar'));
    await tester.tap(find.text('Fondo'));
    await tester.pump();
    expect(dnd.disableCalls, 1);
    expect(find.byType(TimerBackgroundPicker), findsNothing);
    for (final label in ['Fondo', 'Sonido de fondo']) {
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text(label));
    }
    expect(find.byType(BackgroundSoundView), findsNothing);

    final sessionContext = tester.element(find.byType(TimerSessionLayout));
    unawaited(showTimerBackgroundPicker(sessionContext));
    await tester.pumpAndSettle();
    expect(find.byType(TimerBackgroundPicker), findsOneWidget);
    dnd.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TimerBackgroundPicker), findsNothing);
    expect(find.byType(PlayerView), findsNothing);
    expect(find.byKey(_home), findsOneWidget);
    expect(player.stops, 1);
  });

  testWidgets('el fin natural quita la hoja y abre el resumen de la sesión', (
    tester,
  ) async {
    final player = _Player();
    final dnd = _Dnd();
    final container = await _openPlayer(tester, player, dnd);
    _update(container, completed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fondo'));
    await tester.pumpAndSettle();
    expect(find.byType(TimerBackgroundPicker), findsOneWidget);

    _update(container, completed: true);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TimerBackgroundPicker), findsNothing);
    expect(find.byType(PlayerView), findsNothing);
    expect(find.byType(EndScreenView), findsOneWidget);
    expect(player.stops, 1);
    expect(dnd.disableCalls, 1);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Sonido de fondo abre la hoja de sonido existente', (
    tester,
  ) async {
    final container = await _openPlayer(tester, _Player(), _Dnd());
    _update(container, completed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sonido de fondo'));
    await tester.pumpAndSettle();
    expect(find.byType(BackgroundSoundView), findsOneWidget);
    expect(find.byType(TimerBackgroundPicker), findsNothing);
  });
}
