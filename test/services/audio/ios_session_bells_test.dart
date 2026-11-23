import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/services/audio/ios_session_bells.dart';

class _Player extends Mock implements AudioPlayer {}

void main() {
  late _Player primary;
  late _Player bell;
  late StreamController<Duration> positions;
  late StreamController<Duration> bellPositions;
  late StreamController<PositionDiscontinuity> discontinuities;
  late List<_Player> createQueue;
  late IosSessionBells controller;
  var position = Duration.zero;
  var playing = false;
  var processing = ProcessingState.ready;
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    primary = _Player();
    bell = _Player();
    positions = StreamController<Duration>.broadcast(sync: true);
    bellPositions = StreamController<Duration>.broadcast(sync: true);
    discontinuities = StreamController<PositionDiscontinuity>.broadcast(
      sync: true,
    );
    createQueue = [bell];
    when(() => bell.positionStream).thenAnswer((_) => bellPositions.stream);
    position = Duration.zero;
    playing = false;
    processing = ProcessingState.ready;
    when(() => primary.positionStream).thenAnswer((_) => positions.stream);
    when(
      () => primary.playerStateStream,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => primary.positionDiscontinuityStream,
    ).thenAnswer((_) => discontinuities.stream);
    when(() => primary.position).thenAnswer((_) => position);
    when(() => primary.speed).thenReturn(1.0);
    when(() => primary.playing).thenAnswer((_) => playing);
    when(() => primary.processingState).thenAnswer((_) => processing);
    when(() => primary.duration).thenReturn(const Duration(minutes: 10));
    when(
      () => bell.setAsset(kSessionBellAsset),
    ).thenAnswer((_) async => const Duration(seconds: 6));
    when(() => bell.setVolume(any())).thenAnswer((_) async {});
    when(() => bell.seek(Duration.zero)).thenAnswer((_) async {});
    when(() => bell.play()).thenAnswer((_) async {});
    when(() => bell.pause()).thenAnswer((_) async {});
    when(() => bell.stop()).thenAnswer((_) async {});
    when(bell.dispose).thenAnswer((_) async {});
    when(() => bell.processingState).thenReturn(ProcessingState.ready);
    when(() => bell.playing).thenReturn(false);
    when(() => bell.position).thenReturn(Duration.zero);
    controller = IosSessionBells(
      primary,
      createPlayer: () => createQueue.removeAt(0),
    );
  });

  tearDown(() async {
    await controller.disable();
    await positions.close();
    await bellPositions.close();
    await discontinuities.close();
  });

  test(
    'paused selection waits for playback and resume does not duplicate cue',
    () async {
      await controller.enable(.5);
      verifyNever(() => bell.play());
      playing = true;
      positions.add(position);
      await flush();
      verify(() => bell.play()).called(1);
      playing = false;
      positions.add(position);
      playing = true;
      positions.add(position);
      await flush();
      verifyNever(() => bell.play());
      position = const Duration(minutes: 5);
      positions.add(position);
      await flush();
      verify(() => bell.play()).called(1);
    },
  );

  test(
    'completion pauses the bell without starting or awaiting a final ring',
    () async {
      await controller.enable(.5);
      processing = ProcessingState.completed;
      positions.add(const Duration(minutes: 10));
      await flush();
      verifyNever(() => bell.play());
      verify(() => bell.pause()).called(greaterThanOrEqualTo(1));
    },
  );

  test('deselecting while asset loads prevents stale playback', () async {
    playing = true;
    final loading = Completer<Duration?>();
    when(
      () => bell.setAsset(kSessionBellAsset),
    ).thenAnswer((_) => loading.future);
    final enabling = controller.enable(.5);
    await controller.disable();
    loading.complete(const Duration(seconds: 6));
    await enabling;
    verifyNever(() => bell.play());
  });

  test('a full session rings at beginning, middle and end', () async {
    await controller.enable(.5);
    playing = true;
    positions.add(Duration.zero);
    await flush();
    verify(() => bell.play()).called(1);
    position = const Duration(minutes: 5);
    positions.add(position);
    await flush();
    verify(() => bell.play()).called(1);
    position = const Duration(seconds: 594);
    positions.add(position);
    await flush();
    verify(() => bell.play()).called(1);
    position = const Duration(minutes: 10);
    processing = ProcessingState.completed;
    positions.add(position);
    await flush();
    verifyNever(() => bell.play());
  });
  test(
    'precarga el inicio y toca al llegar al tiempo previsto sin completar el archivo',
    () async {
      await controller.setBellCues(
        cues: const [
          TimerBellCue(0, TimerBellKind.start, kSessionBellAsset),
          TimerBellCue(60000, TimerBellKind.interval, kSessionBellAsset),
          TimerBellCue(180000, TimerBellKind.end, kSessionBellAsset),
        ],
        enabled: true,
        volume: .5,
      );
      verify(() => bell.setAsset(kSessionBellAsset)).called(1);
      verifyNever(() => bell.play());
      playing = true;
      positions.add(Duration.zero);
      await flush();
      verify(() => bell.play()).called(1);
      position = const Duration(minutes: 3);
      positions.add(position);
      await flush();
      verify(() => bell.play()).called(1);
      bellPositions.add(const Duration(milliseconds: 100));
      expect(controller.stopBellsAndReportEnd(), isTrue);
      position += const Duration(seconds: 1);
      positions.add(position);
      await flush();
      verifyNever(() => bell.play());
    },
  );

  test('el cierre silenciado se consume y no se reporta como oído', () async {
    await controller.setBellCues(
      cues: const [
        TimerBellCue(0, TimerBellKind.start, kSessionBellAsset),
        TimerBellCue(60000, TimerBellKind.end, kSessionBellAsset),
      ],
      enabled: false,
      volume: .5,
    );
    verify(() => bell.setAsset(kSessionBellAsset)).called(1);
    playing = true;
    positions.add(Duration.zero);
    position = const Duration(minutes: 1);
    positions.add(position);
    await controller.setTimerEnabled(true, .5);
    verifyNever(() => bell.setAsset(kSessionBellAsset));
    positions.add(position);
    await flush();
    verifyNever(() => bell.play());
    expect(controller.stopBellsAndReportEnd(), isFalse);
  });

  test(
    'detener durante el salto del cierre cancela el sonido pendiente',
    () async {
      await controller.setBellCues(
        cues: const [TimerBellCue(60000, TimerBellKind.end, kSessionBellAsset)],
        enabled: true,
        volume: .5,
      );
      final seeking = Completer<void>();
      final seekingStarted = Completer<void>();
      when(() => bell.seek(Duration.zero)).thenAnswer((_) {
        seekingStarted.complete();
        return seeking.future;
      });
      playing = true;
      position = const Duration(minutes: 1);
      positions.add(position);
      await seekingStarted.future;
      expect(controller.stopBellsAndReportEnd(), isFalse);
      seeking.complete();
      await flush();
      verifyNever(() => bell.play());
    },
  );

  test('conserva el último interruptor antes y durante la precarga', () async {
    final loading = Completer<Duration?>();
    when(
      () => bell.setAsset(kSessionBellAsset),
    ).thenAnswer((_) => loading.future);

    final installing = controller.setBellCues(
      cues: const [
        TimerBellCue(0, TimerBellKind.start, kSessionBellAsset),
        TimerBellCue(8000, TimerBellKind.interval, kSessionBellAsset),
      ],
      enabled: true,
      volume: .5,
    );
    await controller.setTimerEnabled(false, .5);
    await flush();
    await controller.setTimerEnabled(true, .5);
    await controller.setTimerEnabled(false, .5);
    loading.complete(const Duration(seconds: 6));
    await installing;

    expect(controller.enabled, isFalse);
    playing = true;
    positions.add(Duration.zero);
    await flush();
    verifyNever(() => bell.play());
    await controller.setTimerEnabled(true, .5);
    position = const Duration(seconds: 8);
    positions.add(position);
    await flush();
    verify(() => bell.play()).called(1);
  });

  test(
    'precarga archivos distintos y una campana reemplaza a la anterior',
    () async {
      final second = _Player();
      createQueue.add(second);
      final selected = BellSound.resolve('kalimba').assetKey;
      final loading = Completer<Duration?>();
      when(() => second.setAsset(selected)).thenAnswer((_) => loading.future);
      when(() => second.setVolume(any())).thenAnswer((_) async {});
      when(() => second.seek(Duration.zero)).thenAnswer((_) async {});
      when(second.play).thenAnswer((_) async {});
      when(second.pause).thenAnswer((_) async {});
      when(second.dispose).thenAnswer((_) async {});
      when(() => second.processingState).thenReturn(ProcessingState.ready);
      when(() => second.playing).thenReturn(true);

      final preload = controller.setBellCues(
        cues: [
          const TimerBellCue(0, TimerBellKind.start, kSessionBellAsset),
          TimerBellCue(8000, TimerBellKind.interval, selected),
          TimerBellCue(16000, TimerBellKind.interval, selected),
        ],
        enabled: true,
        volume: .5,
      );
      await flush();
      verify(() => second.setAsset(selected)).called(1);
      controller.setVolume(.8);
      verify(() => bell.setVolume(.8)).called(1);
      verify(() => second.setVolume(.8)).called(1);
      loading.complete(const Duration(seconds: 4));
      await preload;
      verify(() => second.setVolume(.8)).called(1);

      playing = true;
      positions.add(position);
      await flush();
      verify(bell.play).called(1);
      position = const Duration(seconds: 8);
      positions.add(position);
      await flush();
      verifyInOrder([
        bell.pause,
        () => second.seek(Duration.zero),
        second.play,
      ]);
    },
  );

  test(
    'una búsqueda cancela el salto pendiente y descarta la campana activa',
    () async {
      await controller.setBellCues(
        cues: const [
          TimerBellCue(0, TimerBellKind.start, kSessionBellAsset),
          TimerBellCue(8000, TimerBellKind.interval, kSessionBellAsset),
        ],
        enabled: true,
        volume: .5,
      );
      final seeking = Completer<void>();
      when(() => bell.seek(Duration.zero)).thenAnswer((_) => seeking.future);
      void seek(int seconds) {
        final before = PlaybackEvent(updatePosition: position);
        position = Duration(seconds: seconds);
        discontinuities.add(
          PositionDiscontinuity(
            PositionDiscontinuityReason.seek,
            before,
            PlaybackEvent(updatePosition: position),
          ),
        );
      }

      playing = true;
      positions.add(position);
      await flush();
      verify(() => bell.seek(Duration.zero)).called(1);
      seek(2);
      seeking.complete();
      await flush();
      verifyNever(bell.play);

      position = const Duration(seconds: 8);
      positions.add(position);
      await flush();
      verify(bell.play).called(1);
      seek(10);
      await flush();
      verify(bell.pause).called(1);
      verifyNever(bell.play);
    },
  );

  for (final fallbackWorks in [true, false]) {
    test(
      'espera el respaldo y omite archivos si falla ($fallbackWorks)',
      () async {
        final fallback = bell;
        final selected = BellSound.resolve('kalimba').assetKey;
        final rejected = _Player();
        createQueue.insert(0, rejected);
        when(
          () => rejected.setAsset(selected),
        ).thenThrow(StateError('Archivo dañado'));
        when(rejected.dispose).thenAnswer((_) async {});
        final loading = Completer<Duration?>();
        when(
          () => fallback.setAsset(kSessionBellAsset),
        ).thenAnswer((_) => loading.future);
        var ready = false;
        final preload = controller
            .setBellCues(
              cues: [TimerBellCue(0, TimerBellKind.start, selected)],
              enabled: true,
              volume: .5,
            )
            .then((_) => ready = true);
        await flush();
        verify(() => fallback.setAsset(kSessionBellAsset)).called(1);
        expect(ready, isFalse);
        if (fallbackWorks) {
          loading.complete(const Duration(seconds: 6));
        } else {
          loading.completeError(StateError('Respaldo dañado'));
        }
        await preload;

        playing = true;
        positions.add(position);
        await flush();
        if (fallbackWorks) {
          verify(fallback.play).called(1);
        } else {
          verifyNever(fallback.play);
        }
        verifyNever(rejected.play);
      },
    );
  }
}
