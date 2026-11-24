import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';

void main() {
  const sound = BackgroundSoundsModel(
    id: 'a-b',
    version: 'c',
    title: 'Rain',
    path: 'https://example.com/rain.mp3',
    duration: 60,
  );

  test('the name is stable and independent of the title and URL', () {
    const expected = 'bg-695274f6b86e6e905d2d63600faba937.mp3';
    expect(backgroundSoundFileName(sound), expected);
    expect(
      backgroundSoundFileName(sound.copyWith(title: '../x', path: '/new')),
      expected,
    );
  });

  test('the id and version are separated before hashing', () {
    expect(
      backgroundSoundFileName(sound),
      isNot(backgroundSoundFileName(sound.copyWith(id: 'a', version: 'b-c'))),
    );
    expect(
      backgroundSoundFileName(sound),
      isNot(backgroundSoundFileName(sound.copyWith(version: '2'))),
    );
  });

  test('a file name never contains server path text', () {
    final name = backgroundSoundFileName(
      sound.copyWith(id: 'a/b', version: '../x', title: 'Servidor'),
    );
    expect(name, matches(RegExp(r'^bg-[0-9a-f]{32}\.mp3$')));
    expect(name, isNot(contains('Servidor')));
    expect(name, isNot(contains('a/b')));
    expect(name, isNot(contains('../x')));
  });

  test('previously stored JSON defaults to an empty version', () {
    final oldJson = sound.toJson()..remove('version');
    expect(BackgroundSoundsModel.fromJson(oldJson).version, isEmpty);
  });
}
