import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/player/download/audio_downloader_provider.dart';
import 'package:medito/providers/player/ios_audio_handler.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/services/audio/ios_session_bells.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/services/timer/ios_timer_run_store.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AudioHandler extends Mock implements IosAudioHandler {}

class _Track extends Fake implements Track {}

class _Bells extends Mock implements IosSessionBells {}

class _Preview extends Mock implements SessionBellPreview {}

class _Downloads extends AudioDownloaderProvider {
  @override
  Future<String?> getTrackPath(String fileName) async => null;
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

  test(
    'el interruptor prueba el cierre de la sesión y descarta solicitudes viejas',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final preview = _Preview();
      when(preview.stop).thenAnswer((_) async {});
      const asset = 'assets/audio/bells/p8-kalimba.mp3';
      when(() => preview.play(any(), assetKey: asset)).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          sessionBellPreviewProvider.overrideWithValue(preview),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);
      final originalSink = AudioSessionTracker.logSink;
      AudioSessionTracker.logSink = (_, _) async {};
      addTearDown(() {
        AudioSessionTracker.logSink = originalSink;
        AudioSessionTracker.instance.resetForTesting();
      });
      final request = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 3),
        filePath: '/tmp/timer.wav',
        title: 'Temporizador',
        bells: const TimerBellSettings(endSound: 'kalimba'),
      );
      registerFallbackValue(_Track());
      final handler = _AudioHandler();
      final bells = _Bells();
      iosAudioHandler = handler;
      when(() => handler.sessionBells).thenReturn(bells);
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
      when(
        () => handler.setUrl(
          any(),
          request,
          any(),
          timerBells: any(named: 'timerBells'),
        ),
      ).thenAnswer((_) async {});
      when(handler.play).thenAnswer((_) async {});
      when(() => bells.setTimerEnabled(true, any())).thenAnswer((_) async {});

      final player = container.read(playerProvider.notifier);
      final sounds = container.read(backgroundSoundsNotifierProvider.notifier);
      expect(player.reserveStart(request.timerRunId), isTrue);
      await player.play(request);
      sounds.setSessionBells(true);
      await pumpEventQueue();
      verify(() => preview.play(any(), assetKey: asset)).called(1);

      var applying = Completer<void>();
      when(
        () => bells.setTimerEnabled(true, any()),
      ).thenAnswer((_) => applying.future);
      sounds.setSessionBells(true);
      await player.play(request);
      applying.complete();
      await pumpEventQueue();
      verifyNever(() => preview.play(any(), assetKey: asset));

      applying = Completer<void>();
      sounds.setSessionBells(true);
      await PlaybackAccount.clear();
      applying.complete();
      await pumpEventQueue();
      verifyNever(() => preview.play(any(), assetKey: asset));
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
}
