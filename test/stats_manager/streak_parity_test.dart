// Verifica el cálculo histórico de rachas que conserva el contrato del servidor.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late StatsManager statsManager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    statsManager = StatsManager();
    await statsManager.initializeForTesting();
  });

  tearDown(() {
    statsManager.resetForTesting();
  });

  final fixtureFile = File('test/fixtures/streak_score_fixtures.json');
  final fixture =
      jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
  final referenceInstant = DateTime.parse(
    fixture['referenceInstant'] as String,
  );
  final cases = fixture['cases'] as List<dynamic>;

  DateTime atHourOffset(num offsetHours) {
    final fixtureTime = referenceInstant.add(
      Duration(
        milliseconds: (offsetHours * Duration.millisecondsPerHour).round(),
      ),
    );
    // The fixture describes calendar times. Use the same local clock for the
    // injected date and the persisted timestamps StatsManager reads as local.
    return DateTime(
      fixtureTime.year,
      fixtureTime.month,
      fixtureTime.day,
      fixtureTime.hour,
      fixtureTime.minute,
      fixtureTime.second,
      fixtureTime.millisecond,
      fixtureTime.microsecond,
    );
  }

  group('Streak parity fixture', () {
    for (final rawCase in cases) {
      final testCase = rawCase as Map<String, dynamic>;
      final name = testCase['name'] as String;
      final nowOffsetHours = testCase['nowOffsetHours'] as num;
      final meditationOffsets =
          (testCase['meditationOffsetHours'] as List<dynamic>).cast<num>();
      final freezeOffsets = (testCase['freezeOffsetHours'] as List<dynamic>)
          .cast<num>();
      final dayBoundaryOffsetHours = testCase['dayBoundaryOffsetHours'] as int;
      final expectedStreak = testCase['expectedStreak'] as int;

      test(name, () {
        final now = atHourOffset(nowOffsetHours);
        statsManager.setCurrentDateForTesting(now);
        statsManager.setDayBoundaryOffsetForTesting(
          Duration(hours: dayBoundaryOffsetHours),
        );

        final audioCompleted = meditationOffsets
            .map(
              (offset) => LocalAudioCompleted(
                id: 'audio-$offset',
                timestamp: atHourOffset(offset).millisecondsSinceEpoch,
              ),
            )
            .toList();

        final stats = LocalAllStats.empty().copyWith(
          audioCompleted: audioCompleted,
          freezeUsageDates: freezeOffsets
              .map((offset) => atHourOffset(offset).millisecondsSinceEpoch)
              .toList(),
        );

        final result = statsManager.calculateStreak(stats);

        expect(
          result.streakCurrent,
          expectedStreak,
          reason: 'fixture case "$name" expected streak $expectedStreak',
        );
      });
    }
  });
}
