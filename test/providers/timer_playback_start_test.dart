import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/player/ios_audio_handler.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/services/audio/ios_session_bells.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AudioHandler extends Mock implements IosAudioHandler {}

class _Bells extends Mock implements IosSessionBells {}

class _Track extends Fake implements Track {}

class _DiscardingHandler extends IosAudioHandler {
  int transportStops = 0;

  @override
  Future<void> stopPlayback() async => transportStops++;
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
      final bells = _Bells();
      iosAudioHandler = handler;
      when(() => handler.sessionBells).thenReturn(bells);
      when(
        () => handler.setCustomRepeatMode(RepeatMode.none),
      ).thenAnswer((_) async {});
      when(() => handler.setSpeed(1)).thenAnswer((_) async {});
      when(
        () => handler.setUrl(any(), request, any()),
      ).thenAnswer((_) async {});
      var installed = false;
      when(
        () => bells.setBellCues(
          offsetsMs: any(named: 'offsetsMs'),
          endOffsetMs: any(named: 'endOffsetMs'),
          enabled: any(named: 'enabled'),
          volume: any(named: 'volume'),
        ),
      ).thenAnswer((call) async {
        expect(call.namedArguments[#offsetsMs], [0, 174000]);
        expect(call.namedArguments[#enabled], isTrue);
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
