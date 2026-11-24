import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/timer/timer_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ProviderContainer newContainer() {
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('las dos preferencias empiezan desactivadas', () {
    final state = newContainer().read(timerPreferencesProvider);
    expect(state.mixWithOthers, isFalse);
    expect(state.keepScreenOn, isFalse);
  });

  test('los cambios actualizan el estado y se conservan al volver', () async {
    final container = newContainer();
    final notifier = container.read(timerPreferencesProvider.notifier);
    await notifier.setMixWithOthers(true);
    expect(container.read(timerPreferencesProvider).mixWithOthers, isTrue);
    expect(container.read(timerPreferencesProvider).keepScreenOn, isFalse);

    await notifier.setKeepScreenOn(true);
    expect(prefs.getBool(SharedPreferenceConstants.timerMixWithOthers), isTrue);
    expect(prefs.getBool(SharedPreferenceConstants.timerKeepScreenOn), isTrue);
    final restored = newContainer().read(timerPreferencesProvider);
    expect(restored.mixWithOthers, isTrue);
    expect(restored.keepScreenOn, isTrue);

    await notifier.setMixWithOthers(false);
    await notifier.setKeepScreenOn(false);
    expect(
      prefs.getBool(SharedPreferenceConstants.timerMixWithOthers),
      isFalse,
    );
    expect(prefs.getBool(SharedPreferenceConstants.timerKeepScreenOn), isFalse);
  });

  test('lee las preferencias sin usar el proveedor de estado', () async {
    await prefs.setBool(SharedPreferenceConstants.timerKeepScreenOn, true);
    final state = TimerPreferences.read(prefs);
    expect(state.mixWithOthers, isFalse);
    expect(state.keepScreenOn, isTrue);
  });
}
