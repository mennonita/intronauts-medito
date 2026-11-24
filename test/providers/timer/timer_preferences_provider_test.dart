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

  test('las preferencias empiezan desactivadas', () {
    final state = newContainer().read(timerPreferencesProvider);
    expect(state.mixWithOthers, isFalse);
    expect(state.keepScreenOn, isFalse);
    expect(state.openOnTimer, isFalse);
    expect(state.skipEndScreen, isFalse);
  });

  test(
    'abrir el temporizador y saltar el final se guardan por separado',
    () async {
      final container = newContainer();
      final notifier = container.read(timerPreferencesProvider.notifier);
      await notifier.setOpenOnTimer(true);
      expect(container.read(timerPreferencesProvider).openOnTimer, isTrue);
      expect(container.read(timerPreferencesProvider).skipEndScreen, isFalse);
      expect(prefs.getBool('timer_open_on_timer'), isTrue);

      await notifier.setSkipEndScreen(true);
      final restored = TimerPreferences.read(prefs);
      expect(restored.openOnTimer, isTrue);
      expect(restored.skipEndScreen, isTrue);
      expect(prefs.getBool('timer_skip_end_screen'), isTrue);

      await notifier.setOpenOnTimer(false);
      expect(TimerPreferences.read(prefs).openOnTimer, isFalse);
      expect(
        newContainer().read(timerPreferencesProvider).skipEndScreen,
        isTrue,
      );
      await notifier.setSkipEndScreen(false);
      expect(TimerPreferences.read(prefs).skipEndScreen, isFalse);
    },
  );

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
