import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/providers/day_boundary_offset_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/utils/practice_history.dart';

final practiceHistoryProvider = Provider<AsyncValue<PracticeHistory>>((ref) {
  final stats = ref.watch(statsProvider);
  final prefs = ref.watch(sharedPreferencesProvider);
  final manager = ref.watch(statsManagerProvider);
  final offset = ref.watch(dayBoundaryOffsetProvider).value;
  return stats.whenData(
    (stats) => PracticeHistory.read(
      stats,
      prefs: prefs,
      now: manager.currentDate,
      offset: offset == null
          ? manager.dayBoundaryOffset
          : Duration(hours: offset),
    ),
  );
});

int? returnPauseDays(
  WidgetRef ref,
  PracticeHistory history,
  LocalAllStats? priorStats,
) {
  if (priorStats == null) return null;
  final manager = ref.read(statsManagerProvider);
  final offset = ref.read(dayBoundaryOffsetProvider).value;
  final prior = PracticeHistory.read(
    priorStats,
    prefs: ref.read(sharedPreferencesProvider),
    now: manager.currentDate,
    offset: offset == null
        ? manager.dayBoundaryOffset
        : Duration(hours: offset),
    remember: false,
  );
  final newDays = history.days.difference(prior.days);
  if (newDays.isEmpty) return null;

  final completedDay = newDays.reduce((a, b) => a.isAfter(b) ? a : b);
  return prior.pauseDaysBefore(completedDay);
}
