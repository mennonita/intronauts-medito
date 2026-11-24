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
import 'package:medito/services/timer/timer_device_channel.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/donation/donation_page_provider.dart';
import 'package:medito/providers/providers.dart';
import 'package:medito/providers/review_service_provider.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/providers/stripe/payment_service_provider.dart';
import 'package:medito/services/review_service.dart';
import 'package:medito/src/audio_pigeon.g.dart' show Track;
import 'package:medito/views/timer/session/timer_exit_dialogs.dart';
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
final _long = timerPlaybackRequest(
  mode: TimerMode.countdown,
  duration: const Duration(minutes: 10),
  filePath: '/tmp/timer.wav',
  title: 'Temporizador',
);
final _stopwatch = timerPlaybackRequest(
  mode: TimerMode.stopwatch,
  duration: kStopwatchMaxDuration,
  filePath: '/tmp/timer.wav',
  title: 'Temporizador',
);
const _home = Key('home');

/// Proveedor falso: registra cada cierre y emite los cierres guardados como
/// el proveedor real.
class _Player extends PlayerProvider {
  _Player([PlaybackRequest? request]) : request = request ?? _request;

  final PlaybackRequest request;
  int stops = 0;
  VoidCallback? onStop;
  Object? playError;
  final saves = <bool>[];
  // `runId` que pidió cerrar cada llamada (TIMER-05).
  final closedRuns = <String>[];
  VoidCallback? onClose;
  Completer<void>? closeGate;
  Duration closeElapsed = const Duration(seconds: 90);
  bool discardFails = false;
  final _closes = StreamController<TimerRunCloseResult>.broadcast();

  @override
  PlaybackRequest build() => request;

  @override
  Future<void> play(PlaybackRequest request) async {
    final error = playError;
    if (error != null) throw error;
  }

  @override
  void stop() {
    stops++;
    onStop?.call();
  }

  @override
  Stream<TimerRunCloseResult> get timerCloses => _closes.stream;

  @override
  Future<TimerRunCloseResult?> closeTimer({
    required String runId,
    bool save = true,
  }) async {
    closedRuns.add(runId);
    // Como el proveedor real: otra corrida no se toca.
    if (runId != state?.timerRunId) return null;
    saves.add(save);
    onClose?.call();
    await closeGate?.future;
    if (!save && discardFails) {
      return TimerRunCloseResult(
        runId,
        closeElapsed,
        stopped: false,
        saved: false,
      );
    }
    final result = TimerRunCloseResult(runId, closeElapsed, saved: save);
    if (result.saved) _closes.add(result);
    return result;
  }

  /// Otra corrida ocupa el reproductor (por ejemplo, desde un enlace).
  void replaceRun(PlaybackRequest other) => state = other;

  /// Cierre que llega sin diálogo (por ejemplo, desde la notificación).
  void systemClose(Duration elapsed, {String? runId}) =>
      _closes.add(TimerRunCloseResult(runId ?? request.timerRunId, elapsed));
}

class _Sounds extends BackgroundSoundsNotifier {
  int stopCalls = 0;
  int ambientStops = 0;

  @override
  void stopBackgroundSound() => stopCalls++;

  @override
  Future<void> stopTimerAmbient({
    required bool transportAlreadyStopped,
    Duration fade = Duration.zero,
  }) async {
    ambientStops++;
  }

  @override
  void restoreTimerBackgroundSound(PlaybackRequest request) {}
}

class _Dnd extends DndNotifier {
  int calls = 0;

  @override
  Future<void> setDndMode(bool enable) async => calls++;
}

class _Stats extends StatsNotifier {
  @override
  Future<LocalAllStats> build() async => previewStats;
}

class _Review implements ReviewService {
  @override
  Future<void> checkAndRequestReview() async {}
}

class _Harness {
  _Harness(this.player, this.sounds, this.dnd, this.container);

  final _Player player;
  final _Sounds sounds;
  final _Dnd dnd;
  final ProviderContainer container;
}

Future<_Harness> _openPlayer(
  WidgetTester tester, {
  _Player? player,
  Map<String, Object> prefs = const {},
}) async {
  final fake = player ?? _Player();
  final sounds = _Sounds();
  final dnd = _Dnd();
  await tester.pumpWidget(
    PreviewShell(
      locale: const Locale('es'),
      prefs: {
        ...prefsDark,
        SharedPreferenceConstants.timerBackground: 'black:negro',
        ...prefs,
      },
      overrides: [
        playerProvider.overrideWith(() => fake),
        dndProvider.overrideWith(() => dnd),
        audioStateProvider.overrideWith(AudioStateNotifier.new),
        backgroundSoundsProvider.overrideWith((ref) async => []),
        backgroundSoundsNotifierProvider.overrideWith(() => sounds),
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
  return _Harness(fake, sounds, dnd, container);
}

void _update(
  ProviderContainer container,
  PlaybackRequest request, {
  required int positionMs,
  bool completed = false,
  bool playing = true,
  String? runId,
}) {
  container
      .read(audioStateProvider.notifier)
      .updatePlaybackState(
        container
            .read(audioStateProvider)
            .copyWith(
              position: positionMs,
              duration: request.duration,
              isPlaying: playing && !completed,
              isCompleted: completed,
              runId: runId ?? request.timerRunId,
              track: Track(
                id: request.trackId,
                fileId: request.fileId,
                title: '',
                description: '',
                imageUrl: '',
              ),
            ),
      );
}

Future<void> _systemBack(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  await navigator.maybePop();
  await tester.pump();
}

Future<void> _disposeEndScreen(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
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

  testWidgets('✕ con menos de un minuto sale sin preguntar y sin guardar', (
    tester,
  ) async {
    final h = await _openPlayer(tester);
    expect(find.byType(TimerSessionLayout), findsOneWidget);
    _update(h.container, _request, positionMs: 30000);
    await tester.pumpAndSettle();

    final session = find.byType(TimerSessionLayout);
    final route = ModalRoute.of(tester.element(session))!;
    var playerWasCurrentAtClose = false;
    h.player.onClose = () => playerWasCurrentAtClose = route.isCurrent;
    await tester.tap(find.text('Pantalla'));
    await tester.pumpAndSettle();
    expect(find.byType(TimerBackgroundPicker), findsOneWidget);

    tester.widget<TimerSessionLayout>(session).onClosePressed();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(playerWasCurrentAtClose, isTrue);
    expect(find.byType(TimerBackgroundPicker), findsNothing);
    expect(find.byType(PlayerView), findsNothing);
    expect(find.byKey(_home), findsOneWidget);
    // Descarta en el servicio (R102), nunca con la parada simple.
    expect(h.player.saves, [false]);
    expect(h.player.stops, 0);
    // No molestar lo restaura el servicio nativo: Dart ya no lo toca.
    expect(h.dnd.calls, 0);
  });

  testWidgets('«atrás» con menos de un minuto también sale sin preguntar', (
    tester,
  ) async {
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 30000);
    await tester.pump();
    await _systemBack(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(PlayerView), findsNothing);
    expect(h.player.saves, [false]);
  });

  for (final viaBack in [false, true]) {
    final how = viaBack ? '«atrás»' : '✕';
    testWidgets('$how a los 90 s pregunta con tres opciones', (tester) async {
      final h = await _openPlayer(tester);
      _update(h.container, _request, positionMs: 90000);
      await tester.pump();
      if (viaBack) {
        await _systemBack(tester);
      } else {
        await tester.tap(find.byTooltip('Salir'));
      }
      await tester.pumpAndSettle();
      expect(find.text('¿Salir de la sesión?'), findsOneWidget);
      expect(find.text('Llevas 1 min. ¿Quieres guardarlos?'), findsOneWidget);
      for (final label in [
        'Seguir meditando',
        'Salir sin guardar',
        'Guardar y salir',
      ]) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.text('Seguir meditando'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TimerSessionLayout), findsOneWidget);
      expect(h.player.saves, isEmpty);
      expect(h.player.stops, 0);
    });
  }

  testWidgets(
    'iOS: el gesto lateral abre la misma salida con tres opciones (TIMER-08)',
    (tester) async {
      final h = await _openPlayer(tester);
      _update(h.container, _request, positionMs: 90000);
      await tester.pump();
      // El gesto real de iOS: arrastrar desde el borde izquierdo.
      await tester.dragFrom(const Offset(4, 300), const Offset(320, 0));
      await tester.pumpAndSettle();
      expect(find.text('¿Salir de la sesión?'), findsOneWidget);
      for (final label in [
        'Seguir meditando',
        'Salir sin guardar',
        'Guardar y salir',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      // La pantalla sigue ahí: el gesto nunca la cierra sin preguntar.
      expect(find.byType(TimerSessionLayout), findsOneWidget);

      await tester.tap(find.text('Seguir meditando'));
      await tester.pumpAndSettle();
      expect(find.byType(TimerSessionLayout), findsOneWidget);
      expect(h.player.saves, isEmpty);

      await tester.dragFrom(const Offset(4, 300), const Offset(320, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salir sin guardar'));
      await tester.pumpAndSettle();
      expect(h.player.saves, [false]);
      expect(find.byType(PlayerView), findsNothing);
      expect(find.byKey(_home), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS: «Guardar y salir» desde el gesto lateral guarda (TIMER-08)',
    (tester) async {
      final h = await _openPlayer(tester);
      _update(h.container, _request, positionMs: 90000);
      await tester.pump();
      await tester.dragFrom(const Offset(4, 300), const Offset(320, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar y salir'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(h.player.saves, [true]);
      expect(find.byType(EndScreenView), findsOneWidget);
      await _disposeEndScreen(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'si otra corrida ocupa el reproductor durante el diálogo, no se cierra (TIMER-05)',
    (tester) async {
      final h = await _openPlayer(tester);
      _update(h.container, _request, positionMs: 90000);
      await tester.pump();
      await tester.tap(find.byTooltip('Salir'));
      await tester.pumpAndSettle();
      expect(find.text('¿Salir de la sesión?'), findsOneWidget);
      // Mientras el diálogo espera, empieza otra corrida.
      h.player.replaceRun(_long);
      await tester.tap(find.text('Salir sin guardar'));
      await tester.pumpAndSettle();
      expect(h.player.closedRuns, isEmpty);
      expect(h.player.saves, isEmpty);
      expect(h.player.stops, 0);
      expect(find.byType(PlayerView), findsNothing);
    },
  );

  testWidgets('otra corrida tras el diálogo: no borra su posición compartida '
      '(TIMER-REVIEW-05)', (tester) async {
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 90000);
    await tester.pump();
    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();
    // Mientras el diálogo espera, otra corrida toma el reproductor y ya
    // publica su posición.
    h.player.replaceRun(_long);
    _update(h.container, _long, positionMs: 45000);
    await tester.tap(find.text('Salir sin guardar'));
    await tester.pumpAndSettle();

    expect(find.byType(PlayerView), findsNothing);
    expect(h.player.closedRuns, isEmpty);
    expect(h.player.stops, 0);
    final audio = h.container.read(audioStateProvider);
    expect(audio.runId, _long.timerRunId);
    expect(audio.position, 45000);
    expect(h.sounds.stopCalls, 0);
  });

  testWidgets('la pantalla vieja solo quita su ruta, no la de la otra corrida '
      '(TIMER-REVIEW-05)', (tester) async {
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 90000);
    await tester.pump();
    final oldSession = find.byType(TimerSessionLayout);
    final oldLayout = tester.widget<TimerSessionLayout>(oldSession);
    final oldRoute = ModalRoute.of(tester.element(oldSession))!;
    // La otra corrida abre su propia pantalla encima de la vieja.
    h.player.replaceRun(_long);
    _update(h.container, _long, positionMs: 45000);
    const newScreen = Key('pantalla-de-la-otra-corrida');
    unawaited(
      oldRoute.navigator!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(key: newScreen)),
      ),
    );
    await tester.pumpAndSettle();
    expect(oldRoute.isCurrent, isFalse);

    // La pantalla vieja intenta salir (por ejemplo, un ✕ que llegó tarde).
    oldLayout.onClosePressed();
    await tester.pumpAndSettle();

    expect(find.byKey(newScreen), findsOneWidget);
    expect(find.byType(PlayerView, skipOffstage: false), findsNothing);
    expect(oldRoute.isActive, isFalse);
    expect(h.player.closedRuns, isEmpty);
    expect(h.player.stops, 0);
    final audio = h.container.read(audioStateProvider);
    expect(audio.runId, _long.timerRunId);
    expect(audio.position, 45000);
  });

  testWidgets('cada cierre pide el runId de esta pantalla (TIMER-05)', (
    tester,
  ) async {
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 90000);
    await tester.pump();
    // El cierre de otra corrida no abre el resumen de esta.
    h.player.systemClose(const Duration(minutes: 2), runId: 'otra-corrida');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(EndScreenView), findsNothing);
    expect(find.byType(TimerSessionLayout), findsOneWidget);

    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salir sin guardar'));
    await tester.pumpAndSettle();
    expect(h.player.closedRuns, [_request.timerRunId]);
  });

  testWidgets('«Guardar y salir» guarda y abre el resumen', (tester) async {
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 90000);
    await tester.pump();
    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar y salir'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(h.player.saves, [true]);
    expect(find.byType(PlayerView), findsNothing);
    final end = tester.widget<EndScreenView>(find.byType(EndScreenView));
    expect(end.timerElapsed, const Duration(seconds: 90));
    expect(end.request.timerRunId, _request.timerRunId);
    await _disposeEndScreen(tester);
  });

  testWidgets('«Salir sin guardar» descarta, no guarda y vuelve', (
    tester,
  ) async {
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 90000);
    await tester.pump();
    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salir sin guardar'));
    await tester.pumpAndSettle();
    expect(h.player.saves, [false]);
    expect(h.player.stops, 0);
    expect(find.byType(EndScreenView), findsNothing);
    expect(find.byType(PlayerView), findsNothing);
    expect(find.byKey(_home), findsOneWidget);
    expect(
      find.text('Las sesiones de menos de un minuto no se guardan'),
      findsNothing,
    );
  });

  testWidgets('si no se pudo descartar, la sesión sigue y se avisa', (
    tester,
  ) async {
    final player = _Player()..discardFails = true;
    final h = await _openPlayer(tester, player: player);
    _update(h.container, _request, positionMs: 90000);
    await tester.pump();
    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salir sin guardar'));
    await tester.pump();
    await tester.pump();
    expect(h.player.saves, [false]);
    expect(h.player.stops, 0);
    expect(find.byType(TimerSessionLayout), findsOneWidget);
    expect(find.text('No se pudo salir. Inténtalo de nuevo.'), findsOneWidget);
    // Los controles vuelven a responder.
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Pantalla'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('mientras se descarta, las hojas quedan bloqueadas', (
    tester,
  ) async {
    final player = _Player()..closeGate = Completer<void>();
    final h = await _openPlayer(tester, player: player);
    _update(h.container, _request, positionMs: 30000);
    await tester.pump();

    await tester.tap(find.byTooltip('Salir'));
    await tester.tap(find.text('Pantalla'));
    await tester.pump();
    expect(h.player.saves, [false]);
    expect(find.byType(TimerBackgroundPicker), findsNothing);
    for (final label in ['Pantalla', 'Sonido de fondo']) {
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed,
        isNull,
      );
    }
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Terminar'),
          )
          .onPressed,
      isNull,
    );
    expect(find.byType(BackgroundSoundView), findsNothing);
    player.closeGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerView), findsNothing);
    expect(find.byKey(_home), findsOneWidget);
  });

  group('«Terminar»', () {
    testWidgets('con tiempo por delante pregunta antes de terminar', (
      tester,
    ) async {
      final h = await _openPlayer(tester);
      _update(h.container, _request, positionMs: 50000);
      await tester.pump();
      await tester.tap(find.text('Terminar'));
      await tester.pumpAndSettle();
      expect(find.text('¿Terminar la sesión?'), findsOneWidget);
      // Menos de un minuto: avisa que no se guardará.
      expect(
        find.text(
          'Llevas menos de un minuto. Las sesiones de menos de un minuto no se guardan.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Seguir meditando'));
      await tester.pumpAndSettle();
      expect(h.player.saves, isEmpty);
      expect(find.byType(TimerSessionLayout), findsOneWidget);
    });

    testWidgets('confirmar una sesión corta no repite el aviso al salir', (
      tester,
    ) async {
      final player = _Player()..closeElapsed = const Duration(seconds: 50);
      final h = await _openPlayer(tester, player: player);
      _update(h.container, _request, positionMs: 50000);
      await tester.pump();
      await tester.tap(find.text('Terminar'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Terminar'));
      await tester.pumpAndSettle();
      expect(h.player.saves, [true]);
      expect(find.byType(PlayerView), findsNothing);
      expect(find.byType(EndScreenView), findsNothing);
      expect(
        find.text('Las sesiones de menos de un minuto no se guardan'),
        findsNothing,
      );
    });

    testWidgets('con un minuto o más por delante dice lo que llevas', (
      tester,
    ) async {
      final h = await _openPlayer(tester, player: _Player(_long));
      _update(h.container, _long, positionMs: 61000);
      await tester.pump();
      await tester.tap(find.text('Terminar'));
      await tester.pumpAndSettle();
      expect(find.text('Llevas 1 min.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Terminar'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(h.player.saves, [true]);
      expect(find.byType(EndScreenView), findsOneWidget);
      await _disposeEndScreen(tester);
    });

    testWidgets('con menos de un minuto por delante termina sin preguntar', (
      tester,
    ) async {
      final h = await _openPlayer(tester);
      _update(h.container, _request, positionMs: 61000);
      await tester.pump();
      await tester.tap(find.text('Terminar'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(h.player.saves, [true]);
      expect(find.byType(EndScreenView), findsOneWidget);
      await _disposeEndScreen(tester);
    });

    testWidgets('el cronómetro con más de un minuto termina sin preguntar', (
      tester,
    ) async {
      final player = _Player(_stopwatch)
        ..closeElapsed = const Duration(minutes: 3);
      final h = await _openPlayer(tester, player: player);
      _update(h.container, _stopwatch, positionMs: 180000);
      await tester.pump();
      await tester.tap(find.text('Terminar'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(h.player.saves, [true]);
      final end = tester.widget<EndScreenView>(find.byType(EndScreenView));
      expect(end.timerElapsed, const Duration(minutes: 3));
      await _disposeEndScreen(tester);
    });
  });

  testWidgets('un cierre corto sin diálogo avisa que no se guardó', (
    tester,
  ) async {
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 30000);
    await tester.pump();
    h.player.systemClose(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(
      find.text('Las sesiones de menos de un minuto no se guardan'),
      findsOneWidget,
    );
    expect(find.byType(PlayerView), findsNothing);
  });

  testWidgets('el fin natural deja las campanas al audio y abre el resumen', (
    tester,
  ) async {
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 6000);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pantalla'));
    await tester.pumpAndSettle();
    expect(find.byType(TimerBackgroundPicker), findsOneWidget);

    _update(
      h.container,
      _request,
      positionMs: _request.duration,
      completed: true,
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TimerBackgroundPicker), findsNothing);
    expect(find.byType(PlayerView), findsNothing);
    final end = tester.widget<EndScreenView>(find.byType(EndScreenView));
    expect(end.timerElapsed, const Duration(minutes: 2));
    // SES-06: la pantalla no apaga campanas ni fondo; solo cierra su estado.
    expect(h.sounds.stopCalls, 0);
    expect(h.sounds.ambientStops, 1);
    expect(h.player.stops, 1);
    expect(h.dnd.calls, 0);
    await _disposeEndScreen(tester);
  });

  testWidgets('el final de otra corrida no abre el resumen de esta', (
    tester,
  ) async {
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 6000);
    await tester.pump();
    _update(
      h.container,
      _request,
      positionMs: _request.duration,
      completed: true,
      runId: 'otra-corrida',
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(EndScreenView), findsNothing);
    expect(find.byType(TimerSessionLayout), findsOneWidget);
    expect(h.player.stops, 0);

    _update(h.container, _request, positionMs: 7000);
    await tester.pump();
    _update(
      h.container,
      _request,
      positionMs: _request.duration,
      completed: true,
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(EndScreenView), findsOneWidget);
    await _disposeEndScreen(tester);
  });

  testWidgets('un error al cargar el temporizador vuelve a preparar', (
    tester,
  ) async {
    final player = _Player()..playError = Exception('sin audio');
    final h = await _openPlayer(tester, player: player);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerView), findsNothing);
    expect(find.byKey(_home), findsOneWidget);
    expect(
      find.text('No se pudo iniciar el temporizador. Inténtalo de nuevo.'),
      findsOneWidget,
    );
    expect(h.player.stops, 0);
  });

  testWidgets('timerStartFailed de esta corrida vuelve; el de otra no', (
    tester,
  ) async {
    final h = await _openPlayer(tester);
    h.player.timerStartFailed.value = 'otra-corrida';
    await tester.pumpAndSettle();
    expect(find.byType(TimerSessionLayout), findsOneWidget);

    h.player.timerStartFailed.value = _request.timerRunId;
    await tester.pumpAndSettle();
    expect(find.byType(PlayerView), findsNothing);
    expect(find.byKey(_home), findsOneWidget);
    expect(
      find.text('No se pudo iniciar el temporizador. Inténtalo de nuevo.'),
      findsOneWidget,
    );
    expect(h.player.saves, isEmpty);
  });

  testWidgets('con «Pantalla encendida» la mantiene y la suelta al salir', (
    tester,
  ) async {
    final calls = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    TimerDeviceChannel.debugIsAndroid = true;
    messenger.setMockMethodCallHandler(
      const MethodChannel('intronauts/timer_device'),
      (call) async {
        if (call.method == 'keepScreenOn') {
          calls.add((call.arguments as Map)['on']);
        }
        return null;
      },
    );
    addTearDown(() {
      TimerDeviceChannel.debugIsAndroid = null;
      messenger.setMockMethodCallHandler(
        const MethodChannel('intronauts/timer_device'),
        null,
      );
    });
    final h = await _openPlayer(
      tester,
      prefs: {SharedPreferenceConstants.timerKeepScreenOn: true},
    );
    expect(calls, [true]);
    _update(h.container, _request, positionMs: 30000);
    await tester.pump();
    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerView), findsNothing);
    expect(calls, [true, false]);
  });

  testWidgets('sin «Pantalla encendida» no toca la pantalla', (tester) async {
    final calls = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    TimerDeviceChannel.debugIsAndroid = true;
    messenger.setMockMethodCallHandler(
      const MethodChannel('intronauts/timer_device'),
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    addTearDown(() {
      TimerDeviceChannel.debugIsAndroid = null;
      messenger.setMockMethodCallHandler(
        const MethodChannel('intronauts/timer_device'),
        null,
      );
    });
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 30000);
    await tester.pump();
    await tester.tap(find.byTooltip('Salir'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
  });

  testWidgets('Sonido de fondo abre la hoja de sonido existente', (
    tester,
  ) async {
    final h = await _openPlayer(tester);
    _update(h.container, _request, positionMs: 6000);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sonido de fondo'));
    await tester.pumpAndSettle();
    expect(find.byType(BackgroundSoundView), findsOneWidget);
    expect(find.byType(TimerBackgroundPicker), findsNothing);
  });

  test('el umbral de salir sin preguntar es un minuto', () {
    expect(kTimerExitConfirmMinMs, kMinRecordedTimerSession.inMilliseconds);
  });
}
