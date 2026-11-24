import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/player/ios_audio_handler.dart';
import 'package:medito/services/audio/ios_session_bells.dart';
import 'package:medito/services/timer/ios_timer_run_store.dart';
import 'package:medito/services/timer/timer_end_backup.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:mocktail/mocktail.dart';

class _AudioPlayer extends Mock implements AudioPlayer {}

class _Bells extends Mock implements IosSessionBells {}

class _Source extends Fake implements AudioSource {}

class _RunStore extends Mock implements IosTimerRunStore {}

class _EndBackup extends Mock implements TimerEndBackup {}

class _Handler extends IosAudioHandler {
  _Handler(
    AudioPlayer player,
    this._bells, {
    super.runStore,
    super.endBackup,
  }) : super(player: player);

  final IosSessionBells _bells;

  @override
  IosSessionBells get sessionBells => _bells;

  @override
  Future<void> ensureInitialized() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Play queda bloqueado hasta instalar otra fuente', () async {
    registerFallbackValue(_Source());
    final player = _AudioPlayer();
    final bells = _Bells();
    when(player.pause).thenAnswer((_) async {});
    when(() => player.setSpeed(1)).thenAnswer((_) async {});
    when(() => player.setAudioSource(any())).thenAnswer((_) async => null);
    when(() => player.setLoopMode(LoopMode.off)).thenAnswer((_) async {});
    when(player.play).thenAnswer((_) async {});
    when(() => player.playing).thenReturn(false);
    when(bells.disable).thenAnswer((_) async {});
    when(
      () => bells.setBellCues(
        cues: any(named: 'cues'),
        enabled: any(named: 'enabled'),
        volume: any(named: 'volume'),
      ),
    ).thenAnswer((_) async {});

    final stopGate = Completer<void>();
    when(player.stop).thenAnswer((_) => stopGate.future);
    final handler = _Handler(player, bells);
    final request = timerPlaybackRequest(
      mode: TimerMode.countdown,
      duration: const Duration(minutes: 1),
      filePath: '/tmp/timer.wav',
      title: 'Temporizador',
    );
    final track = Track(
      id: request.trackId,
      title: request.title,
      fileId: request.fileId,
      description: '',
      imageUrl: '',
    );

    await handler.setUrl(null, request, track);
    final stopping = handler.stopPlayback();
    await handler.play();
    verifyNever(player.play);
    stopGate.complete();
    await stopping;
    await handler.play();
    verifyNever(player.play);

    await handler.setUrl(null, request, track);
    await handler.play();
    verify(player.play).called(1);
  });

  test(
    'cambiar de cuenta para el fondo de inmediato; el cierre propio no (R38)',
    () async {
      registerFallbackValue(_Source());
      final player = _AudioPlayer();
      final bells = _Bells();
      when(player.pause).thenAnswer((_) async {});
      when(() => player.setSpeed(1)).thenAnswer((_) async {});
      when(() => player.setAudioSource(any())).thenAnswer((_) async => null);
      when(() => player.setLoopMode(LoopMode.off)).thenAnswer((_) async {});
      when(player.stop).thenAnswer((_) async {});
      when(() => player.playing).thenReturn(false);
      when(bells.disable).thenAnswer((_) async {});
      when(
        () => bells.setBellCues(
          cues: any(named: 'cues'),
          enabled: any(named: 'enabled'),
          volume: any(named: 'volume'),
          output: any(named: 'output'),
        ),
      ).thenAnswer((_) async {});
      final handler = _Handler(player, bells);
      var ambientPauses = 0;
      handler.pauseAmbient = () => ambientPauses++;
      final ambientStop = Completer<void>();
      var ambientStopped = 0;
      handler.stopAmbientPlayer = () {
        ambientStopped++;
        return ambientStop.future;
      };
      final request = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 1),
        filePath: '/tmp/timer.wav',
        title: 'Temporizador',
      );
      final track = Track(
        id: request.trackId,
        title: request.title,
        fileId: request.fileId,
        description: '',
        imageUrl: '',
      );

      await handler.setUrl(null, request, track);
      // Cierre propio: el fondo se apaga después, con desvanecido.
      await handler.stopPlayback(full: false);
      expect(ambientPauses, 0);

      await handler.setUrl(null, request, track);
      clearInteractions(player);
      final discarding = handler.discardPlayback();
      await pumpEventQueue();
      // Espera a que el fondo pare antes de soltar el resto.
      expect(ambientStopped, 1);
      verifyNever(player.stop);
      ambientStop.complete();
      await discarding;
      expect(iosAmbientActive, isFalse);
      verify(player.stop).called(greaterThanOrEqualTo(1));
    },
  );

  for (final interrupted in [false, true]) {
    test(
      'Play del sistema espera la precarga del temporizador ($interrupted)',
      () async {
        final player = _AudioPlayer();
        final bells = _Bells();
        when(player.pause).thenAnswer((_) async {});
        when(() => player.setSpeed(1)).thenAnswer((_) async {});
        when(() => player.setAudioSource(any())).thenAnswer((_) async => null);
        when(() => player.setLoopMode(LoopMode.off)).thenAnswer((_) async {});
        when(player.play).thenAnswer((_) async {});
        when(() => player.playing).thenReturn(false);
        when(player.stop).thenAnswer((_) async {});
        when(bells.disable).thenAnswer((_) async {});

        final entered = Completer<void>();
        final preload = Completer<void>();
        when(
          () => bells.setBellCues(
            cues: any(named: 'cues'),
            enabled: any(named: 'enabled'),
            volume: any(named: 'volume'),
          ),
        ).thenAnswer((_) {
          entered.complete();
          return preload.future;
        });
        final handler = _Handler(player, bells);
        final request = timerPlaybackRequest(
          mode: TimerMode.countdown,
          duration: const Duration(minutes: 1),
          filePath: '/tmp/timer.wav',
          title: 'Temporizador',
        );
        final opening = handler.setUrl(
          null,
          request,
          Track(
            id: request.trackId,
            title: request.title,
            fileId: request.fileId,
            description: '',
            imageUrl: '',
          ),
        );
        await entered.future;
        final systemPlay = handler.play();
        await pumpEventQueue();
        verifyNever(player.play);
        await handler.setSpeed(1.5);
        verifyNever(() => player.setSpeed(1.5));

        if (interrupted) {
          when(
            () => player.playerState,
          ).thenReturn(PlayerState(false, ProcessingState.completed));
          var stoppedBySystem = false;
          handler.onTimerStop = () async {
            stoppedBySystem = true;
            await handler.stopPlayback();
          };
          await handler.stop();
          await systemPlay;
          expect(stoppedBySystem, isTrue);
        }
        preload.complete();
        await opening;
        await systemPlay;
        if (interrupted) {
          verifyNever(player.play);
          verifyNever(() => player.setAudioSource(any()));
        } else {
          verify(player.play).called(1);
        }
      },
    );
  }

  test('el final natural publica la campana final con su runId antes de '
      'soltar las campanas (SIT-01)', () async {
    registerFallbackValue(_Source());
    final player = _AudioPlayer();
    final bells = _Bells();
    final runs = _RunStore();
    final backup = _EndBackup();
    when(player.pause).thenAnswer((_) async {});
    when(() => player.setSpeed(1)).thenAnswer((_) async {});
    when(() => player.setAudioSource(any())).thenAnswer((_) async => null);
    when(() => player.setLoopMode(LoopMode.off)).thenAnswer((_) async {});
    when(() => player.position).thenReturn(const Duration(minutes: 3));
    when(
      () => bells.setBellCues(
        cues: any(named: 'cues'),
        enabled: any(named: 'enabled'),
        volume: any(named: 'volume'),
        output: any(named: 'output'),
      ),
    ).thenAnswer((_) async {});
    when(() => bells.onEndCueStarted = any()).thenReturn(null);
    when(bells.reset).thenReturn(null);
    var deliveries = 0;
    bool? deliveredBeforeBells;
    when(bells.waitTimerBells).thenAnswer((_) async {
      deliveredBeforeBells = deliveries > 0;
    });
    // La campana final empezó durante la espera del final.
    var endStarted = true;
    when(() => bells.endCueStarted).thenAnswer((_) => endStarted);
    when(bells.captureEndStarted).thenAnswer((_) => endStarted);
    bool? publishedBeforeRelease;
    late _Handler handler;
    final request = timerPlaybackRequest(
      mode: TimerMode.countdown,
      duration: const Duration(minutes: 3),
      filePath: '/tmp/timer.wav',
      title: 'Temporizador',
    );
    when(bells.disable).thenAnswer((_) async {
      publishedBeforeRelease ??= handler.timerEndCueRang(request.timerRunId);
      // Soltar las campanas borra su marca.
      endStarted = false;
    });
    when(
      () => runs.finish(
        runId: any(named: 'runId'),
        durationMs: any(named: 'durationMs'),
        fallback: any(named: 'fallback'),
        generation: any(named: 'generation'),
        keepForRetry: any(named: 'keepForRetry'),
      ),
    ).thenAnswer((_) async => true);
    when(runs.deliver).thenAnswer((_) async {
      deliveries++;
      return null;
    });
    when(backup.cancel).thenAnswer((_) async {});
    handler = _Handler(player, bells, runStore: runs, endBackup: backup);
    handler.pauseAmbient = () {};
    await handler.setUrl(
      null,
      request,
      Track(
        id: request.trackId,
        title: request.title,
        fileId: request.fileId,
        description: '',
        imageUrl: '',
      ),
    );
    publishedBeforeRelease = null;

    await handler.completeTimer();

    expect(publishedBeforeRelease, isTrue);
    expect(bells.endCueStarted, isFalse);
    expect(handler.timerEndCueRang(request.timerRunId), isTrue);
    expect(handler.timerEndCueRang('otra-corrida'), isFalse);
    // Guardado: se entrega al historial antes de esperar las campanas (END-01).
    expect(deliveredBeforeBells, isTrue);
  });
}
