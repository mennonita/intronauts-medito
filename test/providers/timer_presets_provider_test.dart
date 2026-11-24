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
    bells: TimerBellSettings(
      start: false,
      intervalMinutes: 3,
      randomCount: 4,
      startSound: 'diapason',
      endSound: 'campana_templo',
      intervalSound: 'kalimba',
      randomSound: 'flauta',
    ),
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

  test('lee un temporizador guardado sin campos de sonido', () async {
    final legacy = settings.bells.toJson()
      ..removeWhere((key, _) => key.endsWith('Sound'));
    await prefs.setString(
      SharedPreferenceConstants.timerPresets,
      jsonEncode([
        {
          ...const TimerPreset(
            name: 'Anterior',
            settings: settings,
            sound: null,
          ).toJson(),
          'bells': legacy,
        },
      ]),
    );
    expect(open().read(timerPresetsProvider).single.settings.bells.toJson(), {
      ...legacy,
      'startSound': 'actual',
      'endSound': 'actual',
      'intervalSound': 'actual',
      'randomSound': 'actual',
    });
  });

  test(
    'conserva las repeticiones al volver a cargar un temporizador',
    () async {
      final repeatedBells = settings.bells.copyWith(
        startRepeats: 2,
        endRepeats: 3,
        intervalRepeats: 3,
        randomRepeats: 2,
      );
      await open()
          .read(timerPresetsProvider.notifier)
          .save('Repeticiones', settings.copyWith(bells: repeatedBells), null);
      expect(
        open().read(timerPresetsProvider).single.settings.bells.toJson(),
        repeatedBells.toJson(),
      );
    },
  );

  test(
    'carga una repetición por campana en temporizadores anteriores',
    () async {
      final legacy = settings.bells.toJson()
        ..removeWhere((key, _) => key.endsWith('Repeats'));
      await prefs.setString(
        SharedPreferenceConstants.timerPresets,
        jsonEncode([
          {
            ...const TimerPreset(
              name: 'Anterior',
              settings: settings,
              sound: null,
            ).toJson(),
            'bells': legacy,
          },
        ]),
      );
      expect(open().read(timerPresetsProvider).single.settings.bells.toJson(), {
        ...legacy,
        'startRepeats': 1,
        'endRepeats': 1,
        'intervalRepeats': 1,
        'randomRepeats': 1,
      });
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

  test('guarda y lee la preparación y las partes', () async {
    const stages = [
      TimerStage(kind: TimerStageKind.sit, minutes: 20, sound: 'diapason'),
      TimerStage(kind: TimerStageKind.walk, minutes: 10, repeats: 2),
    ];
    await open()
        .read(timerPresetsProvider.notifier)
        .save(
          'Partes',
          settings.copyWith(prepSeconds: 30, stages: stages),
          null,
        );
    final restored = open().read(timerPresetsProvider).single.settings;
    expect(restored.prepSeconds, 30);
    expect(restored.stages, stages);
    expect(restored.isMultiStage, isTrue);
  });

  test('lee temporizadores anteriores sin preparación ni partes', () async {
    final legacy =
        const TimerPreset(
            name: 'Anterior',
            settings: settings,
            sound: null,
          ).toJson()
          ..removeWhere((key, _) => key == 'prepSeconds' || key == 'stages');
    final bells =
        Map<String, Object?>.of(legacy['bells'] as Map<String, Object>)
          ..remove('output')
          ..remove('spokenCues');
    await prefs.setString(
      SharedPreferenceConstants.timerPresets,
      jsonEncode([
        {...legacy, 'bells': bells},
        {...legacy, 'name': 'Raro', 'prepSeconds': 'x', 'stages': 'y'},
        {
          ...legacy,
          'name': 'Partes rotas',
          'stages': [
            {'kind': 'sit', 'minutes': 5},
            'basura',
            {'kind': 'walk', 'minutes': 5},
          ],
        },
      ]),
    );
    final presets = open().read(timerPresetsProvider);
    expect(presets.map((preset) => preset.name), [
      'Anterior',
      'Raro',
      'Partes rotas',
    ]);
    expect(presets.first.settings.prepSeconds, 0);
    expect(presets.first.settings.stages, isEmpty);
    expect(presets.first.settings.bells.output, TimerBellOutput.sound);
    expect(presets.first.settings.bells.spokenCues, isFalse);
    expect(presets[1].settings.prepSeconds, 0);
    expect(presets[1].settings.stages, isEmpty);
    expect(presets.last.settings.stages.map((stage) => stage.minutes), [5, 5]);
  });

  test(
    'actualiza, renombra y mueve por id; un id ajeno no cambia nada',
    () async {
      final notifier = open().read(timerPresetsProvider.notifier);
      for (final name in ['Uno', 'Dos', 'Tres']) {
        await notifier.save(name, settings, null);
      }
      List<TimerPreset> current() => open().read(timerPresetsProvider);
      List<String> names() => current().map((preset) => preset.name).toList();
      final ids = current().map((preset) => preset.id).toList();
      expect(ids.toSet(), hasLength(3));
      expect(ids, everyElement(hasLength(32)));

      final updated = TimerPreset(
        id: 'ignorado',
        name: '  Dos largo  ',
        settings: settings.copyWith(minutes: 45, prepSeconds: 10),
        sound: sound,
      );
      expect(await notifier.update(ids[1], updated), isTrue);
      final presets = current();
      expect(presets[1].id, ids[1]);
      expect(presets[1].name, 'Dos largo');
      expect(presets[1].settings.minutes, 45);
      expect(presets[1].settings.prepSeconds, 10);
      expect(presets[1].sound, sound);
      await notifier.update('nadie', updated);
      await notifier.update(
        ids[0],
        TimerPreset(
          name: 'Cero',
          settings: settings.copyWith(minutes: 0),
          sound: null,
        ),
      );
      await notifier.update(
        ids[0],
        const TimerPreset(name: ' ', settings: settings, sound: null),
      );
      expect(names(), ['Uno', 'Dos largo', 'Tres']);

      await notifier.rename(ids[0], '  Mañana  ');
      await notifier.rename(ids[2], 'x' * 40);
      await notifier.rename(ids[1], '   ');
      await notifier.rename('nadie', 'Nada');
      expect(names(), ['Mañana', 'Dos largo', 'x' * kMaxTimerPresetNameLength]);
      expect(current()[0].settings.minutes, 12);

      await notifier.move(ids[0], 2);
      expect(names(), ['Dos largo', 'x' * 30, 'Mañana']);
      await notifier.move(ids[0], 0);
      expect(names(), ['Mañana', 'Dos largo', 'x' * 30]);
      await notifier.move(ids[0], 3);
      await notifier.move(ids[0], -1);
      await notifier.move('nadie', 0);
      expect(names(), ['Mañana', 'Dos largo', 'x' * 30]);
      expect(current().map((preset) => preset.id), ids);

      await notifier.delete(current()[1]);
      expect(names(), ['Mañana', 'x' * 30]);
    },
  );

  test(
    'mover y luego renombrar sin esperar cambia el mismo temporizador',
    () async {
      final notifier = open().read(timerPresetsProvider.notifier);
      await notifier.save('A', settings, null);
      await notifier.save('B', settings, null);
      final a = open().read(timerPresetsProvider).first;
      final move = notifier.move(a.id, 1);
      final rename = notifier.rename(a.id, 'A nuevo');
      final delete = notifier.delete(a);
      expect(await move, isTrue);
      expect(await rename, isTrue);
      expect(await delete, isTrue);
      expect(open().read(timerPresetsProvider).map((preset) => preset.name), [
        'B',
      ]);
    },
  );

  test('los temporizadores sin id reciben uno fijo y lo guardan', () async {
    final legacy = const TimerPreset(
      name: 'Anterior',
      settings: settings,
      sound: null,
    ).toJson()..remove('id');
    await prefs.setString(
      SharedPreferenceConstants.timerPresets,
      jsonEncode([
        legacy,
        {...legacy, 'name': 'Otro'},
      ]),
    );
    final first = open().read(timerPresetsProvider);
    expect(first.map((preset) => preset.id), ['anterior-0', 'anterior-1']);
    expect(open().read(timerPresetsProvider).map((preset) => preset.id), [
      'anterior-0',
      'anterior-1',
    ]);
    await open().read(timerPresetsProvider.notifier).rename('anterior-1', 'B');
    final saved =
        jsonDecode(prefs.getString(SharedPreferenceConstants.timerPresets)!)
            as List<Object?>;
    expect(saved.map((item) => (item as Map)['id']), [
      'anterior-0',
      'anterior-1',
    ]);
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
