
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/player/ios_audio_handler.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AudioHandler extends Mock implements IosAudioHandler {}

class _Track extends Fake implements Track {}

class _Preview extends Mock implements SessionBellPreview {}

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
}
