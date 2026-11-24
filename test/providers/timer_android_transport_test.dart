import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/last_timer_store.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/services/timer/timer_device_channel.dart';
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
  late List<TimerRunCloseResult> closes;
  late ProviderContainer container;

  Future<ProviderContainer> open({
    Duration startConfirmTimeout = const Duration(seconds: 10),
  }) async {
    final opened = ProviderContainer(
      overrides: [
        sessionBellPreviewProvider.overrideWithValue(preview),
        playerProvider.overrideWith(
          () => PlayerProvider(
            useAndroidAudio: true,
            startConfirmTimeout: startConfirmTimeout,
          ),
        ),
        audioStateProvider.overrideWith(AudioStateNotifier.new),
        backgroundSoundsNotifierProvider.overrideWith(_BackgroundSounds.new),
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(opened.dispose);
    return opened;
  }

  void playing(PlaybackRequest playing, {String? runId, int position = 1}) {
    final audio = container.read(audioStateProvider.notifier);
    audio.updatePlaybackState(
      container
          .read(audioStateProvider)
          .copyWith(
            isPlaying: true,
            position: position,
            duration: playing.duration,
            runId: runId ?? playing.timerRunId,
            track: Track(
              id: playing.trackId,
              title: playing.title,
              fileId: playing.fileId,
              description: '',
              imageUrl: '',
            ),
          ),
    );
  }

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
    container = await open();
    player = container.read(playerProvider.notifier);
    sound =
        container.read(backgroundSoundsNotifierProvider.notifier)
            as _BackgroundSounds;
    player.prepare(request);
    expect(player.reserveStart(request.timerRunId), isTrue);
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
              offsetMs:
                  180000, // La campana final suena justo al terminar (TECH-10).
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
    final result = await player.closeTimer(runId: request.timerRunId);
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
        expect(message, [42, true]);
        return TimerStopReport(
          positionMs: 42000,
          stopped: ++attempts == 2,
          endCueRang: false,
        );
      });
      await player.play(request);
      expect(playCalls, 1);
      final failed = await player.closeTimer(runId: request.timerRunId);
      expect(failed?.stopped, isFalse);
      expect(closes, isEmpty);
      final stopped = await player.closeTimer(runId: request.timerRunId);
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
        // La reserva de la cuenta anterior ya no vale (SES-08).
        expect(player.isReserved(request.timerRunId), isFalse);
        expect(player.reserveStart(request.timerRunId), isTrue);
        final stopping = Completer<void>();
        final report = Completer<TimerStopReport>();
        audioHost('stopTimerPlayback', (_) {
          stopping.complete();
          return report.future;
        });
        await player.play(request);
        final close = player.closeTimer(runId: request.timerRunId);
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
        expect(await player.closeTimer(runId: request.timerRunId), isNull);
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
      expect(
        (await player.closeTimer(runId: request.timerRunId))?.recorded,
        isTrue,
      );
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

  test('«Salir sin guardar» rechazado sigue sonando y lo reporta', () async {
    audioHost('stopTimerPlayback', (message) {
      expect(message, [42, false]);
      return TimerStopReport(
        positionMs: 95000,
        stopped: false,
        endCueRang: false,
      );
    });
    await player.play(request);
    final result = await player.closeTimer(
      runId: request.timerRunId,
      save: false,
    );
    expect(result?.stopped, isFalse);
    expect(result?.saved, isFalse);
    expect(result?.recorded, isFalse);
    expect(closes, isEmpty);
    expect(player.hasActiveSession, isTrue);
  });

  test('«Salir sin guardar» no registra ni abre el resumen', () async {
    audioHost('stopTimerPlayback', (message) {
      expect(message, [42, false]);
      return TimerStopReport(
        positionMs: 95000,
        stopped: true,
        endCueRang: false,
      );
    });
    await player.play(request);
    final result = await player.closeTimer(
      runId: request.timerRunId,
      save: false,
    );
    expect(result?.stopped, isTrue);
    expect(result?.recorded, isFalse);
    expect(closes, isEmpty);
    expect(player.hasActiveSession, isFalse);
    verifyNever(() => preview.play(any(), assetKey: any(named: 'assetKey')));
  });

  test('el tiempo del cierre no cuenta la preparación', () async {
    player.releaseStart(request.timerRunId);
    final prepared = request.copyWith(
      timerPrepMs: 30000,
      timerRunId: 'con-preparacion',
    );
    expect(player.reserveStart(prepared.timerRunId), isTrue);
    audioHost(
      'stopTimerPlayback',
      (_) =>
          TimerStopReport(positionMs: 90000, stopped: true, endCueRang: false),
    );
    await player.play(prepared);
    final result = await player.closeTimer(runId: prepared.timerRunId);
    expect(result?.elapsed, const Duration(seconds: 60));
    expect(result?.recorded, isTrue);
  });

  test('la reserva es única hasta soltarla o cerrar la sesión', () async {
    expect(player.reserveStart('otra'), isFalse);
    player.releaseStart(request.timerRunId);
    expect(player.hasActiveSession, isFalse);
    expect(player.reserveStart('otra'), isTrue);
    expect(player.reserveStart(request.timerRunId), isFalse);
    player.releaseStart('otra');

    expect(player.reserveStart(request.timerRunId), isTrue);
    audioHost(
      'stopTimerPlayback',
      (_) =>
          TimerStopReport(positionMs: 5000, stopped: true, endCueRang: false),
    );
    await player.play(request);
    expect(player.reserveStart('otra'), isFalse);
    await player.closeTimer(runId: request.timerRunId);
    expect(player.reserveStart('otra'), isTrue);
  });

  test('un temporizador sin reserva no empieza', () async {
    player.releaseStart(request.timerRunId);
    await player.play(request);
    expect(playCalls, 0);
    expect(player.hasActiveSession, isFalse);
  });

  test('una meditación guiada invalida la reserva pendiente', () async {
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
    try {
      await player.play(guided);
    } catch (_) {
      // Este arnés no simula todo el inicio guiado; basta la reserva.
    }
    expect(player.isReserved(request.timerRunId), isFalse);
    playCalls = 0;
    await player.play(request);
    expect(playCalls, 0);
  });

  test(
    'un error del reproductor con el mismo runId es un inicio fallido',
    () async {
      final stops = <Object?>[];
      audioHost('stopTimerPlayback', (message) {
        stops.add(message);
        return TimerStopReport(positionMs: 0, stopped: true, endCueRang: false);
      });
      await player.play(request);
      timerPlayerErrors.add('otra-sesion');
      await pumpEventQueue();
      expect(player.timerStartFailed.value, isNull);
      expect(player.hasActiveSession, isTrue);

      timerPlayerErrors.add(request.timerRunId);
      await pumpEventQueue();
      expect(player.timerStartFailed.value, request.timerRunId);
      expect(player.hasActiveSession, isFalse);
      expect(stops, [
        [42, false],
      ]);
      expect(closes, isEmpty);
    },
  );

  test('sin estado «sonando» en el plazo el inicio falla', () async {
    container = await open(
      startConfirmTimeout: const Duration(milliseconds: 20),
    );
    player = container.read(playerProvider.notifier);
    expect(player.reserveStart(request.timerRunId), isTrue);
    audioHost(
      'stopTimerPlayback',
      (_) => TimerStopReport(positionMs: 0, stopped: true, endCueRang: false),
    );
    await player.play(request);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(player.timerStartFailed.value, request.timerRunId);
    expect(player.hasActiveSession, isFalse);
  });

  test('«Repetir» se guarda solo cuando la sesión de verdad suena', () async {
    container = await open(
      startConfirmTimeout: const Duration(milliseconds: 1500),
    );
    player = container.read(playerProvider.notifier);
    final prefs = await SharedPreferences.getInstance();
    LastTimerStore.stage(
      request.timerRunId,
      const LastTimerSnapshot(settings: {'minutes': 3}, savedAtMs: 1),
    );
    expect(player.reserveStart(request.timerRunId), isTrue);
    await player.play(request);
    playing(request, position: 0);
    playing(request, runId: 'otra-sesion', position: 500);
    await pumpEventQueue();
    expect(LastTimerStore.read(prefs), isNull);

    playing(request, position: 500);
    await pumpEventQueue();
    expect(LastTimerStore.read(prefs)?.settings, {'minutes': 3});
    // Confirmado: el plazo ya no lo marca como fallido.
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(player.timerStartFailed.value, isNull);
  });

  test('la muestra del cierre con «Solo vibración» no toca audio', () async {
    TimerDeviceChannel.debugIsAndroid = true;
    addTearDown(() => TimerDeviceChannel.debugIsAndroid = null);
    final vibrations = <Object?>[];
    final vibrated = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('intronauts/timer_device'),
          (call) async {
            if (call.method == 'vibrateBell') {
              vibrations.add(call.arguments);
              vibrated.complete();
            }
            return null;
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('intronauts/timer_device'),
            null,
          ),
    );
    player.releaseStart(request.timerRunId);
    final silent = request.copyWith(
      timerBellOutput: 'vibration',
      timerRunId: 'vibracion',
    );
    expect(player.reserveStart(silent.timerRunId), isTrue);
    audioHost(
      'stopTimerPlayback',
      (_) =>
          TimerStopReport(positionMs: 90000, stopped: true, endCueRang: false),
    );
    await player.play(silent);
    expect(
      (await player.closeTimer(runId: silent.timerRunId))?.recorded,
      isTrue,
    );
    await vibrated.future.timeout(const Duration(seconds: 2));
    expect(vibrations, [
      {'repeats': 1},
    ]);
    verifyNever(() => preview.play(any(), assetKey: any(named: 'assetKey')));
  });

  test('el plazo de inicio corre aunque la carga no termine', () async {
    container = await open(
      startConfirmTimeout: const Duration(milliseconds: 20),
    );
    player = container.read(playerProvider.notifier);
    expect(player.reserveStart(request.timerRunId), isTrue);
    final never = Completer<Object?>();
    audioHost('playAudio', (_) => never.future);
    audioHost(
      'stopTimerPlayback',
      (_) => TimerStopReport(positionMs: 0, stopped: true, endCueRang: false),
    );
    unawaited(player.play(request));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(player.timerStartFailed.value, request.timerRunId);
    expect(player.hasActiveSession, isFalse);
    expect(player.reserveStart('siguiente'), isTrue);
  });

  test('cambiar de cuenta suelta la reserva y la sesión', () async {
    audioHost(
      'stopTimerPlayback',
      (_) => TimerStopReport(positionMs: 0, stopped: true, endCueRang: false),
    );
    await player.play(request);
    expect(player.hasActiveSession, isTrue);
    await PlaybackAccount.clear();
    expect(player.hasActiveSession, isFalse);
    expect(player.reserveStart('de-la-cuenta-nueva'), isTrue);
  });

  test(
    'cerrar con el runId de otra corrida no toca la activa (TIMER-05)',
    () async {
      final stops = <Object?>[];
      audioHost('stopTimerPlayback', (message) {
        stops.add(message);
        return TimerStopReport(
          positionMs: 90000,
          stopped: true,
          endCueRang: false,
        );
      });
      await player.play(request);
      expect(await player.closeTimer(runId: 'otra-corrida'), isNull);
      expect(await player.closeTimer(runId: '', save: false), isNull);
      expect(stops, isEmpty);
      expect(player.hasActiveSession, isTrue);

      final result = await player.closeTimer(runId: request.timerRunId);
      expect(result?.runId, request.timerRunId);
      expect(result?.recorded, isTrue);
      expect(stops, [
        [42, true],
      ]);
      expect(closes.single.runId, request.timerRunId);
    },
  );

  test(
    'el reporte nativo de otra corrida no cierra la activa (TIMER-05)',
    () async {
      await player.play(request);
      await player.timerStopped(
        42,
        TimerStopReport(
          positionMs: 90000,
          stopped: true,
          endCueRang: false,
          runId: 'otra-corrida',
        ),
      );
      expect(closes, isEmpty);
      expect(player.hasActiveSession, isTrue);

      await player.timerStopped(
        42,
        TimerStopReport(
          positionMs: 90000,
          stopped: true,
          endCueRang: false,
          runId: request.timerRunId,
        ),
      );
      expect(closes.single.runId, request.timerRunId);
    },
  );

  group('esperar el foco durante una llamada (REV-06)', () {
    void waitingForFocus({int position = 0}) {
      container
          .read(audioStateProvider.notifier)
          .updatePlaybackState(
            PlaybackState(
              isPlaying: false,
              isBuffering: false,
              isSeeking: false,
              isCompleted: false,
              position: position,
              duration: request.duration,
              speed: Speed(speed: 1),
              volume: 100,
              track: Track(
                id: request.trackId,
                title: request.title,
                fileId: request.fileId,
                description: '',
                imageUrl: '',
              ),
              runId: request.timerRunId,
              waitingForFocus: true,
            ),
          );
    }

    Future<void> openWith(Duration timeout) async {
      container = await open(startConfirmTimeout: timeout);
      player = container.read(playerProvider.notifier);
      expect(player.reserveStart(request.timerRunId), isTrue);
      audioHost(
        'stopTimerPlayback',
        (_) => TimerStopReport(positionMs: 0, stopped: true, endCueRang: false),
      );
    }

    test('la espera no vence el plazo; al colgar la sesión empieza', () async {
      await openWith(const Duration(milliseconds: 1500));
      await player.play(request);
      waitingForFocus();
      // La llamada dura más que el plazo de inicio.
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(player.timerStartFailed.value, isNull);
      expect(player.hasActiveSession, isTrue);

      // Se cuelga: el reloj avanza y el inicio se confirma.
      playing(request, position: 500);
      await pumpEventQueue();
      expect(player.timerStartFailed.value, isNull);
      expect(player.hasActiveSession, isTrue);
    });

    test('el plazo vuelve a contar cuando el reloj puede avanzar', () async {
      await openWith(const Duration(milliseconds: 1500));
      await player.play(request);
      waitingForFocus();
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(player.timerStartFailed.value, isNull);
      // Ya suena, pero la posición nunca avanza: es un fallo de verdad.
      playing(request, position: 0);
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(player.timerStartFailed.value, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(player.timerStartFailed.value, request.timerRunId);
      expect(player.hasActiveSession, isFalse);
    });

    test('la espera de otra corrida no detiene el plazo', () async {
      await openWith(const Duration(milliseconds: 1500));
      await player.play(request);
      container
          .read(audioStateProvider.notifier)
          .updatePlaybackState(
            container
                .read(audioStateProvider)
                .copyWith(runId: 'otra-corrida', waitingForFocus: true),
          );
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(player.timerStartFailed.value, request.timerRunId);
    });
  });

  group('una guiada reemplaza un temporizador en Android (TIMER-REVIEW-01)', () {
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

    Future<void> playGuided() async {
      try {
        await player.play(guided);
      } catch (_) {
        // Este arnés no simula todo el inicio guiado; basta el reemplazo.
      }
    }

    test(
      'guarda el temporizador con su posición final, nunca lo descarta',
      () async {
        final stops = <Object?>[];
        var playsAtStop = -1;
        audioHost('stopTimerPlayback', (message) {
          stops.add(message);
          playsAtStop = playCalls;
          return TimerStopReport(
            positionMs: 420000,
            stopped: true,
            endCueRang: false,
            completionPersisted: true,
            runId: request.timerRunId,
          );
        });
        await player.play(request);
        playing(request, position: 420000);
        expect(playCalls, 1);

        await playGuided();

        // save == true: el servicio guarda el cierre ANTES de cargar la guiada.
        expect(stops, [
          [42, true],
        ]);
        expect(playsAtStop, 1);
        // Reemplazar no abre el resumen del temporizador.
        expect(closes, isEmpty);
      },
    );

    test(
      'si el guardado falla, no se descarta: la sesión se conserva',
      () async {
        final stops = <Object?>[];
        audioHost('stopTimerPlayback', (message) {
          stops.add(message);
          // El servicio no pudo guardar: no detuvo nada y conserva el registro.
          return TimerStopReport(
            positionMs: 420000,
            stopped: false,
            endCueRang: false,
            completionPersisted: false,
            runId: request.timerRunId,
          );
        });
        await player.play(request);
        playing(request, position: 420000);

        await playGuided();

        // Nunca se pidió «salir sin guardar» (save == false borraría la sesión).
        expect(stops, [
          [42, true],
        ]);
        expect(closes, isEmpty);
      },
    );
  });

  group('cuenta vinculada antes de abrir el servicio (TIMER-REVIEW-03)', () {
    late List<MethodCall> accountCalls;
    late List<String> order;

    setUp(() {
      PlaybackAccount.resetForTesting();
      PlaybackAccount.bindsNatively = true;
      addTearDown(PlaybackAccount.resetForTesting);
      accountCalls = [];
      order = [];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('intronauts/playback_account');
      messenger.setMockMethodCallHandler(channel, (call) async {
        accountCalls.add(call);
        order.add('bind');
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      host(
        'MeditoAndroidAudioServiceManager',
        'startService',
        MeditoAndroidAudioServiceManager.pigeonChannelCodec,
        (_) {
          order.add('startService');
          if (!serviceStarted.isCompleted) serviceStarted.complete();
          return null;
        },
      );
    });

    test(
      'sin cuenta (ruta sin conexión) vincula una identidad local persistente',
      () async {
        await player.play(request);

        expect(playCalls, 1);
        expect(order.first, 'bind');
        expect(order, containsAllInOrder(['bind', 'startService']));
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getString(SharedPreferenceConstants.userId);
        expect(saved, isNotNull);
        expect(accountCalls.single.method, 'bind');
        expect((accountCalls.single.arguments as Map)['clientId'], saved);
        expect(PlaybackAccount.isBound, isTrue);
      },
    );

    test('con una identidad guardada vincula esa misma', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        SharedPreferenceConstants.userId,
        'cliente-guardado',
      );

      await player.play(request);

      expect(order, containsAllInOrder(['bind', 'startService']));
      expect(
        (accountCalls.single.arguments as Map)['clientId'],
        'cliente-guardado',
      );
    });
  });

  test(
    'una guiada que pide «No molestar» manda el nombre de la regla (REV-12)',
    () {
      final track = Track(
        id: 'guiada',
        title: 'Guiada',
        fileId: 'archivo',
        description: '',
        imageUrl: '',
      );
      final asked = PlayerProvider.guidedAudioData(
        'file:///tmp/guiada.mp3',
        track,
        dndRequested: true,
        dndRuleName: 'Temporizador de meditación',
      );
      expect(asked.dndRequested, isTrue);
      expect(asked.timerDndRuleName, 'Temporizador de meditación');
      expect(asked.timerSeed, isNull);

      final notAsked = PlayerProvider.guidedAudioData(
        'file:///tmp/guiada.mp3',
        track,
        dndRequested: false,
        dndRuleName: 'Temporizador de meditación',
      );
      expect(notAsked.timerDndRuleName, isNull);
    },
  );
}
