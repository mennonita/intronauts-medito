import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/timer/last_timer_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const key = SharedPreferenceConstants.timerLastSettings;
  const snapshot = LastTimerSnapshot(
    settings: {
      'minutes': 15,
      'stages': [
        {'kind': 'sit', 'minutes': 5},
        {'kind': 'walk', 'minutes': 10},
      ],
    },
    backgroundSoundId: 'rain',
    savedAtMs: 1000,
  );
  const replacement = LastTimerSnapshot(
    settings: {'minutes': 10},
    savedAtMs: 2000,
  );

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test(
    'guardar la sesión preparada escribe sus ajustes y libera el borrador',
    () async {
      LastTimerStore.stage('round-trip', snapshot);
      expect(prefs.containsKey(key), isFalse);
      expect(await LastTimerStore.commitStaged(prefs, 'round-trip'), isTrue);
      expect(prefs.containsKey(key), isTrue);
      expect(LastTimerStore.read(prefs)?.toJson(), {
        'v': 1,
        'settings': snapshot.settings,
        'backgroundSoundId': 'rain',
        'savedAtMs': 1000,
      });
      expect(await LastTimerStore.commitStaged(prefs, 'round-trip'), isFalse);
    },
  );

  test('un identificador distinto no escribe ni elimina el borrador', () async {
    LastTimerStore.stage('current-run', snapshot);
    expect(await LastTimerStore.commitStaged(prefs, 'other-run'), isFalse);
    expect(prefs.containsKey(key), isFalse);
    expect(await LastTimerStore.commitStaged(prefs, 'current-run'), isTrue);
  });

  test('sin un borrador no hay nada que guardar ni leer', () async {
    expect(await LastTimerStore.commitStaged(prefs, 'unstaged-run'), isFalse);
    expect(prefs.containsKey(key), isFalse);
    expect(LastTimerStore.read(prefs), isNull);
  });

  test('lee ajustes sin nombre y con sonido de fondo opcional', () async {
    await prefs.setString(
      key,
      '{"v":1,"settings":{"minutes":10},"savedAtMs":2000}',
    );
    expect(LastTimerStore.read(prefs)?.toJson(), replacement.toJson());
  });

  test('devuelve null con datos inválidos', () async {
    for (final raw in [
      '{json',
      '[]',
      '{"v":2,"settings":{},"savedAtMs":1}',
      '{"v":1,"settings":[],"savedAtMs":1}',
      '{"v":1,"settings":{},"backgroundSoundId":3,"savedAtMs":1}',
      '{"v":1,"settings":{},"savedAtMs":"1"}',
    ]) {
      await prefs.setString(key, raw);
      expect(LastTimerStore.read(prefs), isNull);
    }
    await prefs.setInt(key, 1);
    expect(LastTimerStore.read(prefs), isNull);
  });

  test('preparar otra sesión reemplaza el borrador anterior', () async {
    LastTimerStore.stage('first-run', snapshot);
    LastTimerStore.stage('second-run', replacement);
    expect(await LastTimerStore.commitStaged(prefs, 'first-run'), isFalse);
    expect(prefs.containsKey(key), isFalse);
    expect(await LastTimerStore.commitStaged(prefs, 'second-run'), isTrue);
    expect(LastTimerStore.read(prefs)?.toJson(), replacement.toJson());
  });

  test('un guardado pendiente conserva el borrador más reciente', () async {
    LastTimerStore.stage('saving-run', snapshot);
    final saving = LastTimerStore.commitStaged(prefs, 'saving-run');
    LastTimerStore.stage('next-run', replacement);
    expect(await saving, isTrue);
    expect(await LastTimerStore.commitStaged(prefs, 'next-run'), isTrue);
    expect(LastTimerStore.read(prefs)?.toJson(), replacement.toJson());
  });
}
