import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/timer/timer_background.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/utils/logger.dart';

final timerBackgroundProvider =
    NotifierProvider<TimerBackgroundNotifier, TimerBackground>(
      TimerBackgroundNotifier.new,
    );

class TimerBackgroundNotifier extends Notifier<TimerBackground> {
  static const _key = SharedPreferenceConstants.timerBackground;
  Future<bool> _lastWrite = Future.value(true);

  @override
  TimerBackground build() {
    final value = ref.watch(sharedPreferencesProvider).get(_key);
    return value is String
        ? TimerBackground.parse(value)
        : TimerBackground.defaultValue;
  }

  Future<bool> set(TimerBackground background) {
    final write = _lastWrite.then((_) async {
      if (!ref.mounted) return false;
      final prefs = ref.read(sharedPreferencesProvider);
      try {
        if (await prefs.setString(_key, background.serialize())) {
          if (ref.mounted) state = background;
          return true;
        }
      } catch (error, stack) {
        AppLogger.e('TIMER', 'No se pudo guardar el fondo', error, stack);
      }
      try {
        // Las preferencias cambian en caché antes de confirmar el guardado.
        await prefs.reload();
      } catch (error, stack) {
        AppLogger.e('TIMER', 'No se pudo recargar el fondo', error, stack);
      }
      return false;
    });
    _lastWrite = write;
    return write;
  }
}
