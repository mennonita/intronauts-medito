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
  });

  final bool mixWithOthers;
  final bool keepScreenOn;

  TimerPreferences copyWith({bool? mixWithOthers, bool? keepScreenOn}) =>
      TimerPreferences(
        mixWithOthers: mixWithOthers ?? this.mixWithOthers,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      );

  static TimerPreferences read(SharedPreferences prefs) => TimerPreferences(
    mixWithOthers:
        prefs.getBool(SharedPreferenceConstants.timerMixWithOthers) ?? false,
    keepScreenOn:
        prefs.getBool(SharedPreferenceConstants.timerKeepScreenOn) ?? false,
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
}
