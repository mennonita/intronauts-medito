import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/stats_provider.dart';

/// Guarda la hora local en que empieza el día de práctica.
class DayBoundaryOffsetNotifier extends AsyncNotifier<int> {
  @override
  int build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getInt(SharedPreferenceConstants.dayBoundaryOffsetHours) ?? 0;
  }

  Future<void> setOffsetHours(int hours) async {
    final manager = ref.read(statsManagerProvider);
    await manager.initialize();
    await manager.setDayBoundaryOffset(Duration(hours: hours));
    state = AsyncValue.data(hours);
    // Actualiza el calendario y el contador con el nuevo inicio del día.
    await ref.read(statsProvider.notifier).refreshFromLocal();
  }
}

final dayBoundaryOffsetProvider =
    AsyncNotifierProvider<DayBoundaryOffsetNotifier, int>(
      DayBoundaryOffsetNotifier.new,
    );
