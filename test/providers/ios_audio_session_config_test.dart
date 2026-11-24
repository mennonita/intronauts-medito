import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/providers/player/ios_audio_handler.dart';

void main() {
  test('con «Música de otras apps» la sesión se mezcla con ellas', () {
    final config = IosAudioHandler.sessionConfiguration(mixWithOthers: true);
    expect(config.avAudioSessionCategory, AVAudioSessionCategory.playback);
    expect(
      config.avAudioSessionCategoryOptions,
      AVAudioSessionCategoryOptions.mixWithOthers,
    );
  });

  test('sin la preferencia la otra app se pausa', () {
    final config = IosAudioHandler.sessionConfiguration(mixWithOthers: false);
    expect(config.avAudioSessionCategory, AVAudioSessionCategory.playback);
    expect(
      config.avAudioSessionCategoryOptions,
      AVAudioSessionCategoryOptions.none,
    );
    expect(config.avAudioSessionMode, AVAudioSessionMode.defaultMode);
  });
}
