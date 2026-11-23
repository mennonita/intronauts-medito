import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/services/audio/session_bell_preview.dart';

class _Player extends Mock implements AudioPlayer {}

void main() {
  late _Player player;
  late SessionBellPreview preview;
  setUp(() {
    player = _Player();
    when(
      () => player.setAsset(kSessionBellAsset),
    ).thenAnswer((_) async => const Duration(seconds: 6));
    when(() => player.setVolume(any())).thenAnswer((_) async {});
    when(player.pause).thenAnswer((_) async {});
    when(() => player.play()).thenAnswer((_) async {});
    when(() => player.stop()).thenAnswer((_) async {});
    when(() => player.dispose()).thenAnswer((_) async {});
    preview = SessionBellPreview(player: player);
  });

  test('audition plays the bundled bell without a primary player', () async {
    await preview.play(.4);
    verifyInOrder([
      () => player.setAsset(kSessionBellAsset),
      () => player.setVolume(.4),
      () => player.play(),
    ]);
  });

  test('switching sounds during load cancels stale audition', () async {
    final loaded = Completer<Duration?>();
    when(
      () => player.setAsset(kSessionBellAsset),
    ).thenAnswer((_) => loaded.future);
    final pending = preview.play(.4);
    await pumpEventQueue();
    verify(() => player.setAsset(kSessionBellAsset)).called(1);
    await preview.stop();
    loaded.complete(const Duration(seconds: 6));
    await pending;
    verifyNever(() => player.play());
  });

  test('dispose during load prevents late playback', () async {
    final loaded = Completer<Duration?>();
    when(
      () => player.setAsset(kSessionBellAsset),
    ).thenAnswer((_) => loaded.future);
    final pending = preview.play(.4);
    await pumpEventQueue();
    await preview.dispose();
    loaded.complete(const Duration(seconds: 6));
    await pending;
    verifyNever(() => player.play());
  });

  test(
    'tocar rápido pausa la muestra y reproduce solo el último archivo',
    () async {
      final obsolete = Completer<Duration?>();
      final selected = BellSound.resolve('kalimba').assetKey;
      when(
        () => player.setAsset(kSessionBellAsset),
      ).thenAnswer((_) => obsolete.future);
      when(
        () => player.setAsset(selected),
      ).thenAnswer((_) async => const Duration(seconds: 4));
      final first = preview.play(.4);
      await pumpEventQueue();
      final second = preview.play(.7, assetKey: selected);
      await second;
      obsolete.complete(const Duration(seconds: 6));
      await first;
      verifyInOrder([
        player.pause,
        () => player.setAsset(kSessionBellAsset),
        player.pause,
        () => player.setAsset(selected),
        () => player.setVolume(.7),
        player.play,
      ]);
      verifyNever(() => player.setVolume(.4));
      verifyNever(player.play);
    },
  );

  test(
    'una solicitud reemplazada antes de cargar no abre su archivo',
    () async {
      final selected = BellSound.resolve('kalimba').assetKey;
      when(
        () => player.setAsset(selected),
      ).thenAnswer((_) async => const Duration(seconds: 4));
      await Future.wait([
        preview.play(.4),
        preview.play(.7, assetKey: selected),
      ]);
      verifyNever(() => player.setAsset(kSessionBellAsset));
      verify(() => player.setAsset(selected)).called(1);
    },
  );
}
