import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:medito/providers/player/ios_audio_handler.dart';
import 'package:medito/services/audio/ios_session_bells.dart';
import 'package:mocktail/mocktail.dart';

class _AudioPlayer extends Mock implements AudioPlayer {}

class _Bells extends Mock implements IosSessionBells {}

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

  late List<String> calls;
  late bool playing;
  late String? runId;
  late TimerInterruptionController controller;

  AudioInterruptionEvent event(bool begin, AudioInterruptionType type) =>
      AudioInterruptionEvent(begin, type);

  setUp(() {
    calls = [];
    playing = true;
    runId = 'run-a';
    controller = TimerInterruptionController(
      isPlaying: () {
        calls.add('read');
        return playing;
      },
      currentRunId: () => runId,
      pauseAll: () async {
        calls.add('pause');
        playing = false;
      },
      resumeAll: () async {
        calls.add('resume');
        playing = true;
      },
      duck: (ducked) => calls.add(ducked ? 'duck' : 'unduck'),
    );
  });

  test('lee si sonaba ANTES de pausar y reanuda al terminar', () async {
    await controller.handleInterruption(
      event(true, AudioInterruptionType.pause),
    );
    expect(calls, ['read', 'pause']);
    await controller.handleInterruption(
      event(false, AudioInterruptionType.pause),
    );
    expect(calls, ['read', 'pause', 'resume']);
  });

  test('una segunda interrupción no pisa el estado guardado', () async {
    await controller.handleInterruption(
      event(true, AudioInterruptionType.pause),
    );
    await controller.handleInterruption(
      event(true, AudioInterruptionType.unknown),
    );
    expect(calls.where((call) => call == 'read'), hasLength(1));
    await controller.handleInterruption(
      event(false, AudioInterruptionType.pause),
    );
    expect(calls.last, 'resume');
  });

  test('si ya estaba en pausa no se reanuda', () async {
    playing = false;
    await controller.handleInterruption(
      event(true, AudioInterruptionType.pause),
    );
    await controller.handleInterruption(
      event(false, AudioInterruptionType.pause),
    );
    expect(calls, isNot(contains('resume')));
  });

  test('no reanuda otra sesión', () async {
    await controller.handleInterruption(
      event(true, AudioInterruptionType.pause),
    );
    runId = 'run-b';
    await controller.handleInterruption(
      event(false, AudioInterruptionType.pause),
    );
    expect(calls, isNot(contains('resume')));
  });

  test('un final que no permite reanudar deja la pausa', () async {
    await controller.handleInterruption(
      event(true, AudioInterruptionType.pause),
    );
    await controller.handleInterruption(
      event(false, AudioInterruptionType.unknown),
    );
    expect(calls, isNot(contains('resume')));
    // Y la siguiente interrupción empieza de cero.
    await controller.handleInterruption(
      event(false, AudioInterruptionType.pause),
    );
    expect(calls, isNot(contains('resume')));
  });

  test('bajar el volumen no pausa', () async {
    await controller.handleInterruption(
      event(true, AudioInterruptionType.duck),
    );
    await controller.handleInterruption(
      event(false, AudioInterruptionType.duck),
    );
    expect(calls, ['duck', 'unduck']);
  });

  test('desconectar audífonos pausa y no reanuda después', () async {
    await controller.handleBecomingNoisy();
    expect(calls, ['pause']);
    await controller.handleInterruption(
      event(false, AudioInterruptionType.pause),
    );
    expect(calls, ['pause']);
  });

  test('la interrupción pausa juntos voz, campanas y fondo', () async {
    final player = _AudioPlayer();
    final bells = _Bells();
    when(player.pause).thenAnswer((_) async {});
    when(() => player.playing).thenReturn(true);
    when(bells.pauseForInterruption).thenAnswer((_) async {});
    final handler = _Handler(player, bells);
    var ambientPaused = 0;
    handler.pauseAmbient = () => ambientPaused++;
    final paused = Completer<void>();
    unawaited(
      handler.interruptions
          .handleInterruption(event(true, AudioInterruptionType.pause))
          .then(paused.complete),
    );
    await paused.future;
    verify(player.pause).called(1);
    verify(bells.pauseForInterruption).called(1);
    expect(ambientPaused, 1);
  });
}
