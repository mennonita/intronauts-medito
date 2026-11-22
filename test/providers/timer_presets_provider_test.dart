import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_preset.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_settings.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/timer/timer_presets_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mocktail/mocktail.dart';

class _Preferences extends Mock implements SharedPreferences {}

void main() {
  const settings = TimerSettings(
    mode: TimerMode.countdown,
    minutes: 12,
    extraTime: true,
    bells: TimerBellSettings(start: false, intervalMinutes: 3, randomCount: 4),
  );
  const sound = BackgroundSoundsModel(
    id: 'rain',
    title: 'Rain',
    path: '/rain',
    duration: 2,
  );
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ProviderContainer open([SharedPreferences? customPrefs]) {
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(customPrefs ?? prefs),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'guarda y borra ajustes y sonido sin cambiar la selección general',
    () async {
      await prefs.setString(SharedPreferenceConstants.bgSound, 'global');
      final notifier = open().read(timerPresetsProvider.notifier);
      await notifier.save('  Lluvia  ', settings, sound);
      await notifier.save('Silencio', settings, null);
      final reopened = open();
      final presets = reopened.read(timerPresetsProvider);
      expect(presets.map((preset) => preset.name), ['Lluvia', 'Silencio']);
      expect(presets.first.settings.minutes, 12);
      expect(presets.first.settings.extraTime, isTrue);
      expect(presets.first.settings.bells.toJson(), settings.bells.toJson());
      expect(presets.first.sound, sound);
      expect(presets.last.sound, isNull);
      expect(prefs.getString(SharedPreferenceConstants.bgSound), 'global');
      await reopened.read(timerPresetsProvider.notifier).delete(presets.first);
      expect(open().read(timerPresetsProvider).single.name, 'Silencio');
    },
  );

  test(
    'respeta la longitud del nombre, canStart y el límite de veinte',
    () async {
      final container = open();
      final notifier = container.read(timerPresetsProvider.notifier);
      await notifier.save(' ', settings, null);
      await notifier.save('x' * 31, settings, null);
      await notifier.save('Cero', settings.copyWith(minutes: 0), null);
      expect(container.read(timerPresetsProvider), isEmpty);
      await notifier.save(
        'Cronómetro',
        settings.copyWith(mode: TimerMode.stopwatch, minutes: 0),
        null,
      );
      for (var i = 1; i <= 20; i++) {
        await notifier.save('Temporizador $i', settings, null);
      }
      final presets = open().read(timerPresetsProvider);
      expect(presets, hasLength(kMaxTimerPresets));
      expect(presets.first.settings.mode, TimerMode.stopwatch);
      expect(presets.last.name, 'Temporizador 19');
    },
  );

  test('ignora un JSON roto y descarta solo las entradas inválidas', () async {
    await prefs.setString(
      SharedPreferenceConstants.timerPresets,
      '[malformado',
    );
    expect(open().read(timerPresetsProvider), isEmpty);
    final valid = const TimerPreset(
      name: 'Válido',
      settings: settings,
      sound: null,
    ).toJson();
    await prefs.setString(
      SharedPreferenceConstants.timerPresets,
      jsonEncode([
        {...valid, 'minutes': 0},
        {...valid, 'mode': 'inválido'},
        {...valid, 'name': ' '},
        valid,
      ]),
    );
    expect(open().read(timerPresetsProvider).single.name, 'Válido');
  });

  test('guarda y borra en pantalla solo tras confirmar la escritura', () async {
    final store = _Preferences();
    const key = SharedPreferenceConstants.timerPresets;
    when(() => store.getString(key)).thenReturn(null);
    when(store.reload).thenAnswer((_) async {});
    final pending = Completer<bool>();
    when(() => store.setString(key, any())).thenAnswer((_) => pending.future);
    final container = open(store);
    final notifier = container.read(timerPresetsProvider.notifier);

    final save = notifier.save('Lluvia', settings, sound);
    await pumpEventQueue();
    expect(container.read(timerPresetsProvider), isEmpty);
    pending.complete(true);
    expect(await save, isTrue);
    final preset = container.read(timerPresetsProvider).single;

    when(() => store.setString(key, any())).thenAnswer((_) async => false);
    expect(await notifier.delete(preset), isFalse);
    expect(await notifier.save('Silencio', settings, null), isFalse);
    expect(container.read(timerPresetsProvider), [preset]);
    verify(store.reload).called(2);

    when(() => store.setString(key, any())).thenAnswer((_) async => true);
    expect(await notifier.delete(preset), isTrue);
    expect(container.read(timerPresetsProvider), isEmpty);
  });
}
