import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/services/audio/ios_session_bells.dart';

class _Player extends Mock implements AudioPlayer {}

void main() {
  late _Player primary;
  late _Player bell;
  late StreamController<Duration> positions;
  late StreamController<Duration> bellPositions;
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
    ).thenAnswer((_) => const Stream.empty());
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
    when(() => bell.processingState).thenReturn(ProcessingState.ready);
    when(() => bell.playing).thenReturn(false);
    when(() => bell.position).thenReturn(Duration.zero);
    controller = IosSessionBells(primary, bell: bell);
  });

  tearDown(() async {
    await controller.disable();
    await positions.close();
    await bellPositions.close();
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
        offsetsMs: [0, 60000, 180000],
        endOffsetMs: 180000,
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
      offsetsMs: [0, 60000],
      endOffsetMs: 60000,
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
        offsetsMs: [60000],
        endOffsetMs: 60000,
        enabled: true,
        volume: .5,
      );
      final seeking = Completer<void>();
      when(() => bell.seek(Duration.zero)).thenAnswer((_) => seeking.future);
      playing = true;
      position = const Duration(minutes: 1);
      positions.add(position);
      expect(controller.stopBellsAndReportEnd(), isFalse);
      seeking.complete();
      await flush();
      verifyNever(() => bell.play());
    },
  );

  test('conserva el último interruptor antes y durante la precarga', () async {
    final stopping = Completer<void>();
    final loading = Completer<Duration?>();
    when(() => bell.stop()).thenAnswer((_) => stopping.future);
    when(
      () => bell.setAsset(kSessionBellAsset),
    ).thenAnswer((_) => loading.future);

    final installing = controller.setBellCues(
      offsetsMs: [0, 8000],
      enabled: true,
      volume: .5,
    );
    await controller.setTimerEnabled(false, .5);
    stopping.complete();
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
}
