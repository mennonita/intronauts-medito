import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/last_timer_store.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_launch.dart';
import 'package:medito/models/timer/timer_preset.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/providers.dart';
import 'package:medito/providers/timer/timer_presets_provider.dart';
import 'package:medito/providers/timer/timer_settings_provider.dart';
import 'package:medito/repositories/background_sounds/background_sounds_repository.dart';
import 'package:medito/repositories/track/track_repository.dart';
import 'package:medito/services/timer/timer_device_channel.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/timer/timer_view.dart';
import 'package:medito/views/timer/widgets/timer_preset_name_dialog.dart';

import '../../helpers/firebase_analytics_test_helper.dart';
import '../../helpers/firebase_test_helper.dart';

final l10n = lookupAppLocalizations(const Locale('es'));

const _rain = BackgroundSoundsModel(
  id: 'lluvia',
  title: 'Lluvia',
  path: 'https://example.com/lluvia.mp3',
  duration: 1000,
);
const _waves = BackgroundSoundsModel(
  id: 'olas',
  title: 'Olas',
  path: 'https://example.com/olas.mp3',
  duration: 1000,
);

/// Reproductor falso: lleva su propia reserva para poder simular que otra
/// sesión la tomó.
class _FakePlayer extends PlayerProvider {
  _FakePlayer() : super(useAndroidAudio: false);

  String? reserved;
  bool active = false;
  final reservedIds = <String>[];
  final released = <String>[];
  final prepared = <PlaybackRequest>[];
  final played = <PlaybackRequest>[];

  /// Se llama al reservar; sirve para quitar la reserva a mitad del inicio.
  VoidCallback? onReserved;

  @override
  PlaybackRequest? build() => null;

  @override
  String get statsOwnerId => 'dueño-1';

  @override
  bool get hasActiveSession => reserved != null || active;

  @override
  bool reserveStart(String runId) {
    if (runId.isEmpty || hasActiveSession) return false;
    reserved = runId;
    reservedIds.add(runId);
    onReserved?.call();
    return true;
  }

  @override
  bool isReserved(String runId) => runId.isNotEmpty && reserved == runId;

  @override
  void releaseStart(String runId) {
    released.add(runId);
    if (reserved == runId) reserved = null;
  }

  /// Una meditación guiada que empieza invalida la reserva (R55).
  void guidedStarted() => reserved = null;

  @override
  void prepare(PlaybackRequest request) {
    prepared.add(request);
    state = request;
  }

  @override
  Future<void> play(PlaybackRequest request) async {
    if (request.isTimer && !isReserved(request.timerRunId)) return;
    played.add(request);
  }
}

class _FakeSounds extends Fake implements BackgroundSoundsRepository {
  _FakeSounds({this.selected, this.catalog = const []});

  final BackgroundSoundsModel? selected;
  final List<BackgroundSoundsModel> catalog;

  @override
  BackgroundSoundsModel? getSelectedBgSoundFromSharedPreferences() => selected;

  @override
  bool getSessionBellsEnabled({bool forTimer = false}) => true;

  @override
  List<BackgroundSoundsModel> fetchCachedBackgroundSounds() => catalog;
}

class _FakeTracks extends Fake implements TrackRepository {
  @override
  Future<Never> fetchTrack(String trackId) =>
      Future.error(Exception('sin red'));
}

/// Hace lo que PlayerView: toma la solicitud preparada y la reproduce.
class _FakePlayerPage extends ConsumerStatefulWidget {
  const _FakePlayerPage();

  @override
  ConsumerState<_FakePlayerPage> createState() => _FakePlayerPageState();
}

class _FakePlayerPageState extends ConsumerState<_FakePlayerPage> {
  @override
  void initState() {
    super.initState();
    final request = ref.read(playerProvider);
    if (request != null) {
      unawaited(ref.read(playerProvider.notifier).play(request));
    }
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('pantalla-del-reproductor'));
}

String _settingsJson(TimerSettings settings) =>
    jsonEncode(settings.toSnapshotJson());

String _presetsJson(List<TimerPreset> presets) =>
    jsonEncode([for (final preset in presets) preset.toJson()]);

const _home = Key('inicio');

late _FakePlayer _player;
late List<Duration> _fileDurations;

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  TimerLaunch? launch,
  BackgroundSoundsModel? selected,
  List<BackgroundSoundsModel> catalog = const [],
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    PreviewShell(
      locale: const Locale('es'),
      prefs: {...prefsDark, ...prefs},
      overrides: [
        playerProvider.overrideWith(() => _player),
        backgroundSoundsRepositoryProvider.overrideWithValue(
          _FakeSounds(selected: selected, catalog: catalog),
        ),
        trackRepositoryProvider.overrideWithValue(_FakeTracks()),
      ],
      child: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Builder(
          builder: (context) => Scaffold(
            key: _home,
            body: TimerView(source: 'prueba', launch: launch),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byKey(_home)));
}

Future<void> _pumpUntilSettled(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _tapStart(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, l10n.timerStart));
  await _pumpUntilSettled(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await FirebaseTestHelper.initializeFirebaseForTest();
    FirebaseAnalyticsTestHelper.setupFirebaseAnalyticsMocks();
  });

  setUp(() {
    _player = _FakePlayer();
    _fileDurations = [];
    TimerView.prepareTimerFile = (duration) async {
      _fileDurations.add(duration);
      return '/tmp/medito_timer_prueba.wav';
    };
    TimerView.playerPageBuilder = (_) => const _FakePlayerPage();
  });

  tearDown(() {
    TimerView.prepareTimerFile = (duration) async => '';
    TimerDeviceChannel.debugIsAndroid = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('intronauts/timer_device'),
          null,
        );
  });

  const morning = TimerPreset(
    id: 'p1',
    name: 'Mañana',
    settings: TimerSettings(mode: TimerMode.countdown, minutes: 25),
    sound: _rain,
  );
  const evening = TimerPreset(
    id: 'p2',
    name: 'Noche',
    settings: TimerSettings(mode: TimerMode.countdown, minutes: 40),
    sound: null,
  );

  group('temporizadores guardados', () {
    testWidgets('tocar uno lo carga, avisa y no empieza', (tester) async {
      final container = await _pump(
        tester,
        prefs: {
          SharedPreferenceConstants.timerPresets: _presetsJson([morning]),
        },
      );
      expect(find.text('Mañana'), findsOneWidget);
      expect(find.text('25 min'), findsOneWidget);

      await tester.tap(find.text('Mañana'));
      await _pumpUntilSettled(tester);

      expect(find.text(l10n.timerPresetLoaded('Mañana')), findsOneWidget);
      expect(container.read(timerSettingsProvider).minutes, 25);
      expect(_player.reservedIds, isEmpty);
      expect(_player.prepared, isEmpty);
      expect(find.text('pantalla-del-reproductor'), findsNothing);

      // El siguiente inicio usa el sonido de fondo del temporizador cargado.
      await _tapStart(tester);
      final request = _player.played.single;
      expect(request.overrideBackgroundSound, isTrue);
      expect(request.backgroundSound, _rain);
      expect(request.plannedDurationMs, 25 * 60 * 1000);
    });

    testWidgets('el menú cambia el nombre', (tester) async {
      final container = await _pump(
        tester,
        prefs: {
          SharedPreferenceConstants.timerPresets: _presetsJson([morning]),
        },
      );
      await tester.tap(find.byTooltip(l10n.timerPresetOptions('Mañana')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.timerPresetRename));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'Mañana');
      await tester.enterText(find.byType(TextField), 'Tarde');
      await tester.tap(find.text(l10n.timerPresetSave));
      await tester.pumpAndSettle();

      expect(container.read(timerPresetsProvider).single.name, 'Tarde');
      expect(container.read(timerPresetsProvider).single.id, 'p1');
    });

    testWidgets('el menú guarda los ajustes actuales', (tester) async {
      final container = await _pump(
        tester,
        prefs: {
          SharedPreferenceConstants.timerPresets: _presetsJson([morning]),
          kTimerSettingsSnapshotKey: _settingsJson(
            const TimerSettings(
              mode: TimerMode.countdown,
              minutes: 12,
              prepSeconds: 30,
            ),
          ),
        },
        selected: _waves,
      );
      await tester.tap(find.byTooltip(l10n.timerPresetOptions('Mañana')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.timerPresetUpdate));
      await _pumpUntilSettled(tester);

      final preset = container.read(timerPresetsProvider).single;
      expect(preset.settings.minutes, 12);
      expect(preset.settings.prepSeconds, 30);
      expect(preset.sound, _waves);
      expect(find.text(l10n.timerPresetUpdated), findsOneWidget);
    });

    testWidgets('el menú mueve y no deja subir al primero', (tester) async {
      final container = await _pump(
        tester,
        prefs: {
          SharedPreferenceConstants.timerPresets: _presetsJson([
            morning,
            evening,
          ]),
        },
      );
      await tester.tap(find.byTooltip(l10n.timerPresetOptions('Mañana')));
      await tester.pumpAndSettle();
      final moveUp = tester.widget<PopupMenuItem<Object?>>(
        find.ancestor(
          of: find.text(l10n.timerPresetMoveUp),
          matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
        ),
      );
      expect(moveUp.enabled, isFalse);
      await tester.tap(find.text(l10n.timerPresetMoveDown));
      await tester.pumpAndSettle();

      expect(container.read(timerPresetsProvider).map((p) => p.id), [
        'p2',
        'p1',
      ]);
    });

    testWidgets('el menú borra después de confirmar', (tester) async {
      final container = await _pump(
        tester,
        prefs: {
          SharedPreferenceConstants.timerPresets: _presetsJson([
            morning,
            evening,
          ]),
        },
      );
      await tester.tap(find.byTooltip(l10n.timerPresetOptions('Noche')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.timerPresetDelete));
      await tester.pumpAndSettle();
      expect(find.text(l10n.timerDeletePresetQuestion('Noche')), findsOne);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(l10n.timerPresetDelete),
        ),
      );
      await tester.pumpAndSettle();

      expect(container.read(timerPresetsProvider).map((p) => p.id), ['p1']);
    });

    testWidgets('«Editar guardados» abre la hoja', (tester) async {
      await _pump(
        tester,
        prefs: {
          SharedPreferenceConstants.timerPresets: _presetsJson([morning]),
        },
      );
      await tester.ensureVisible(find.text(l10n.timerManagePresets));
      await tester.tap(find.text(l10n.timerManagePresets));
      await tester.pumpAndSettle();
      expect(find.byType(ReorderableListView), findsOneWidget);
      expect(find.text(l10n.timerDone), findsOneWidget);
    });

    testWidgets('el nombre propuesto lleva duración y campana', (tester) async {
      await _pump(
        tester,
        prefs: {
          kTimerSettingsSnapshotKey: _settingsJson(
            const TimerSettings(mode: TimerMode.countdown, minutes: 20),
          ),
        },
      );
      await tester.ensureVisible(find.text(l10n.timerSavePreset));
      await tester.tap(find.text(l10n.timerSavePreset));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '20 min · ${l10n.bellSoundActual}');
    });

    test(
      'nombre propuesto sin campana de inicio, sin campanas y cronómetro',
      () {
        const endOnly = TimerSettings(
          mode: TimerMode.countdown,
          minutes: 90,
          bells: TimerBellSettings(start: false, endSound: 'cuenco_tibetano'),
        );
        expect(
          timerPresetAutoName(endOnly, l10n),
          '1 ${l10n.hours} 30 min · ${l10n.bellSoundTibetanBowl}',
        );
        const none = TimerSettings(
          mode: TimerMode.countdown,
          minutes: 5,
          bells: TimerBellSettings(start: false, end: false),
        );
        expect(
          timerPresetAutoName(none, l10n),
          '5 min · ${l10n.timerBellsSummaryNone}',
        );
        const stopwatch = TimerSettings(mode: TimerMode.stopwatch, minutes: 5);
        expect(
          timerPresetAutoName(stopwatch, l10n),
          '${l10n.timerModeStopwatch} · ${l10n.bellSoundActual}',
        );
      },
    );

    testWidgets('con letra al doble no hay desbordes', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        textScale: 2,
        prefs: {
          SharedPreferenceConstants.timerPresets: _presetsJson([
            morning,
            evening,
          ]),
        },
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Mañana'), findsOneWidget);
    });
  });

  group('pistas', () {
    testWidgets('con 0 minutos dice que elija al menos 1', (tester) async {
      await _pump(
        tester,
        prefs: {
          kTimerSettingsSnapshotKey: _settingsJson(
            const TimerSettings(mode: TimerMode.countdown, minutes: 0),
          ),
        },
      );
      expect(find.text(l10n.timerZeroHint), findsOneWidget);
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, l10n.timerStart),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('tiempo extra sin campana al terminar muestra la pista', (
      tester,
    ) async {
      await _pump(
        tester,
        prefs: {
          kTimerSettingsSnapshotKey: _settingsJson(
            const TimerSettings(
              mode: TimerMode.countdown,
              minutes: 10,
              extraTime: true,
              bells: TimerBellSettings(end: false),
            ),
          ),
        },
      );
      expect(find.text(l10n.timerExtraTimeBellHint), findsOneWidget);
    });

    testWidgets('por partes oculta las ruedas y el tiempo extra', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text(l10n.timerExtraTime), findsOneWidget);
      await tester.ensureVisible(find.text(l10n.timerStagesTitle));
      await tester.tap(find.text(l10n.timerStagesTitle));
      await _pumpUntilSettled(tester);
      expect(find.text(l10n.timerExtraTime), findsNothing);
      expect(find.text(l10n.timerStagesTotal('25 min')), findsOneWidget);
    });
  });

  group('inicio', () {
    testWidgets('el error al preparar usa el texto del temporizador', (
      tester,
    ) async {
      TimerView.prepareTimerFile = (_) async => throw Exception('disco lleno');
      await _pump(tester);
      await _tapStart(tester);
      expect(find.text(l10n.timerStartError), findsOneWidget);
      expect(find.text(l10n.unableToLoadAudio), findsNothing);
      expect(_player.reserved, isNull);
      expect(_player.released, _player.reservedIds);
      expect(_player.prepared, isEmpty);
    });

    testWidgets('la solicitud lleva la reserva, el dueño y la preparación', (
      tester,
    ) async {
      await _pump(
        tester,
        prefs: {
          kTimerSettingsSnapshotKey: _settingsJson(
            const TimerSettings(
              mode: TimerMode.countdown,
              minutes: 15,
              prepSeconds: 10,
            ),
          ),
        },
      );
      await _tapStart(tester);
      final request = _player.played.single;
      expect(request.timerRunId, _player.reservedIds.single);
      expect(request.timerOwnerId, 'dueño-1');
      expect(request.timerPrepMs, 10000);
      expect(request.plannedDurationMs, 15 * 60 * 1000);
      expect(
        _fileDurations.single,
        const Duration(minutes: 15, seconds: 10) +
            const Duration(milliseconds: 7500),
      );
      expect(_player.released, isEmpty);
      expect(find.text('pantalla-del-reproductor'), findsOneWidget);
    });

    testWidgets('prepara «último temporizador» sin escribirlo', (tester) async {
      final container = await _pump(
        tester,
        selected: _rain,
        prefs: {
          kTimerSettingsSnapshotKey: _settingsJson(
            const TimerSettings(mode: TimerMode.countdown, minutes: 8),
          ),
        },
      );
      await _tapStart(tester);
      final prefs = container.read(sharedPreferencesProvider);
      expect(
        prefs.containsKey(SharedPreferenceConstants.timerLastSettings),
        isFalse,
      );
      final runId = _player.played.single.timerRunId;
      expect(await LastTimerStore.commitStaged(prefs, runId), isTrue);
      final snapshot = LastTimerStore.read(prefs)!;
      expect(snapshot.settings['minutes'], 8);
      expect(snapshot.backgroundSoundId, _rain.id);
    });

    testWidgets('con una sesión activa no empieza y avisa', (tester) async {
      _player.active = true;
      await _pump(tester);
      await _tapStart(tester);
      expect(find.text(l10n.timerLaunchBusy), findsOneWidget);
      expect(_player.prepared, isEmpty);
      expect(_player.played, isEmpty);
    });

    testWidgets('volumen en cero: cancelar suelta la reserva', (tester) async {
      TimerDeviceChannel.debugIsAndroid = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('intronauts/timer_device'),
            (call) async =>
                call.method == 'mediaVolume' ? {'current': 0, 'max': 15} : null,
          );
      await _pump(tester);
      await _tapStart(tester);
      expect(find.text(l10n.timerVolumeZeroTitle), findsOneWidget);
      expect(find.text(l10n.timerVolumeZeroBody), findsOneWidget);

      await tester.tap(find.text(l10n.timerPresetCancel));
      await _pumpUntilSettled(tester);
      expect(_player.reserved, isNull);
      expect(_player.released, _player.reservedIds);
      expect(_player.prepared, isEmpty);
      expect(find.text('pantalla-del-reproductor'), findsNothing);

      // «Empezar así» sigue.
      await _tapStart(tester);
      await tester.tap(find.text(l10n.timerStartAnyway));
      await _pumpUntilSettled(tester);
      expect(_player.played, hasLength(1));
      expect(find.text('pantalla-del-reproductor'), findsOneWidget);
    });

    testWidgets('solo vibración no pregunta por el volumen', (tester) async {
      TimerDeviceChannel.debugIsAndroid = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('intronauts/timer_device'),
            (call) async => {'current': 0, 'max': 15},
          );
      await _pump(
        tester,
        prefs: {
          kTimerSettingsSnapshotKey: _settingsJson(
            const TimerSettings(
              mode: TimerMode.countdown,
              minutes: 10,
              bells: TimerBellSettings(output: TimerBellOutput.vibration),
            ),
          ),
        },
      );
      await _tapStart(tester);
      expect(find.text(l10n.timerVolumeZeroTitle), findsNothing);
      expect(_player.played, hasLength(1));
    });

    testWidgets('si otra sesión toma el reproductor durante el aviso, se '
        'detiene sin abrir nada', (tester) async {
      TimerDeviceChannel.debugIsAndroid = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('intronauts/timer_device'),
            (call) async => {'current': 0, 'max': 15},
          );
      await _pump(tester);
      await _tapStart(tester);
      expect(find.text(l10n.timerVolumeZeroTitle), findsOneWidget);

      _player.guidedStarted();
      await tester.tap(find.text(l10n.timerStartAnyway));
      await _pumpUntilSettled(tester);
      expect(_player.prepared, isEmpty);
      expect(find.text('pantalla-del-reproductor'), findsNothing);
      expect(find.text(l10n.timerStartError), findsNothing);
      expect(find.text(l10n.timerLaunchBusy), findsNothing);
    });

    testWidgets('si otra sesión toma el reproductor mientras se prepara el '
        'archivo, se detiene sin abrir nada', (tester) async {
      final file = Completer<String>();
      TimerView.prepareTimerFile = (_) => file.future;
      await _pump(tester);
      await _tapStart(tester);
      _player.guidedStarted();
      file.complete('/tmp/medito_timer_prueba.wav');
      await _pumpUntilSettled(tester);
      expect(_player.prepared, isEmpty);
      expect(find.text('pantalla-del-reproductor'), findsNothing);
      expect(find.text(l10n.timerStartError), findsNothing);
    });
  });

  group('arranque desde fuera', () {
    testWidgets('minutos: cuenta regresiva sin partes ni tiempo extra', (
      tester,
    ) async {
      final container = await _pump(
        tester,
        launch: const TimerLaunch(minutes: 7),
        prefs: {
          kTimerSettingsSnapshotKey: _settingsJson(
            const TimerSettings(
              mode: TimerMode.countdown,
              minutes: 30,
              extraTime: true,
              prepSeconds: 30,
              stages: [
                TimerStage(kind: TimerStageKind.sit, minutes: 10),
                TimerStage(kind: TimerStageKind.walk, minutes: 5),
              ],
            ),
          ),
        },
      );
      await _pumpUntilSettled(tester);
      final request = _player.played.single;
      expect(request.plannedDurationMs, 7 * 60 * 1000);
      expect(request.timerPrepMs, 30000);
      expect(request.timerStageDurationsMs, isEmpty);
      expect(request.timerExtraTime, isFalse);
      expect(request.timerRunId, _player.reservedIds.single);
      expect(request.timerOwnerId, 'dueño-1');
      expect(request.overrideBackgroundSound, isFalse);
      expect(container.read(timerSettingsProvider).minutes, 7);
    });

    testWidgets('«startAt» se ignora: empieza ya con la preparación guardada', (
      tester,
    ) async {
      final launch = TimerLaunch.fromUri(
        Uri.parse(
          'org.meditofoundation://medito/timer/start?minutes=5'
          '&startAt=2030-01-01T06:00:00Z',
        ),
      );
      await _pump(
        tester,
        launch: launch,
        prefs: {
          kTimerSettingsSnapshotKey: _settingsJson(
            const TimerSettings(
              mode: TimerMode.countdown,
              minutes: 20,
              prepSeconds: 10,
            ),
          ),
        },
      );
      await _pumpUntilSettled(tester);
      final request = _player.played.single;
      expect(request.plannedDurationMs, 5 * 60 * 1000);
      expect(request.timerPrepMs, 10000);
    });

    testWidgets('nombre de temporizador guardado con partes y su sonido', (
      tester,
    ) async {
      const parts = TimerPreset(
        id: 'p3',
        name: 'Retiro',
        settings: TimerSettings(
          mode: TimerMode.countdown,
          minutes: 20,
          prepSeconds: 60,
          stages: [
            TimerStage(kind: TimerStageKind.sit, minutes: 20),
            TimerStage(kind: TimerStageKind.walk, minutes: 10),
            TimerStage(kind: TimerStageKind.sit, minutes: 20),
          ],
        ),
        sound: _rain,
      );
      await _pump(
        tester,
        launch: const TimerLaunch(presetName: 'Retiro'),
        prefs: {
          SharedPreferenceConstants.timerPresets: _presetsJson([
            morning,
            parts,
          ]),
        },
      );
      await _pumpUntilSettled(tester);
      final request = _player.played.single;
      expect(request.plannedDurationMs, 50 * 60 * 1000);
      expect(request.timerPrepMs, 60000);
      expect(request.timerStageDurationsMs, [
        20 * 60 * 1000,
        10 * 60 * 1000,
        20 * 60 * 1000,
      ]);
      expect(request.timerStageKinds, ['sit', 'walk', 'sit']);
      expect(request.overrideBackgroundSound, isTrue);
      expect(request.backgroundSound, _rain);
    });

    testWidgets('«Repetir» restaura ajustes y sonido por id', (tester) async {
      final snapshot = LastTimerSnapshot(
        settings: const TimerSettings(
          mode: TimerMode.countdown,
          minutes: 33,
          prepSeconds: 30,
          bells: TimerBellSettings(endSound: 'cuenco_tibetano'),
        ).toSnapshotJson(),
        backgroundSoundId: _waves.id,
        savedAtMs: 1,
      );
      await _pump(
        tester,
        launch: TimerLaunch.fromRoutePath('timer/start?last=1'),
        selected: _rain,
        catalog: const [_rain, _waves],
        prefs: {
          SharedPreferenceConstants.timerLastSettings: jsonEncode(
            snapshot.toJson(),
          ),
        },
      );
      await _pumpUntilSettled(tester);
      final request = _player.played.single;
      expect(request.plannedDurationMs, 33 * 60 * 1000);
      expect(request.timerPrepMs, 30000);
      expect(request.timerEndSound, 'cuenco_tibetano');
      expect(request.overrideBackgroundSound, isTrue);
      expect(request.backgroundSound, _waves);
    });

    testWidgets('«Repetir» con un sonido que ya no existe deja el actual', (
      tester,
    ) async {
      final snapshot = LastTimerSnapshot(
        settings: const TimerSettings(
          mode: TimerMode.countdown,
          minutes: 12,
        ).toSnapshotJson(),
        backgroundSoundId: 'borrado',
        savedAtMs: 1,
      );
      await _pump(
        tester,
        launch: const TimerLaunch(last: true),
        selected: _rain,
        prefs: {
          SharedPreferenceConstants.timerLastSettings: jsonEncode(
            snapshot.toJson(),
          ),
        },
      );
      await _pumpUntilSettled(tester);
      final request = _player.played.single;
      expect(request.plannedDurationMs, 12 * 60 * 1000);
      expect(request.overrideBackgroundSound, isFalse);
    });

    testWidgets('sin datos para resolver se queda en la pantalla', (
      tester,
    ) async {
      await _pump(tester, launch: const TimerLaunch(presetName: 'No existe'));
      await _pumpUntilSettled(tester);
      expect(_player.reservedIds, isEmpty);
      expect(find.text(l10n.timerStartError), findsNothing);
      expect(find.text(l10n.timerLaunchBusy), findsNothing);
    });

    testWidgets('con una sesión en curso no la reemplaza y avisa', (
      tester,
    ) async {
      _player.active = true;
      final container = await _pump(
        tester,
        launch: const TimerLaunch(minutes: 3),
        prefs: {
          kTimerSettingsSnapshotKey: _settingsJson(
            const TimerSettings(mode: TimerMode.countdown, minutes: 20),
          ),
        },
      );
      await _pumpUntilSettled(tester);
      expect(find.text(l10n.timerLaunchBusy), findsOneWidget);
      expect(_player.played, isEmpty);
      expect(_player.prepared, isEmpty);
      expect(container.read(timerSettingsProvider).minutes, 20);
    });

    testWidgets('dos arranques en el mismo cuadro abren una sola sesión', (
      tester,
    ) async {
      await _pump(tester);
      final navigator = Navigator.of(tester.element(find.byKey(_home)));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const TimerView(
              source: 'enlace',
              launch: TimerLaunch(minutes: 5),
            ),
          ),
        ),
      );
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const TimerView(
              source: 'enlace',
              launch: TimerLaunch(minutes: 5),
            ),
          ),
        ),
      );
      await _pumpUntilSettled(tester);
      expect(_player.reservedIds, hasLength(1));
      expect(_player.played, hasLength(1));
      expect(find.text(l10n.timerLaunchBusy), findsOneWidget);
    });
  });
}
