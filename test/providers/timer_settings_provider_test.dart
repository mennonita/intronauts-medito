import 'dart:async';
import 'dart:convert';

import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/timer/timer_settings_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Preferences extends Mock implements SharedPreferences {}

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ProviderContainer newContainer() => ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );

  test('first visit opens on a 10 minute countdown', () {
    final container = newContainer();
    addTearDown(container.dispose);
    final settings = container.read(timerSettingsProvider);
    expect(settings.mode, TimerMode.countdown);
    expect(settings.minutes, kDefaultTimerMinutes);
    expect(settings.extraTime, isFalse);
    expect(settings.bells.toJson(), {
      'start': true,
      'end': true,
      'intervalMinutes': 0,
      'randomCount': 0,
      'startSound': 'actual',
      'endSound': 'actual',
      'intervalSound': 'actual',
      'randomSound': 'actual',
      'startRepeats': 1,
      'endRepeats': 1,
      'intervalRepeats': 1,
      'randomRepeats': 1,
      'output': 'sound',
      'spokenCues': false,
    });
  });

  test('remembers the length but always reopens on the countdown', () {
    final first = newContainer();
    final sub = first.listen(timerSettingsProvider, (_, _) {});
    first.read(timerSettingsProvider.notifier)
      ..setMinutes(20)
      ..setMode(TimerMode.stopwatch);
    expect(first.read(timerSettingsProvider).mode, TimerMode.stopwatch);
    sub.close();
    first.dispose();

    final next = newContainer();
    addTearDown(next.dispose);
    final settings = next.read(timerSettingsProvider);
    expect(settings.mode, TimerMode.countdown);
    expect(settings.minutes, 20);
  });

  test('lee preferencias antiguas con la campana actual', () async {
    const legacy = {
      'start': false,
      'end': true,
      'intervalMinutes': 3,
      'randomCount': 2,
    };
    await prefs.setString(
      SharedPreferenceConstants.timerBellSettings,
      jsonEncode(legacy),
    );
    final container = newContainer();
    addTearDown(container.dispose);
    expect(container.read(timerSettingsProvider).bells.toJson(), {
      ...legacy,
      'startSound': 'actual',
      'endSound': 'actual',
      'intervalSound': 'actual',
      'randomSound': 'actual',
      'startRepeats': 1,
      'endRepeats': 1,
      'intervalRepeats': 1,
      'randomRepeats': 1,
      'output': 'sound',
      'spokenCues': false,
    });
  });

  test('recuerda las campanas y el tiempo extra entre pantallas', () async {
    final first = newContainer();
    final settings = first.read(timerSettingsProvider);
    final notifier = first.read(timerSettingsProvider.notifier);
    final bells = settings.bells.copyWith(
      start: false,
      end: false,
      intervalMinutes: 15,
      randomCount: 6,
      startSound: 'diapason',
      endSound: 'campana_templo',
      intervalSound: 'kalimba',
      randomSound: 'flauta',
    );
    await notifier.setBells(bells);
    await notifier.setExtraTime(true);
    first.dispose();

    final next = newContainer();
    addTearDown(next.dispose);
    final restored = next.read(timerSettingsProvider);
    expect(restored.extraTime, isTrue);
    expect(restored.bells.toJson(), bells.toJson());
  });

  test('recuerda la preparación y las partes', () async {
    const stages = [
      TimerStage(kind: TimerStageKind.sit, minutes: 20, sound: 'diapason'),
      TimerStage(kind: TimerStageKind.walk, minutes: 10),
    ];
    final first = newContainer();
    expect(first.read(timerSettingsProvider).prepSeconds, 0);
    expect(first.read(timerSettingsProvider).stages, isEmpty);
    final notifier = first.read(timerSettingsProvider.notifier);
    await notifier.setPrepSeconds(30);
    await notifier.setStages(stages);
    first.dispose();

    final next = newContainer();
    addTearDown(next.dispose);
    final restored = next.read(timerSettingsProvider);
    expect(restored.prepSeconds, 30);
    expect(restored.stages, stages);
    expect(restored.isMultiStage, isTrue);
  });

  test(
    'admite toda la preparación guardable, hasta seis partes y repeticiones válidas',
    () async {
      final container = newContainer();
      addTearDown(container.dispose);
      final sub = container.listen(timerSettingsProvider, (_, _) {});
      addTearDown(sub.close);
      final notifier = container.read(timerSettingsProvider.notifier);
      await notifier.setPrepSeconds(180);
      expect(container.read(timerSettingsProvider).prepSeconds, 180);
      await notifier.setPrepSeconds(99999);
      expect(
        container.read(timerSettingsProvider).prepSeconds,
        kMaxTimerPrepSeconds,
      );
      await notifier.setPrepSeconds(180);
      await notifier.setStages([
        const TimerStage(kind: TimerStageKind.sit, minutes: 0, repeats: 0),
        for (var i = 1; i <= 8; i++)
          TimerStage(kind: TimerStageKind.sit, minutes: i, repeats: 7),
      ]);
      final stages = container.read(timerSettingsProvider).stages;
      expect(stages, hasLength(6));
      expect(stages.first.minutes, 1);
      expect(stages.first.repeats, 1);
      expect(stages.skip(1).map((stage) => stage.repeats), everyElement(3));
      expect(container.read(timerSettingsProvider).canStart, isTrue);

      final reopened = newContainer();
      addTearDown(reopened.dispose);
      expect(reopened.read(timerSettingsProvider).prepSeconds, 180);
      expect(reopened.read(timerSettingsProvider).stages, stages);
    },
  );

  test('lee las claves anteriores si no hay ajustes juntos', () async {
    await prefs.setInt(SharedPreferenceConstants.timerMinutes, 25);
    await prefs.setBool(SharedPreferenceConstants.timerExtraTime, true);
    await prefs.setInt(SharedPreferenceConstants.timerPrepSeconds, 180);
    await prefs.setString(
      SharedPreferenceConstants.timerStages,
      jsonEncode([
        const TimerStage(kind: TimerStageKind.sit, minutes: 5).toJson(),
        const TimerStage(kind: TimerStageKind.walk, minutes: 5).toJson(),
      ]),
    );
    final container = newContainer();
    addTearDown(container.dispose);
    final settings = container.read(timerSettingsProvider);
    expect(settings.minutes, 25);
    expect(settings.extraTime, isTrue);
    expect(settings.prepSeconds, 180);
    expect(settings.stages, hasLength(2));

    await prefs.setString(SharedPreferenceConstants.timerStages, '[roto');
    await prefs.setString(kTimerSettingsSnapshotKey, '{roto');
    final broken = newContainer();
    addTearDown(broken.dispose);
    expect(broken.read(timerSettingsProvider).stages, isEmpty);
    expect(broken.read(timerSettingsProvider).minutes, 25);
  });

  test('aplica y guarda todos los ajustes de un temporizador', () async {
    final first = newContainer();
    final sub = first.listen(timerSettingsProvider, (_, _) {});
    const settings = TimerSettings(
      mode: TimerMode.stopwatch,
      minutes: 33,
      extraTime: true,
      prepSeconds: 180,
      stages: [
        TimerStage(kind: TimerStageKind.sit, minutes: 5),
        TimerStage(kind: TimerStageKind.rest, minutes: 2),
      ],
      bells: TimerBellSettings(
        intervalMinutes: 5,
        output: TimerBellOutput.vibration,
        spokenCues: true,
      ),
    );
    expect(
      await first.read(timerSettingsProvider.notifier).apply(settings),
      isTrue,
    );
    expect(
      first.read(timerSettingsProvider).toSnapshotJson(),
      settings.toSnapshotJson(),
    );
    expect(prefs.getInt(SharedPreferenceConstants.timerMinutes), 33);
    sub.close();
    first.dispose();

    final next = newContainer();
    addTearDown(next.dispose);
    final restored = next.read(timerSettingsProvider);
    expect(
      restored.toSnapshotJson(),
      settings.copyWith(mode: TimerMode.countdown).toSnapshotJson(),
    );
  });

  test('aplicar publica los ajustes solo si se guardaron', () async {
    final store = _Preferences();
    when(() => store.getString(any())).thenReturn(null);
    when(() => store.getInt(any())).thenReturn(null);
    when(() => store.getBool(any())).thenReturn(null);
    when(store.reload).thenAnswer((_) async {});
    final pending = Completer<bool>();
    when(
      () => store.setString(kTimerSettingsSnapshotKey, any()),
    ).thenAnswer((_) => pending.future);
    when(() => store.setInt(any(), any())).thenAnswer((_) async => true);
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(timerSettingsProvider, (_, _) {});
    addTearDown(sub.close);
    const settings = TimerSettings(
      mode: TimerMode.countdown,
      minutes: 40,
      prepSeconds: 30,
    );
    final notifier = container.read(timerSettingsProvider.notifier);

    final apply = notifier.apply(settings);
    await pumpEventQueue();
    expect(container.read(timerSettingsProvider).minutes, kDefaultTimerMinutes);
    pending.complete(false);
    expect(await apply, isFalse);
    expect(container.read(timerSettingsProvider).minutes, kDefaultTimerMinutes);
    verify(store.reload).called(1);

    when(
      () => store.setString(kTimerSettingsSnapshotKey, any()),
    ).thenAnswer((_) async => true);
    expect(await notifier.apply(settings), isTrue);
    expect(container.read(timerSettingsProvider).minutes, 40);
    expect(container.read(timerSettingsProvider).prepSeconds, 30);
  });
}
