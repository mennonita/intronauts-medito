import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_background.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/timer/timer_background_provider.dart';
import 'package:medito/src/audio_pigeon.g.dart' show Track;
import 'package:medito/views/player/widgets/artist_title_widget.dart';
import 'package:medito/views/player/widgets/player_buttons/player_buttons_widget.dart';
import 'package:medito/views/timer/session/timer_background_picker.dart';
import 'package:medito/views/timer/session/timer_backgrounds.dart';
import 'package:medito/views/timer/session/timer_session_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';

PlaybackRequest _request({
  TimerMode mode = TimerMode.countdown,
  bool extraTime = false,
}) => timerPlaybackRequest(
  mode: mode,
  duration: mode == TimerMode.stopwatch
      ? kStopwatchMaxDuration
      : const Duration(minutes: 2),
  extraTime: extraTime,
  filePath: '/tmp/timer.wav',
  title: 'Título de audio',
);

void _noop() {}

TimerSessionLayout _layout(
  PlaybackRequest request, {
  bool playing = false,
  bool loading = false,
  VoidCallback onClose = _noop,
  VoidCallback onEnd = _noop,
  VoidCallback onPlayPause = _noop,
}) => TimerSessionLayout(
  request: request,
  isPlaying: playing,
  isAudioLoading: loading,
  isBackgroundSoundSelected: false,
  onPlayPausePressed: onPlayPause,
  onClosePressed: onClose,
  onEndSession: onEnd,
);

Widget _app(
  ProviderContainer container,
  Widget home, {
  bool accessible = false,
  bool reduceMotion = true,
  double textScale = 1,
  GlobalKey<NavigatorState>? navigator,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    navigatorKey: navigator,
    locale: const Locale('es'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    theme: ThemeData.light(),
    darkTheme: ThemeData.dark(),
    themeAnimationDuration: Duration.zero,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        accessibleNavigation: accessible,
        disableAnimations: reduceMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: home,
  ),
);

void _audioUpdate(
  ProviderContainer container,
  PlaybackRequest request, {
  int position = 0,
  bool playing = false,
  bool completed = false,
  int? duration,
  String? trackId,
  String? fileId,
}) {
  container
      .read(audioStateProvider.notifier)
      .updatePlaybackState(
        container
            .read(audioStateProvider)
            .copyWith(
              position: position,
              isPlaying: playing,
              isCompleted: completed,
              duration: duration ?? request.duration,
              track: Track(
                id: trackId ?? request.trackId,
                fileId: fileId ?? request.fileId,
                title: '',
                description: '',
                imageUrl: '',
              ),
            ),
      );
}

Iterable<double> _controlOpacities(WidgetTester tester) => tester
    .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
    .map((widget) => widget.opacity);

void main() {
  late ProviderContainer container;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        audioStateProvider.overrideWith(AudioStateNotifier.new),
      ],
    );
    addTearDown(container.dispose);
  });

  testWidgets('muestra la cuenta grande y los controles del temporizador', (
    tester,
  ) async {
    var closed = 0;
    var ended = 0;
    var toggled = 0;
    await tester.pumpWidget(
      _app(
        container,
        _layout(
          _request(),
          onClose: () => closed++,
          onEnd: () => ended++,
          onPlayPause: () => toggled++,
        ),
      ),
    );
    expect(find.text('Temporizador'), findsOneWidget);
    final count = find.text('2:00');
    expect(count, findsOneWidget);
    final style = tester.widget<Text>(count).style!;
    expect(style.fontSize, greaterThanOrEqualTo(64));
    expect(style.fontWeight, FontWeight.w300);
    expect(style.fontFeatures, const [FontFeature.tabularFigures()]);
    expect(tester.getCenter(count).dy, closeTo(600 * timerCountCenter, 20));
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(ArtistTitleWidget), findsNothing);
    expect(find.byType(PlayerButtonsWidget), findsNothing);
    expect(find.text('Título de audio'), findsNothing);
    expect(find.text('Sonido de fondo'), findsOneWidget);
    await tester.tap(find.byTooltip('Continuar'));
    await tester.tap(find.byTooltip('Cerrar'));
    await tester.tap(find.text('Terminar'));
    expect(toggled, 1);
    expect(closed, 1);
    expect(ended, 1);
  });

  testWidgets('espera una actualización al repetir un temporizador idéntico', (
    tester,
  ) async {
    final first = _request().copyWith(timerSeed: 1);
    _audioUpdate(container, first, position: 164000, completed: true);
    await tester.pumpWidget(_app(container, _layout(first)));
    expect(find.text('2:00'), findsOneWidget);

    _audioUpdate(container, first, position: 30000, playing: true);
    await tester.pump();
    expect(find.text('1:30'), findsOneWidget);

    final second = first.copyWith(timerSeed: 2);
    await tester.pumpWidget(_app(container, _layout(second)));
    expect(find.text('2:00'), findsOneWidget);
    expect(find.text('1:30'), findsNothing);
  });

  testWidgets(
    'ignora reinicios, IDs ajenos y pausas sin la duración del archivo',
    (tester) async {
      final request = _request(extraTime: true);
      await tester.pumpWidget(_app(container, _layout(request)));
      expect(find.text('2:00'), findsOneWidget);

      container.read(audioStateProvider.notifier).resetState();
      await tester.pump();
      expect(find.text('2:00'), findsOneWidget);

      _audioUpdate(
        container,
        request,
        position: 120000,
        playing: true,
        trackId: '',
        fileId: '',
      );
      await tester.pump();
      expect(find.text('2:00'), findsOneWidget);

      _audioUpdate(
        container,
        request,
        position: 120000,
        playing: true,
        trackId: 'anterior',
        fileId: 'archivo-anterior',
      );
      await tester.pump();
      expect(find.text('2:00'), findsOneWidget);

      _audioUpdate(
        container,
        request,
        position: 120000,
        playing: true,
        fileId: 'timer-countdown-60000',
      );
      await tester.pump();
      expect(find.text('2:00'), findsOneWidget);

      _audioUpdate(
        container,
        request,
        position: 30000,
        duration: request.duration - 2001,
      );
      await tester.pump();
      expect(find.text('2:00'), findsOneWidget);

      _audioUpdate(container, request, position: 120000, completed: true);
      await tester.pump();
      expect(find.text('2:00'), findsOneWidget);

      _audioUpdate(
        container,
        request,
        position: 30000,
        playing: true,
        fileId: '',
        duration: 0,
      );
      await tester.pump();
      expect(find.text('1:30'), findsOneWidget);
    },
  );

  testWidgets('acepta la primera muestra en pausa con el archivo cargado', (
    tester,
  ) async {
    final request = _request();
    await tester.pumpWidget(_app(container, _layout(request)));
    expect(find.text('2:00'), findsOneWidget);

    _audioUpdate(
      container,
      request,
      position: 30000,
      trackId: '',
      duration: request.duration + 2000,
    );
    await tester.pump();
    expect(find.text('1:30'), findsOneWidget);

    _audioUpdate(container, request, position: 122000, trackId: '', fileId: '');
    await tester.pump();
    expect(find.text('0:00'), findsOneWidget);
  });

  testWidgets('el cronómetro empieza en cero y trunca los milisegundos', (
    tester,
  ) async {
    final request = _request(mode: TimerMode.stopwatch);
    _audioUpdate(container, request, position: 78241, playing: true);
    await tester.pumpWidget(_app(container, _layout(request)));
    expect(find.text('Cronómetro'), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);
    _audioUpdate(container, request, position: 1999, playing: true);
    await tester.pump();
    expect(find.text('0:01'), findsOneWidget);
  });

  testWidgets('oculta controles a los seis segundos, y un toque los muestra', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(container, _layout(_request(), playing: true), reduceMotion: false),
    );
    final button = find.text('Fondo');
    final backgroundButton = tester.getCenter(button);
    await tester.pump(const Duration(milliseconds: 5999));
    expect(_controlOpacities(tester), [1, 1]);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_controlOpacities(tester), [0, 0]);
    expect(button.hitTestable(), findsNothing);
    expect(find.text('Temporizador'), findsOneWidget);
    expect(find.text('2:00'), findsOneWidget);
    await tester.tapAt(backgroundButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_controlOpacities(tester), [1, 1]);
    expect(find.byType(TimerBackgroundPicker), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    expect(_controlOpacities(tester), [0, 0]);
  });

  testWidgets('muestra los controles si está en pausa o cargando', (
    tester,
  ) async {
    final request = _request();
    await tester.pumpWidget(_app(container, _layout(request, playing: true)));
    await tester.pump(const Duration(seconds: 7));
    expect(_controlOpacities(tester), [0, 0]);

    await tester.pumpWidget(_app(container, _layout(request)));
    await tester.pump(const Duration(seconds: 7));
    expect(_controlOpacities(tester), [1, 1]);
    expect(find.byTooltip('Continuar').hitTestable(), findsOneWidget);

    await tester.pumpWidget(
      _app(container, _layout(request, loading: true, playing: true)),
    );
    await tester.pump(const Duration(seconds: 7));
    expect(_controlOpacities(tester), [1, 1]);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('2:00'), findsOneWidget);
  });

  testWidgets('la navegación accesible mantiene los controles visibles', (
    tester,
  ) async {
    final request = _request();
    await tester.pumpWidget(
      _app(container, _layout(request, playing: true), accessible: true),
    );
    await tester.pump(const Duration(seconds: 7));
    expect(_controlOpacities(tester), [1, 1]);
    expect(find.byTooltip('Pausar').hitTestable(), findsOneWidget);
  });

  testWidgets('cada animación queda quieta cuando se reduce el movimiento', (
    tester,
  ) async {
    final request = _request();
    await tester.pumpWidget(_app(container, const Scaffold()));
    await tester.pumpAndSettle();
    // Riverpod registra un callback que se ejecuta si ya hay otro cuadro.
    final idleCallbacks = tester.binding.transientCallbackCount;
    for (final animation in TimerBackground.values.where(
      (value) => value.kind == TimerBackgroundKind.animation,
    )) {
      await container.read(timerBackgroundProvider.notifier).set(animation);
      await tester.pumpWidget(_app(container, _layout(request, playing: true)));
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, idleCallbacks);
      expect(find.text('2:00'), findsOneWidget);
    }

    await tester.pumpWidget(
      _app(container, _layout(request), reduceMotion: false),
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(idleCallbacks));
    await tester.pumpWidget(_app(container, _layout(request)));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, idleCallbacks);
  });

  testWidgets('el fondo cambia en la sesión y la selección queda en la hoja', (
    tester,
  ) async {
    await tester.pumpWidget(_app(container, _layout(_request())));
    await tester.tap(find.text('Fondo'));
    await tester.pumpAndSettle();
    final picker = find.byType(TimerBackgroundPicker);
    final waves = find.widgetWithText(TextButton, 'Ondas');
    expect(picker, findsOneWidget);
    expect(find.text('Animación'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(waves);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: waves, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(
      prefs.get(SharedPreferenceConstants.timerBackground),
      'animation:ondas',
    );
    final sessionCanvas = tester
        .widgetList<TimerBackgroundCanvas>(find.byType(TimerBackgroundCanvas))
        .singleWhere((canvas) => canvas.withScrim);
    expect(sessionCanvas.background, TimerBackground.waves);
    expect(picker, findsOneWidget);
  });

  testWidgets(
    'la hoja al 45 % deja el texto visible en horizontal a escala 1.5',
    (tester) async {
      tester.view.physicalSize = const Size(800, 260);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(container, _layout(_request()), textScale: 1.5),
      );
      await tester.tap(find.text('Fondo'));
      await tester.pumpAndSettle();
      final sheet = tester.getRect(find.byType(BottomSheet));
      expect(sheet.height, closeTo(117, 0.1));
      final route = ModalRoute.of(
        tester.element(find.byType(TimerBackgroundPicker)),
      )!;
      expect(route.barrierColor, Colors.black.withValues(alpha: 0.2));
      for (final item in [find.text('Temporizador'), find.text('2:00')]) {
        final visible = tester.getRect(item);
        expect(visible.top, greaterThanOrEqualTo(0));
        expect(visible.bottom, lessThanOrEqualTo(sheet.top));
        expect(visible.left, greaterThanOrEqualTo(0));
        expect(visible.right, lessThanOrEqualTo(800));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('los iconos del sistema cambian con fondos oscuros y claros', (
    tester,
  ) async {
    await tester.pumpWidget(_app(container, _layout(_request())));
    final region = find.byType(AnnotatedRegion<SystemUiOverlayStyle>);
    SystemUiOverlayStyle style() =>
        tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(region).value;
    expect(style().statusBarIconBrightness, Brightness.light);
    expect(style().systemNavigationBarIconBrightness, Brightness.light);
    final saving = container
        .read(timerBackgroundProvider.notifier)
        .set(TimerBackground.cream);
    await tester.pump();
    await saving;
    await tester.pumpAndSettle();
    expect(style().statusBarIconBrightness, Brightness.dark);
    expect(style().systemNavigationBarIconBrightness, Brightness.dark);
  });

  for (final changeBrightness in [false, true]) {
    testWidgets(
      changeBrightness
          ? 'al salir restaura el tema tras un cambio de brillo del sistema'
          : 'al salir restaura el estilo anterior de las barras del sistema',
      (tester) async {
        final binding = tester.binding;
        final navigator = GlobalKey<NavigatorState>();
        final calls = <Map<Object?, Object?>>[];
        final messenger = binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'SystemChrome.setSystemUIOverlayStyle') {
            calls.add(call.arguments as Map<Object?, Object?>);
          }
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
          binding.platformDispatcher.clearPlatformBrightnessTestValue();
        });
        binding.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        final baseline = SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.dark,
        );
        SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle());
        await tester.pumpWidget(
          _app(container, const Scaffold(), navigator: navigator),
        );
        SystemChrome.setSystemUIOverlayStyle(baseline);
        await tester.pump();
        final before = calls.last;
        _push(
          navigator.currentState!,
          _layout(
            _request(),
            onClose: () {
              navigator.currentState!.pop();
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(
          calls.last['statusBarIconBrightness'],
          Brightness.light.toString(),
        );

        if (changeBrightness) {
          binding.platformDispatcher.platformBrightnessTestValue =
              Brightness.dark;
          await tester.pumpAndSettle();
          final saving = container
              .read(timerBackgroundProvider.notifier)
              .set(TimerBackground.cream);
          await tester.pump();
          await saving;
          await tester.pumpAndSettle();
          expect(
            calls.last['statusBarIconBrightness'],
            Brightness.dark.toString(),
          );
        }

        await tester.tap(find.byTooltip('Cerrar'));
        await tester.pumpAndSettle();
        expect(find.byType(TimerSessionLayout), findsNothing);
        if (changeBrightness) {
          expect(
            calls.last['statusBarIconBrightness'],
            Brightness.light.toString(),
          );
          expect(
            calls.last['systemNavigationBarIconBrightness'],
            Brightness.light.toString(),
          );
        } else {
          expect(calls.last, before);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

void _push(NavigatorState navigator, Widget screen) {
  unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) => screen)));
}
