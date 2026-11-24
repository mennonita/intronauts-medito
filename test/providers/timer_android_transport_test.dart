import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/timer/timer_session_closer.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Preview extends Mock implements SessionBellPreview {}

class _BackgroundSounds extends BackgroundSoundsNotifier {
  void moveSwitch(bool enabled) {
    state = state.copyWith(bellsEnabled: enabled);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final request = timerPlaybackRequest(
    mode: TimerMode.countdown,
    duration: const Duration(minutes: 3),
    filePath: '/tmp/timer.wav',
    title: 'Temporizador',
    seed: 42,
    bells: const TimerBellSettings(endSound: 'kalimba'),
  );

  late PlayerProvider player;
  late _Preview preview;
  late _BackgroundSounds sound;
  late Completer<void> serviceStarted;
  late int playCalls;
  late List<TimerCloseResult> closes;
  final tracker = AudioSessionTracker.instance;
  final defaultLog = AudioSessionTracker.logSink;

  void host(
    String api,
    String method,
    MessageCodec<Object?> codec,
    FutureOr<Object?> Function(Object? message) handle,
  ) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.medito.$api.$method',
      codec,
    );
    messenger.setMockDecodedMessageHandler(channel, (message) async {
      return [await handle(message)];
    });
    addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
  }

  void audioHost(String method, FutureOr<Object?> Function(Object?) handle) =>
      host(
        'MeditoAudioServiceApi',
        method,
        MeditoAudioServiceApi.pigeonChannelCodec,
        handle,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tracker.resetForTesting();
    AudioSessionTracker.logSink = (_, _) async {};
    addTearDown(() {
      tracker.resetForTesting();
      AudioSessionTracker.logSink = defaultLog;
    });
    preview = _Preview();
    when(preview.stop).thenAnswer((_) async {});
    final container = ProviderContainer(
      overrides: [
        sessionBellPreviewProvider.overrideWithValue(preview),
        playerProvider.overrideWith(
          () => PlayerProvider(useAndroidAudio: true),
        ),
        audioStateProvider.overrideWith(AudioStateNotifier.new),
        backgroundSoundsNotifierProvider.overrideWith(_BackgroundSounds.new),
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(container.dispose);
    player = container.read(playerProvider.notifier);
    sound =
        container.read(backgroundSoundsNotifierProvider.notifier)
            as _BackgroundSounds;
    player.prepare(request);
    closes = [];
    final subscription = player.timerCloses.listen(closes.add);
    addTearDown(subscription.cancel);
    addTearDown(() => MeditoTimerStopCallbackApi.setUp(null));
    serviceStarted = Completer<void>();
    playCalls = 0;
    host(
      'MeditoAndroidAudioServiceManager',
      'startService',
      MeditoAndroidAudioServiceManager.pigeonChannelCodec,
      (_) => serviceStarted.complete(),
    );
    host(
      'MeditoAndroidAudioServiceManager',
      'isServiceReady',
      MeditoAndroidAudioServiceManager.pigeonChannelCodec,
      (_) => true,
    );
    audioHost('setBellCues', (_) => null);
    audioHost('setBackgroundSoundVolume', (_) => null);
    audioHost('setSessionBells', (_) => null);
    audioHost('playAudio', (_) {
      playCalls++;
      return true;
    });
  });

  test(
    'el puente envía el tipo, archivo y tiempo del cierre elegido',
    () async {
      audioHost('setBellCues', (message) {
        expect(message, [
          false,
          [
            BellCue(
              offsetMs: 0,
              kind: 'start',
              assetKey: 'assets/audio/session_bell_v2.wav',
            ),
            BellCue(
              offsetMs: 178324,
              kind: 'end',
              assetKey: 'assets/audio/bells/p8-kalimba.mp3',
            ),
          ],
        ]);
        return null;
      });
      await player.play(request);
      expect(playCalls, 1);
    },
  );

  test('detener durante la espera del servicio cancela playAudio', () async {
    final starting = player.play(request);
    await serviceStarted.future;
    await pumpEventQueue();
    final result = await player.closeTimer();
    await starting;
    expect(result?.stopped, isTrue);
    expect(result?.elapsed, Duration.zero);
    expect(playCalls, 0);
    expect(closes, hasLength(1));
  });

  test(
    'un cierre rechazado deja la sesión abierta y permite reintentar',
    () async {
      var attempts = 0;
      audioHost('stopTimerPlayback', (message) {
        expect(message, [42]);
        return TimerStopReport(
          positionMs: 42000,
          stopped: ++attempts == 2,
          endCueRang: false,
        );
      });
      await player.play(request);
      expect(playCalls, 1);
      final failed = await player.closeTimer();
      expect(failed?.stopped, isFalse);
      expect(closes, isEmpty);
      final stopped = await player.closeTimer();
      expect(stopped?.stopped, isTrue);
      expect(stopped?.elapsed, const Duration(seconds: 42));
      expect(closes, [stopped]);
      expect(attempts, 2);
    },
  );

  for (final switchAccount in [false, true]) {
    test(
      'descarta un cierre pendiente al cambiar o borrar la cuenta ($switchAccount)',
      () async {
        await PlaybackAccount.clear();
        await PlaybackAccount.bind('cliente', userId: 'anterior');
        final stopping = Completer<void>();
        final report = Completer<TimerStopReport>();
        audioHost('stopTimerPlayback', (_) {
          stopping.complete();
          return report.future;
        });
        await player.play(request);
        final close = player.closeTimer();
        await stopping.future;
        if (switchAccount) {
          await PlaybackAccount.bind('cliente', userId: 'nuevo');
        } else {
          await PlaybackAccount.clear();
        }
        report.complete(
          TimerStopReport(positionMs: 95000, stopped: true, endCueRang: false),
        );
        expect(await close, isNull);
        expect(closes, isEmpty);
        expect(await player.closeTimer(), isNull);
      },
    );
  }

  test(
    'un cierre anticipado toca el sonido guardado en la solicitud',
    () async {
      const selected = 'assets/audio/bells/p8-kalimba.mp3';
      final sounded = Completer<void>();
      when(() => preview.play(any(), assetKey: selected)).thenAnswer((_) async {
        sounded.complete();
      });
      audioHost(
        'stopTimerPlayback',
        (_) => TimerStopReport(
          positionMs: 90000,
          stopped: true,
          endCueRang: false,
          completionPersisted: true,
        ),
      );
      await player.play(request);
      verify(preview.stop).called(1);
      expect((await player.closeTimer())?.recorded, isTrue);
      await sounded.future.timeout(const Duration(seconds: 2));
      verify(() => preview.play(any(), assetKey: selected)).called(1);
    },
  );

  test(
    'aplica el último interruptor si cambia durante el puente de Android',
    () async {
      final sent = <bool>[];
      final changing = Completer<void>();
      final first = Completer<void>();
      audioHost('setSessionBells', (message) {
        sent.add((message as List).single as bool);
        if (sent.length != 1) return null;
        changing.complete();
        return first.future;
      });
      audioHost('playAudio', (_) {
        expect(sent, [true, false]);
        playCalls++;
        return true;
      });

      final starting = player.play(request);
      await changing.future;
      sound.moveSwitch(false);
      first.complete();
      await starting;
      expect(playCalls, 1);
    },
  );
}
