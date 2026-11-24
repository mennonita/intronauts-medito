import 'dart:async';
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

/// Todos los ajustes del temporizador en una sola escritura, para que nunca
/// queden mezclados ajustes nuevos con anteriores. Las claves sueltas de
/// versiones anteriores solo se leen si esta no existe.
const kTimerSettingsSnapshotKey = 'timer_settings_snapshot';

class TimerSettingsNotifier extends Notifier<TimerSettings> {
  @override
  TimerSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final saved = _readSnapshot(prefs.getString(kTimerSettingsSnapshotKey));
    // Siempre se vuelve a abrir en cuenta regresiva.
    if (saved != null) return saved.copyWith(mode: TimerMode.countdown);

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
    var stages = const <TimerStage>[];
    try {
      final raw = prefs.getString(SharedPreferenceConstants.timerStages);
      if (raw != null) stages = timerStagesFromJson(jsonDecode(raw));
    } catch (error) {
      AppLogger.w('TIMER', 'Partes del temporizador inválidas: $error');
    }
    return TimerSettings(
      bells: bells,
      extraTime:
          prefs.getBool(SharedPreferenceConstants.timerExtraTime) ?? false,
      mode: TimerMode.countdown,
      minutes: (minutes ?? kDefaultTimerMinutes).clamp(0, kMaxTimerMinutes),
      prepSeconds: timerPrepSecondsFromJson(
        prefs.getInt(SharedPreferenceConstants.timerPrepSeconds),
      ),
      stages: stages,
    );
  }

  static TimerSettings? _readSnapshot(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      return TimerSettings.fromSnapshotJson(json, requireStart: false);
    } catch (error) {
      AppLogger.w('TIMER', 'Ajustes del temporizador inválidos: $error');
      return null;
    }
  }

  // La pantalla limita las opciones; aquí se admite todo el rango guardable
  // (las prácticas de la casa pueden traer, por ejemplo, 180 s).
  static int _validPrep(int seconds) => seconds.clamp(0, kMaxTimerPrepSeconds);

  static List<TimerStage> _validStages(List<TimerStage> stages) =>
      List.unmodifiable(stages.take(kMaxTimerStages).map((s) => s.clamped()));

  static TimerSettings _valid(TimerSettings settings) => settings.copyWith(
    minutes: settings.minutes.clamp(0, kMaxTimerMinutes),
    prepSeconds: _validPrep(settings.prepSeconds),
    stages: _validStages(settings.stages),
  );

  /// Guarda [settings] completos en una sola escritura. Se llama sin esperar
  /// nada antes, así la caché de preferencias queda al día en el acto y las
  /// escrituras salen en el orden de las llamadas.
  Future<bool> _write(TimerSettings settings) async {
    final prefs = ref.read(sharedPreferencesProvider);
    try {
      final saved = await prefs.setString(
        kTimerSettingsSnapshotKey,
        jsonEncode(settings.toSnapshotJson()),
      );
      if (saved) {
        // Solo indica que la duración ya se había elegido (analítica).
        await prefs.setInt(
          SharedPreferenceConstants.timerMinutes,
          settings.minutes,
        );
      }
      if (saved) return true;
    } catch (error, stack) {
      AppLogger.e('TIMER', 'No se pudieron guardar los ajustes', error, stack);
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
  }

  void setMode(TimerMode mode) {
    if (mode == state.mode) return;
    state = state.copyWith(mode: mode);
  }

  void setMinutes(int minutes) {
    final clamped = minutes.clamp(0, kMaxTimerMinutes);
    if (clamped == state.minutes) return;
    state = state.copyWith(minutes: clamped);
    unawaited(_write(state));
  }

  Future<void> setBells(TimerBellSettings bells) async {
    state = state.copyWith(bells: bells);
    await _write(state);
  }

  Future<void> setExtraTime(bool enabled) async {
    state = state.copyWith(extraTime: enabled);
    await _write(state);
  }

  Future<void> setPrepSeconds(int seconds) async {
    state = state.copyWith(prepSeconds: _validPrep(seconds));
    await _write(state);
  }

  Future<void> setStages(List<TimerStage> stages) async {
    state = state.copyWith(stages: _validStages(stages));
    await _write(state);
  }

  /// Aplica todos los ajustes de una vez (al cargar un temporizador guardado).
  /// Se publican en pantalla solo después de guardarse; devuelve false si la
  /// escritura falló y entonces nada cambia.
  Future<bool> apply(TimerSettings settings) async {
    final valid = _valid(settings);
    final saved = await _write(valid);
    if (saved && ref.mounted) state = valid;
    return saved;
  }
}
