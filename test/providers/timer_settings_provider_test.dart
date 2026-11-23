import 'dart:convert';

import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/timer/timer_settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
