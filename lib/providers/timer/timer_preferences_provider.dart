import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class TimerPreferences {
  const TimerPreferences({
    this.mixWithOthers = false,
    this.keepScreenOn = false,
    this.openOnTimer = false,
    this.skipEndScreen = false,
  });

  final bool mixWithOthers;
  final bool keepScreenOn;
  final bool openOnTimer;
  final bool skipEndScreen;

  TimerPreferences copyWith({
    bool? mixWithOthers,
    bool? keepScreenOn,
    bool? openOnTimer,
    bool? skipEndScreen,
  }) => TimerPreferences(
    mixWithOthers: mixWithOthers ?? this.mixWithOthers,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    openOnTimer: openOnTimer ?? this.openOnTimer,
    skipEndScreen: skipEndScreen ?? this.skipEndScreen,
  );

  static TimerPreferences read(SharedPreferences prefs) => TimerPreferences(
    mixWithOthers:
        prefs.getBool(SharedPreferenceConstants.timerMixWithOthers) ?? false,
    keepScreenOn:
        prefs.getBool(SharedPreferenceConstants.timerKeepScreenOn) ?? false,
    openOnTimer:
        prefs.getBool(SharedPreferenceConstants.timerOpenOnTimer) ?? false,
    skipEndScreen:
        prefs.getBool(SharedPreferenceConstants.timerSkipEndScreen) ?? false,
  );
}

final timerPreferencesProvider =
    NotifierProvider<TimerPreferencesNotifier, TimerPreferences>(
      TimerPreferencesNotifier.new,
    );

class TimerPreferencesNotifier extends Notifier<TimerPreferences> {
  @override
  TimerPreferences build() =>
      TimerPreferences.read(ref.watch(sharedPreferencesProvider));

  Future<void> setMixWithOthers(bool enabled) async {
    state = state.copyWith(mixWithOthers: enabled);
    await ref
        .read(sharedPreferencesProvider)
        .setBool(SharedPreferenceConstants.timerMixWithOthers, enabled);
  }

  Future<void> setKeepScreenOn(bool enabled) async {
    state = state.copyWith(keepScreenOn: enabled);
    await ref
        .read(sharedPreferencesProvider)
        .setBool(SharedPreferenceConstants.timerKeepScreenOn, enabled);
  }

  Future<void> setOpenOnTimer(bool enabled) async {
    state = state.copyWith(openOnTimer: enabled);
    await ref
        .read(sharedPreferencesProvider)
        .setBool(SharedPreferenceConstants.timerOpenOnTimer, enabled);
  }

  Future<void> setSkipEndScreen(bool enabled) async {
    state = state.copyWith(skipEndScreen: enabled);
    await ref
        .read(sharedPreferencesProvider)
        .setBool(SharedPreferenceConstants.timerSkipEndScreen, enabled);
  }
}
