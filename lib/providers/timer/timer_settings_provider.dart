import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_settings.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';

export 'package:medito/models/timer/timer_settings.dart';

final timerSettingsProvider =
    NotifierProvider.autoDispose<TimerSettingsNotifier, TimerSettings>(
      TimerSettingsNotifier.new,
    );

class TimerSettingsNotifier extends Notifier<TimerSettings> {
  @override
  TimerSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final minutes = prefs.getInt(SharedPreferenceConstants.timerMinutes);
    var bells = const TimerBellSettings();
    try {
      final raw = prefs.getString(SharedPreferenceConstants.timerBellSettings);
      if (raw != null) {
        bells = TimerBellSettings.fromJson(
          jsonDecode(raw) as Map<String, Object?>,
        );
      }
    } catch (error) {
      AppLogger.w('TIMER', 'Ajustes de campanas inválidos: $error');
    }
    return TimerSettings(
      bells: bells,
      extraTime:
          prefs.getBool(SharedPreferenceConstants.timerExtraTime) ?? false,
      mode: TimerMode.countdown,
      minutes: (minutes ?? kDefaultTimerMinutes).clamp(0, kMaxTimerMinutes),
    );
  }

  void setMode(TimerMode mode) {
    if (mode == state.mode) return;
    state = state.copyWith(mode: mode);
  }

  void setMinutes(int minutes) {
    final clamped = minutes.clamp(0, kMaxTimerMinutes);
    if (clamped == state.minutes) return;
    state = state.copyWith(minutes: clamped);
    ref
        .read(sharedPreferencesProvider)
        .setInt(SharedPreferenceConstants.timerMinutes, clamped);
  }

  Future<void> setBells(TimerBellSettings bells) async {
    state = state.copyWith(bells: bells);
    await ref
        .read(sharedPreferencesProvider)
        .setString(
          SharedPreferenceConstants.timerBellSettings,
          jsonEncode(bells.toJson()),
        );
  }

  Future<void> setExtraTime(bool enabled) async {
    state = state.copyWith(extraTime: enabled);
    await ref
        .read(sharedPreferencesProvider)
        .setBool(SharedPreferenceConstants.timerExtraTime, enabled);
  }
}
