import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/timer/last_timer_store.dart';
import 'package:medito/services/timer/timer_device_channel.dart';
import 'package:medito/services/timer/timer_shortcuts_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const channel = MethodChannel('intronauts/timer_device');
  const root = 'org.meditofoundation://medito/timer/start';
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TimerDeviceChannel.debugIsAndroid = true;
    binding.platformDispatcher.localesTestValue = [const Locale('es', 'MX')];
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    binding.platformDispatcher.clearLocalesTestValue();
    debugDefaultTargetPlatformOverride = null;
    TimerDeviceChannel.debugIsAndroid = null;
  });

  final durationShortcuts = [
    for (final minutes in [5, 10, 20])
      {
        'id': 'timer_$minutes',
        'shortLabel': 'Temporizador de $minutes min',
        'longLabel': 'Temporizador de $minutes min',
        'uri': '$root?minutes=$minutes',
      },
  ];

  test('publica los tres atajos de duración sin una sesión anterior', () async {
    await TimerShortcutsService.refresh();

    expect(calls.single.method, 'setShortcuts');
    expect(calls.single.arguments, {'shortcuts': durationShortcuts});
  });

  test('agrega Repetir si hay una sesión anterior guardada', () async {
    const snapshot = LastTimerSnapshot(settings: {'minutes': 8}, savedAtMs: 1);
    SharedPreferences.setMockInitialValues({
      SharedPreferenceConstants.timerLastSettings: jsonEncode(
        snapshot.toJson(),
      ),
    });

    await TimerShortcutsService.refresh();

    expect(calls.single.method, 'setShortcuts');
    expect(calls.single.arguments, {
      'shortcuts': [
        ...durationShortcuts,
        {
          'id': 'timer_last',
          'shortLabel': 'Repetir último temporizador',
          'longLabel': 'Repetir último temporizador',
          'uri': '$root?last=1',
        },
      ],
    });
  });

  test('ignora una sesión guardada inválida', () async {
    SharedPreferences.setMockInitialValues({
      SharedPreferenceConstants.timerLastSettings: '{',
    });

    await TimerShortcutsService.refresh();

    expect(calls.single.arguments, {'shortcuts': durationShortcuts});
  });

  test('no llama al canal fuera de Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    await TimerShortcutsService.refresh();

    expect(calls, isEmpty);
  });

  test('termina aunque falle el registro de atajos', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'TIMER_DEVICE');
    });

    await expectLater(TimerShortcutsService.refresh(), completes);
  });
}
