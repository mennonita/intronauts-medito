import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/services/reminders/mindfulness_bells_service.dart';
import 'package:medito/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:medito/services/reminders/mindfulness_bells_service.dart'
    show MindfulnessBellsConfig;

final mindfulnessBellsServiceProvider = Provider<MindfulnessBellsService>(
  (ref) => MindfulnessBellsService(),
);

final mindfulnessBellsProvider =
    NotifierProvider<MindfulnessBellsNotifier, MindfulnessBellsConfig>(
      MindfulnessBellsNotifier.new,
    );

class MindfulnessBellsNotifier extends Notifier<MindfulnessBellsConfig> {
  Future<void> _pendingUpdate = Future<void>.value();

  @override
  MindfulnessBellsConfig build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    const defaults = MindfulnessBellsConfig();
    final startHour =
        (prefs.getInt(SharedPreferenceConstants.mindfulnessBellsStartHour) ??
                defaults.startHour)
            .clamp(5, 22);
    return MindfulnessBellsConfig(
      enabled:
          prefs.getBool(SharedPreferenceConstants.mindfulnessBellsEnabled) ??
          defaults.enabled,
      startHour: startHour,
      endHour:
          (prefs.getInt(SharedPreferenceConstants.mindfulnessBellsEndHour) ??
                  defaults.endHour)
              .clamp(startHour + 1, 23),
      everyHours:
          (prefs.getInt(SharedPreferenceConstants.mindfulnessBellsEveryHours) ??
                  defaults.everyHours)
              .clamp(1, 4),
    );
  }

  Future<void> setEnabled(bool enabled) =>
      _update((config) => config.copyWith(enabled: enabled));

  Future<void> setStartHour(int hour) => _update((config) {
    final start = hour.clamp(5, 22);
    return config.copyWith(
      startHour: start,
      endHour: config.endHour.clamp(start + 1, 23),
    );
  });

  Future<void> setEndHour(int hour) => _update(
    (config) => config.copyWith(endHour: hour.clamp(config.startHour + 1, 23)),
  );

  Future<void> setEveryHours(int hours) =>
      _update((config) => config.copyWith(everyHours: hours.clamp(1, 4)));

  Future<void> _update(
    MindfulnessBellsConfig Function(MindfulnessBellsConfig) change,
  ) {
    // Evita que dos cambios cancelen o agenden las mismas campanas a la vez.
    final update = _pendingUpdate.then((_) async {
      final previous = state;
      final next = change(previous);
      final prefs = ref.read(sharedPreferencesProvider);
      final service = ref.read(mindfulnessBellsServiceProvider);
      try {
        await service.apply(next);
        await _save(prefs, next);
      } catch (_) {
        try {
          await Future.wait([_save(prefs, previous), service.apply(previous)]);
        } catch (error, stack) {
          AppLogger.e(
            'MINDFULNESS_BELLS',
            'No se pudo restaurar el horario',
            error,
            stack,
          );
        }
        rethrow;
      }
      state = next;
    });
    _pendingUpdate = update.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return update;
  }

  Future<void> _save(
    SharedPreferences prefs,
    MindfulnessBellsConfig config,
  ) async {
    final results = await Future.wait([
      prefs.setBool(
        SharedPreferenceConstants.mindfulnessBellsEnabled,
        config.enabled,
      ),
      prefs.setInt(
        SharedPreferenceConstants.mindfulnessBellsStartHour,
        config.startHour,
      ),
      prefs.setInt(
        SharedPreferenceConstants.mindfulnessBellsEndHour,
        config.endHour,
      ),
      prefs.setInt(
        SharedPreferenceConstants.mindfulnessBellsEveryHours,
        config.everyHours,
      ),
    ]);
    if (results.contains(false)) {
      throw StateError('Could not save mindfulness bell preferences');
    }
  }
}
