import 'dart:convert';

import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/models/timer/timer_preset.dart';
import 'package:medito/models/timer/timer_session.dart';
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
      final ids = <String>{};
      for (final item in presets) {
        try {
          var preset = TimerPreset.fromJson(item as Map<String, Object?>);
          // Sin id o repetido (datos anteriores): uno fijo por posición, que
          // no cambia al volver a leer y queda guardado en la próxima escritura.
          if (preset.id.isEmpty || ids.contains(preset.id)) {
            preset = preset.copyWith(id: 'anterior-${result.length}');
          }
          ids.add(preset.id);
          result.add(preset);
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
        TimerPreset(
          id: newTimerRunId(),
          name: trimmed,
          settings: settings,
          sound: sound,
        ),
      ];
    });
  }

  /// Reemplaza el temporizador con ese [id]; si ya no existe o el nuevo es
  /// inválido no cambia nada. Conserva el id.
  Future<bool> update(String id, TimerPreset preset) {
    final trimmed = preset.name.trim();
    return _change((presets) {
      final index = _indexOf(presets, id);
      if (index < 0 ||
          !TimerPreset.isValidName(trimmed) ||
          !preset.settings.canStart) {
        return presets;
      }
      return [...presets]
        ..[index] = preset.copyWith(id: presets[index].id, name: trimmed);
    });
  }

  /// Cambia el nombre; se recorta al máximo y un nombre vacío no cambia nada.
  Future<bool> rename(String id, String name) {
    final trimmed = name
        .trim()
        .characters
        .take(kMaxTimerPresetNameLength)
        .toString()
        .trim();
    return _change((presets) {
      final index = _indexOf(presets, id);
      if (index < 0 || trimmed.isEmpty || presets[index].name == trimmed) {
        return presets;
      }
      return [...presets]..[index] = presets[index].copyWith(name: trimmed);
    });
  }

  /// Mueve el temporizador con ese [id] para que quede en la posición [to]
  /// de la lista vigente cuando se aplica.
  Future<bool> move(String id, int to) => _change((presets) {
    final from = _indexOf(presets, id);
    if (from < 0 || to < 0 || to >= presets.length || from == to) {
      return presets;
    }
    final moved = [...presets];
    moved.insert(to, moved.removeAt(from));
    return moved;
  });

  Future<bool> delete(TimerPreset preset) => _change((presets) {
    final index = _indexOf(presets, preset.id);
    if (index < 0) return presets;
    return [...presets]..removeAt(index);
  });

  static int _indexOf(List<TimerPreset> presets, String id) =>
      id.isEmpty ? -1 : presets.indexWhere((preset) => preset.id == id);

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
