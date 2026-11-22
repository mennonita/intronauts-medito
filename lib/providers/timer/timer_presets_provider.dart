import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/models/timer/timer_preset.dart';
import 'package:medito/models/timer/timer_settings.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/utils/logger.dart';

final timerPresetsProvider =
    NotifierProvider<TimerPresetsNotifier, List<TimerPreset>>(
      TimerPresetsNotifier.new,
    );

class TimerPresetsNotifier extends Notifier<List<TimerPreset>> {
  Future<bool> _lastWrite = Future.value(true);

  @override
  List<TimerPreset> build() {
    try {
      final raw = ref
          .watch(sharedPreferencesProvider)
          .getString(SharedPreferenceConstants.timerPresets);
      if (raw == null) return const [];
      final presets = jsonDecode(raw) as List<Object?>;
      final result = <TimerPreset>[];
      for (final item in presets) {
        try {
          result.add(TimerPreset.fromJson(item as Map<String, Object?>));
          if (result.length == kMaxTimerPresets) break;
        } catch (error) {
          AppLogger.w('TIMER', 'Se descartó un temporizador guardado: $error');
        }
      }
      return List.unmodifiable(result);
    } catch (error) {
      AppLogger.w('TIMER', 'No se pudieron leer los temporizadores: $error');
      return const [];
    }
  }

  Future<bool> save(
    String name,
    TimerSettings settings,
    BackgroundSoundsModel? sound,
  ) {
    final trimmed = name.trim();
    return _change((presets) {
      if (!TimerPreset.isValidName(trimmed) ||
          !settings.canStart ||
          presets.length >= kMaxTimerPresets) {
        return presets;
      }
      return [
        ...presets,
        TimerPreset(name: trimmed, settings: settings, sound: sound),
      ];
    });
  }

  Future<bool> delete(TimerPreset preset) => _change(
    (presets) => presets.where((item) => !identical(item, preset)).toList(),
  );

  Future<bool> _change(List<TimerPreset> Function(List<TimerPreset>) change) {
    final write = _lastWrite.then((_) async {
      if (!ref.mounted) return false;
      final presets = change(state);
      if (identical(presets, state)) return true;
      final prefs = ref.read(sharedPreferencesProvider);
      try {
        final saved = await prefs.setString(
          SharedPreferenceConstants.timerPresets,
          jsonEncode(presets.map((item) => item.toJson()).toList()),
        );
        if (saved) {
          if (ref.mounted) state = List.unmodifiable(presets);
          return true;
        }
      } catch (error, stack) {
        AppLogger.e('TIMER', 'No se pudo guardar el cambio', error, stack);
      }
      try {
        // La caché de preferencias se actualiza antes de confirmar la escritura.
        await prefs.reload();
      } catch (error, stack) {
        AppLogger.e(
          'TIMER',
          'No se pudieron volver a leer las preferencias',
          error,
          stack,
        );
      }
      return false;
    });
    _lastWrite = write;
    return write;
  }
}
