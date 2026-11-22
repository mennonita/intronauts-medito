import 'package:flutter/services.dart';
import 'package:medito/services/review_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/utils/practice_history.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

LocalAudioCompleted session(DateTime at, [String id = 'track']) =>
    LocalAudioCompleted(id: id, timestamp: at.millisecondsSinceEpoch);

LocalAllStats statsWith(List<LocalAudioCompleted> sessions) =>
    LocalAllStats.empty().copyWith(audioCompleted: sessions);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = StatsManager();
  final now = DateTime(2026, 11, 21, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    manager.resetForTesting();
    await manager.initializeForTesting();
    manager.setCurrentDateForTesting(now);
  });

  test(
    'counts distinct days with tracks, a timer or manual sessions',
    () async {
      manager.setStatsForTesting(
        statsWith([
          session(DateTime(2026, 10, 1, 7)),
          session(DateTime(2026, 10, 1, 19)),
          session(DateTime(2026, 11, 12, 15), 'timer_300000'),
          session(DateTime(2026, 11, 18, 12), TypeConstants.manual2),
          session(DateTime(2026, 11, 19, 12), TypeConstants.streakFreeze),
          session(DateTime(2026, 11, 20, 12), 'dummy-track-1'),
        ]).copyWith(
          freezeUsageDates: [DateTime(2026, 11, 17, 12).millisecondsSinceEpoch],
        ),
      );

      expect(await manager.returns, 3);
    },
  );

  test('groups sessions by the chosen day boundary', () async {
    manager.setDayBoundaryOffsetForTesting(const Duration(hours: 4));
    manager.setStatsForTesting(
      statsWith([
        session(DateTime(2026, 11, 20, 23)),
        session(DateTime(2026, 11, 21, 2)),
      ]),
    );

    expect(await manager.returns, 1);
  });

  test('uses completion time for a new session across midnight', () async {
    final completed = session(DateTime(2026, 11, 21, 0, 3));
    await manager.addAudioCompleted(completed, 600000, skipPost: true);
    final stats = await manager.localAllStats;

    expect(
      stats.audioCompleted!.single.timestamp,
      completed.timestamp - 600000,
    );
    final history = PracticeHistory.read(
      stats,
      prefs: await SharedPreferences.getInstance(),
      now: now,
      offset: Duration.zero,
    );
    expect(history.days, {DateTime(2026, 11, 21)});
  });

  test(
    'never loses returns across pauses, deletions or a new day boundary',
    () async {
      final first = session(DateTime(2026, 11, 18, 23));
      final second = session(DateTime(2026, 11, 19, 2));
      manager.setStatsForTesting(statsWith([first, second]));
      expect(await manager.returns, 2);

      manager.setCurrentDateForTesting(DateTime(2026, 12, 20, 12));
      await manager.removeAudioCompleted(second);
      manager.setDayBoundaryOffsetForTesting(const Duration(hours: 4));
      manager.resetForTesting();
      await manager.initializeForTesting();
      manager.setCurrentDateForTesting(DateTime(2026, 12, 20, 12));
      manager.setDayBoundaryOffsetForTesting(const Duration(hours: 4));
      expect(await manager.returns, 2);

      await manager.addAudioCompleted(first, 0, skipPost: true);
      expect(await manager.returns, 2);
      await manager.addAudioCompleted(
        session(DateTime(2026, 12, 20, 7)),
        0,
        skipPost: true,
      );
      expect(await manager.returns, 3);
    },
  );

  test('counts the last seven logical practice days, including today', () {
    final history = PracticeHistory.read(
      statsWith([
        session(DateTime(2026, 11, 14, 23)),
        session(DateTime(2026, 11, 15, 23)),
        session(DateTime(2026, 11, 16, 2)),
        session(DateTime(2026, 11, 20, 12), TypeConstants.streakFreeze),
        session(DateTime(2026, 11, 21, 7)),
      ]),
      now: now,
      offset: const Duration(hours: 4),
    );

    expect(history.daysThisWeek, 2);
  });

  test('requests a review at ten nonconsecutive returns', () async {
    const channel = MethodChannel('dev.britannio.in_app_review');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'isAvailable' ? true : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final review = ReviewService(statsManager: manager);

    final sessions = List.generate(
      10,
      (index) => session(DateTime(2026, 11, 21 - index * 2, 12)),
    );
    manager.setStatsForTesting(statsWith(sessions.take(9).toList()));
    await review.checkAndRequestReview();
    expect(calls, isEmpty);

    manager.setStatsForTesting(statsWith(sessions));
    await review.checkAndRequestReview();
    expect(calls, ['isAvailable', 'requestReview']);
  });

  test('detects a gap of two calendar days and skips a gap of one', () {
    final completion = DateTime(2026, 11, 21, 3, 30);
    PracticeHistory priorHistory(List<LocalAudioCompleted> sessions) =>
        PracticeHistory.read(
          statsWith(sessions),
          now: completion,
          offset: const Duration(hours: 4),
        );

    expect(priorHistory([]).pauseDays, isNull);
    expect(
      priorHistory([session(DateTime(2026, 11, 20, 1))]).pauseDays,
      isNull,
    );
    expect(
      priorHistory([
        session(DateTime(2026, 11, 19, 2)),
        session(DateTime(2026, 11, 19, 19), TypeConstants.streakFreeze),
      ]).pauseDays,
      2,
    );
    expect(
      priorHistory([session(DateTime(2026, 11, 20, 17))]).pauseDays,
      isNull,
    );
  });
}
