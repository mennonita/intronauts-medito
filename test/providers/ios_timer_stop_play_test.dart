import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/player/ios_audio_handler.dart';
import 'package:medito/services/audio/ios_session_bells.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:mocktail/mocktail.dart';

class _AudioPlayer extends Mock implements AudioPlayer {}

class _Bells extends Mock implements IosSessionBells {}

class _Source extends Fake implements AudioSource {}

class _Handler extends IosAudioHandler {
  _Handler(AudioPlayer player, this._bells) : super(player: player);

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
}
