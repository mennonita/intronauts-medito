import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import '../../models/background_sounds/background_sounds_model.dart';

final sessionBellPreview = SessionBellPreview();
final sessionBellPreviewProvider = Provider<SessionBellPreview>(
  (ref) => sessionBellPreview,
);

/// Reproduce una muestra sin cambiar las campanas de la sesión.
class SessionBellPreview {
  SessionBellPreview({AudioPlayer? player}) : _player = player;
  AudioPlayer? _player;
  int _generation = 0;
  Future<void>? _stopping;

  Future<void> play(
    double volume, {
    String assetKey = kSessionBellAsset,
  }) async {
    final generation = ++_generation;
    try {
      await _stopping;
      if (generation != _generation) return;
      final player = _player ??= AudioPlayer();
      await player.pause();
      if (generation != _generation) return;
      await player.setAsset(assetKey);
      if (generation != _generation) return;
      await player.setVolume(volume);
      if (generation != _generation) return;
      await player.play();
    } catch (_) {
      if (generation == _generation) rethrow;
    }
  }

  Future<void> stop() async {
    _generation++;
    final player = _player;
    if (player == null) return;
    final stopping = _stopping ??= player.stop();
    try {
      await stopping;
    } finally {
      if (identical(_stopping, stopping)) _stopping = null;
    }
  }

  Future<void> dispose() async {
    _generation++;
    await _player?.dispose();
    _player = null;
  }
}
