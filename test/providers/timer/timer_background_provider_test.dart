import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/timer/timer_background.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/timer/timer_background_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:medito/views/previews/preview_support.dart';

const _key = SharedPreferenceConstants.timerBackground;

class _FailingPreferences extends MemoryPrefs {
  _FailingPreferences() : super({_key: 'image:bruma'});

  final pending = Completer<bool>();
  bool throwsOnWrite = false;
  String? _cachedWrite;

  @override
  Future<bool> setString(String key, String value) {
    _cachedWrite = value;
    if (throwsOnWrite) throw StateError('Falló el guardado');
    return pending.future;
  }

  @override
  Object? get(String key) => _cachedWrite ?? super.get(key);

  @override
  Future<void> reload() async => _cachedWrite = null;
}

ProviderContainer _open(SharedPreferences prefs) {
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'guarda las selecciones en orden y recupera la última al abrir',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = _open(prefs).read(timerBackgroundProvider.notifier);
      final first = notifier.set(TimerBackground.mist);
      final second = notifier.set(TimerBackground.black);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(prefs.get('timerBackground'), 'black:negro');
      expect(_open(prefs).read(timerBackgroundProvider), TimerBackground.black);
    },
  );

  test('ignora preferencias de otro tipo o con texto inválido', () async {
    for (final raw in [
      17,
      false,
      ['image:bruma'],
      'black:desconocido',
    ]) {
      SharedPreferences.setMockInitialValues({_key: raw});
      final prefs = await SharedPreferences.getInstance();
      expect(
        _open(prefs).read(timerBackgroundProvider),
        TimerBackground.breathing,
      );
    }
  });

  test(
    'un guardado fallido conserva el fondo y la última preferencia',
    () async {
      final prefs = _FailingPreferences();
      final container = _open(prefs);
      final notifier = container.read(timerBackgroundProvider.notifier);
      expect(container.read(timerBackgroundProvider), TimerBackground.mist);

      final save = notifier.set(TimerBackground.black);
      await pumpEventQueue();
      expect(container.read(timerBackgroundProvider), TimerBackground.mist);
      expect(prefs.get(_key), 'black:negro');
      prefs.pending.complete(false);
      expect(await save, isFalse);
      expect(container.read(timerBackgroundProvider), TimerBackground.mist);
      expect(prefs.get(_key), 'image:bruma');

      prefs.throwsOnWrite = true;
      expect(await notifier.set(TimerBackground.sunrise), isFalse);
      expect(prefs.get(_key), 'image:bruma');
      expect(_open(prefs).read(timerBackgroundProvider), TimerBackground.mist);
    },
  );
}
