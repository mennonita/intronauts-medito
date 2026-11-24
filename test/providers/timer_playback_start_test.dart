import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/player/download/audio_downloader_provider.dart';
import 'package:medito/providers/player/ios_audio_handler.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/services/audio/ios_session_bells.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/services/timer/ios_timer_run_store.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AudioHandler extends Mock implements IosAudioHandler {}

class _Bells extends Mock implements IosSessionBells {}

class _Track extends Fake implements Track {}

class _Preview extends Mock implements SessionBellPreview {}

class _Downloads extends AudioDownloaderProvider {
  @override
  Future<String?> getTrackPath(String fileName) async => null;
}

/// Preferencias reales cuyas escrituras pueden fallar.
class _FailingPrefs extends Fake implements SharedPreferences {
  _FailingPrefs(this.real);

  final SharedPreferences real;
  bool fail = false;

  @override
  Object? get(String key) => real.get(key);
  @override
  String? getString(String key) => real.getString(key);
  @override
  Future<bool> setString(String key, String value) async =>
      !fail && await real.setString(key, value);
  @override
  Future<bool> remove(String key) async => !fail && await real.remove(key);
}

class _DiscardingHandler extends IosAudioHandler {
  int transportStops = 0;

  @override
  Future<void> stopPlayback({bool full = true}) async => transportStops++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'el primer inicio y el reintento activan el interruptor antes de play',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          audioStateProvider.overrideWith(AudioStateNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      final originalSink = AudioSessionTracker.logSink;
      AudioSessionTracker.logSink = (_, _) async {};
      AudioSessionTracker.instance.resetForTesting();
      addTearDown(() {
        AudioSessionTracker.logSink = originalSink;
        AudioSessionTracker.instance.resetForTesting();
      });
      final request = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 3),
        filePath: '/tmp/timer.wav',
        title: 'Temporizador',
      );
      registerFallbackValue(_Track());
      final handler = _AudioHandler();
      iosAudioHandler = handler;
      when(
        () => handler.setCustomRepeatMode(RepeatMode.none),
      ).thenAnswer((_) async {});
      when(() => handler.setSpeed(1)).thenAnswer((_) async {});
      when(handler.cancelPendingTimerStart).thenAnswer((_) {});
      when(
        () => handler.configureSession(
          mixWithOthers: any(named: 'mixWithOthers'),
        ),
      ).thenAnswer((_) async {});
      var installed = false;
      when(
        () => handler.setUrl(
          any(),
          request,
          any(),
          timerBells: any(named: 'timerBells'),
        ),
      ).thenAnswer((call) async {
        expect(request.timerBellCues?.map((cue) => cue.offsetMs), [0, 180000]);
        final settings =
            call.namedArguments[#timerBells] as ({bool enabled, double volume});
        expect(settings.enabled, isTrue);
        expect(
          container.read(backgroundSoundsNotifierProvider).bellsEnabled,
          isTrue,
        );
        installed = true;
      });
      when(() => handler.play()).thenAnswer((_) async {
        expect(installed, isTrue);
        installed = false;
      });

      final player = container.read(playerProvider.notifier);
      expect(player.reserveStart(request.timerRunId), isTrue);
      expect(
        container.read(backgroundSoundsNotifierProvider).bellsEnabled,
        isFalse,
      );
      await player.play(request);
      await player.play(request);
      verify(() => handler.play()).called(2);
      expect(container.read(playerProvider), request);
    },
  );

  // Las campanas del temporizador ya no tienen interruptor general:
  // cada campana decide por su ajuste (PLAN §4 UX-2).
  test(
    'en el temporizador, el interruptor de campanas no cambia nada',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final preview = _Preview();
      when(preview.stop).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          sessionBellPreviewProvider.overrideWithValue(preview),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);
      final sounds = container.read(backgroundSoundsNotifierProvider.notifier);
      sounds.setTimerScope(true);

      sounds.setSessionBells(false);
      await pumpEventQueue();

      expect(
        container.read(backgroundSoundsNotifierProvider).bellsEnabled,
        isTrue,
      );
      verifyNever(() => preview.play(any(), assetKey: any(named: 'assetKey')));
    },
  );

  test('descartar en iOS solo detiene el transporte', () async {
    final handler = _DiscardingHandler();
    var timerCloses = 0;
    handler.onTimerStop = () async => timerCloses++;

    await handler.discardPlayback();

    expect(handler.transportStops, 1);
    expect(timerCloses, 0);
    expect(handler.onTimerStop, isNull);
  });

  test(
    'una guiada que reemplaza un temporizador lo cierra con su tiempo (REV-05)',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final recorded = <Map<String, dynamic>>[];
      final originalStore = IosTimerRunStore.instance;
      final store = IosTimerRunStore(
        prefs: () async => prefs,
        record: (payload) async {
          recorded.add(payload);
          return TimerRecordResult.accepted;
        },
      );
      IosTimerRunStore.instance = store;
      addTearDown(() => IosTimerRunStore.instance = originalStore);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          audioStateProvider.overrideWith(AudioStateNotifier.new),
          audioDownloaderProvider.overrideWith(_Downloads.new),
          playerProvider.overrideWith(
            () => PlayerProvider(useAndroidAudio: false),
          ),
        ],
      );
      addTearDown(container.dispose);
      final originalSink = AudioSessionTracker.logSink;
      AudioSessionTracker.logSink = (_, _) async {};
      addTearDown(() {
        AudioSessionTracker.logSink = originalSink;
        AudioSessionTracker.instance.resetForTesting();
      });
      final timer = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 20),
        filePath: '/tmp/timer.wav',
        title: 'Temporizador',
      );
      const guided = PlaybackRequest(
        trackId: 'guiada',
        fileId: 'archivo-guiado',
        title: 'Guiada',
        description: '',
        coverUrl: '',
        remoteUrl: 'file:///tmp/guiada.mp3',
        duration: 600000,
        hasBackgroundSound: false,
      );
      registerFallbackValue(_Track());
      registerFallbackValue(timer);
      registerFallbackValue(RepeatMode.none);
      final handler = _AudioHandler();
      iosAudioHandler = handler;
      when(() => handler.setCustomRepeatMode(any())).thenAnswer((_) async {});
      when(() => handler.setSpeed(1)).thenAnswer((_) async {});
      when(handler.cancelPendingTimerStart).thenAnswer((_) {});
      when(
        () => handler.configureSession(
          mixWithOthers: any(named: 'mixWithOthers'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => handler.setUrl(
          any(),
          any(),
          any(),
          timerBells: any(named: 'timerBells'),
        ),
      ).thenAnswer((_) async {});
      when(handler.play).thenAnswer((_) async {});

      final player = container.read(playerProvider.notifier);
      expect(player.reserveStart(timer.timerRunId), isTrue);
      await player.play(timer);
      expect(store.liveRunId, timer.timerRunId);

      // Siete minutos después empieza una guiada en su lugar.
      when(() => handler.timerRunId).thenReturn(timer.timerRunId);
      when(() => handler.position).thenReturn(const Duration(minutes: 7));
      var replacedBeforeAudio = false;
      when(
        () => handler.setUrl(
          any(),
          guided,
          any(),
          timerBells: any(named: 'timerBells'),
        ),
      ).thenAnswer((_) async {
        replacedBeforeAudio = store.active == null && store.liveRunId == null;
      });
      await player.play(guided);
      await pumpEventQueue();

      expect(replacedBeforeAudio, isTrue);
      expect(store.liveRunId, isNull);
      expect(store.active, isNull);
      expect(recorded.single[TypeConstants.runIdKey], timer.timerRunId);
      expect(recorded.single[TypeConstants.durationIdKey], 7 * 60000);
      expect(store.finished, isEmpty);
    },
  );

  test(
    'una guiada no reemplaza un temporizador que no se pudo guardar (TMR-02)',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final failing = _FailingPrefs(prefs);
      final recorded = <Map<String, dynamic>>[];
      final originalStore = IosTimerRunStore.instance;
      final store = IosTimerRunStore(
        prefs: () async => failing,
        record: (payload) async {
          recorded.add(payload);
          return TimerRecordResult.accepted;
        },
      );
      IosTimerRunStore.instance = store;
      addTearDown(() => IosTimerRunStore.instance = originalStore);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          audioStateProvider.overrideWith(AudioStateNotifier.new),
          audioDownloaderProvider.overrideWith(_Downloads.new),
          playerProvider.overrideWith(
            () => PlayerProvider(useAndroidAudio: false),
          ),
        ],
      );
      addTearDown(container.dispose);
      final originalSink = AudioSessionTracker.logSink;
      AudioSessionTracker.logSink = (_, _) async {};
      addTearDown(() {
        AudioSessionTracker.logSink = originalSink;
        AudioSessionTracker.instance.resetForTesting();
      });
      final timer = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 20),
        filePath: '/tmp/timer.wav',
        title: 'Temporizador',
      );
      const guided = PlaybackRequest(
        trackId: 'guiada',
        fileId: 'archivo-guiado',
        title: 'Guiada',
        description: '',
        coverUrl: '',
        remoteUrl: 'file:///tmp/guiada.mp3',
        duration: 600000,
        hasBackgroundSound: false,
      );
      registerFallbackValue(_Track());
      registerFallbackValue(timer);
      registerFallbackValue(RepeatMode.none);
      final handler = _AudioHandler();
      iosAudioHandler = handler;
      when(() => handler.setCustomRepeatMode(any())).thenAnswer((_) async {});
      when(() => handler.setSpeed(1)).thenAnswer((_) async {});
      when(handler.cancelPendingTimerStart).thenAnswer((_) {});
      when(
        () => handler.configureSession(
          mixWithOthers: any(named: 'mixWithOthers'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => handler.setUrl(
          any(),
          any(),
          any(),
          timerBells: any(named: 'timerBells'),
        ),
      ).thenAnswer((_) async {});
      when(handler.play).thenAnswer((_) async {});

      final player = container.read(playerProvider.notifier);
      expect(player.reserveStart(timer.timerRunId), isTrue);
      player.prepare(timer);
      await player.play(timer);
      expect(store.liveRunId, timer.timerRunId);

      // A los 61 s el guardado falla: la última foto podría ser de 59 s.
      when(() => handler.timerRunId).thenReturn(timer.timerRunId);
      when(() => handler.position).thenReturn(const Duration(seconds: 61));
      failing.fail = true;
      player.prepare(guided);
      await expectLater(
        player.play(guided),
        throwsA(isA<TimerReplaceFailedException>()),
      );

      // El temporizador sigue siendo la sesión viva y nada de la guiada cargó.
      verifyNever(
        () => handler.setUrl(
          any(),
          guided,
          any(),
          timerBells: any(named: 'timerBells'),
        ),
      );
      verify(handler.play).called(1);
      expect(store.liveRunId, timer.timerRunId);
      expect(store.active?['runId'], timer.timerRunId);
      expect(player.activeTimerRequest, timer);
      expect(container.read(playerProvider), timer);
      expect(recorded, isEmpty);

      // Con el guardado de vuelta, la guiada lo reemplaza con su tiempo.
      failing.fail = false;
      await player.play(guided);
      await pumpEventQueue();
      expect(recorded.single[TypeConstants.durationIdKey], 61000);
      expect(store.liveRunId, isNull);
    },
  );

  test(
    'iOS: la campana final publicada al terminar cuenta para la reseña '
    '(SIT-01)',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final originalStore = IosTimerRunStore.instance;
      IosTimerRunStore.instance = IosTimerRunStore(
        prefs: () async => prefs,
        record: (_) async => TimerRecordResult.accepted,
      );
      addTearDown(() => IosTimerRunStore.instance = originalStore);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          audioStateProvider.overrideWith(AudioStateNotifier.new),
          audioDownloaderProvider.overrideWith(_Downloads.new),
          playerProvider.overrideWith(
            () => PlayerProvider(useAndroidAudio: false),
          ),
        ],
      );
      addTearDown(container.dispose);
      final originalSink = AudioSessionTracker.logSink;
      AudioSessionTracker.logSink = (_, _) async {};
      addTearDown(() {
        AudioSessionTracker.logSink = originalSink;
        AudioSessionTracker.instance.resetForTesting();
      });
      final timer = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 3),
        filePath: '/tmp/timer.wav',
        title: 'Temporizador',
      );
      registerFallbackValue(_Track());
      registerFallbackValue(timer);
      registerFallbackValue(RepeatMode.none);
      final handler = _AudioHandler();
      final bells = _Bells();
      iosAudioHandler = handler;
      when(() => handler.sessionBells).thenReturn(bells);
      // Las campanas ya se soltaron: su marca se borró.
      when(() => bells.endCueStarted).thenReturn(false);
      when(() => handler.timerRunId).thenReturn(timer.timerRunId);
      // El controlador publicó el resultado con su `runId` antes de soltarlas.
      when(() => handler.timerEndCueRang(timer.timerRunId)).thenReturn(true);
      when(() => handler.setCustomRepeatMode(any())).thenAnswer((_) async {});
      when(() => handler.setSpeed(1)).thenAnswer((_) async {});
      when(handler.cancelPendingTimerStart).thenAnswer((_) {});
      when(
        () => handler.configureSession(
          mixWithOthers: any(named: 'mixWithOthers'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => handler.setUrl(
          any(),
          any(),
          any(),
          timerBells: any(named: 'timerBells'),
        ),
      ).thenAnswer((_) async {});
      when(handler.play).thenAnswer((_) async {});

      final player = container.read(playerProvider.notifier);
      expect(player.reserveStart(timer.timerRunId), isTrue);
      player.prepare(timer);
      await player.play(timer);

      void update({required bool playing, required bool completed}) {
        container
            .read(audioStateProvider.notifier)
            .updatePlaybackState(
              PlaybackState(
                isPlaying: playing,
                isBuffering: false,
                isSeeking: false,
                isCompleted: completed,
                position: completed ? timer.duration : 1000,
                duration: timer.duration,
                speed: Speed(speed: 1),
                volume: 100,
                track: Track(
                  id: timer.trackId,
                  fileId: timer.fileId,
                  title: '',
                  description: '',
                  imageUrl: '',
                ),
                runId: timer.timerRunId,
              ),
            );
      }

      update(playing: true, completed: false);
      update(playing: false, completed: true);

      final outcome = player.takeSitOutcome();
      expect(outcome?.naturalEnd, isTrue);
      expect(outcome?.endCueRang, isTrue);
    },
  );
}
