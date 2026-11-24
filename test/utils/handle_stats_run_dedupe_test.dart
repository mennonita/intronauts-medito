import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/services/stats_service.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:medito/utils/stats_updater.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Service extends Mock implements StatsService {}

/// Preferencias reales con escrituras que pueden fallar o esperar.
class _Prefs extends Fake implements SharedPreferences {
  _Prefs(this.real);

  final SharedPreferences real;
  bool failStats = false;
  // Como SharedPreferences: la caché cambia aunque el disco falle.
  bool cacheThenFail = false;
  Completer<void>? gate;
  final statsWrites = <String>[];

  @override
  Future<bool> setString(String key, String value) async {
    if (key == SharedPreferenceConstants.localAllStatsKey ||
        key == 'stats_pending_owner') {
      if (failStats) return false;
      if (cacheThenFail) {
        await real.setString(key, value);
        return false;
      }
      final waiting = gate;
      if (waiting != null) await waiting.future;
      if (key == SharedPreferenceConstants.localAllStatsKey) {
        statsWrites.add(value);
      }
    }
    return real.setString(key, value);
  }

  @override
  String? getString(String key) => real.getString(key);
  @override
  int? getInt(String key) => real.getInt(key);
  @override
  bool? getBool(String key) => real.getBool(key);
  @override
  double? getDouble(String key) => real.getDouble(key);
  @override
  List<String>? getStringList(String key) => real.getStringList(key);
  @override
  Object? get(String key) => real.get(key);
  @override
  Set<String> getKeys() => real.getKeys();
  @override
  bool containsKey(String key) => real.containsKey(key);
  @override
  Future<bool> setInt(String key, int value) => real.setInt(key, value);
  @override
  Future<bool> setBool(String key, bool value) => real.setBool(key, value);
  @override
  Future<bool> setDouble(String key, double value) =>
      real.setDouble(key, value);
  @override
  Future<bool> setStringList(String key, List<String> value) =>
      real.setStringList(key, value);
  @override
  Future<bool> remove(String key) => real.remove(key);
}

const _account = '00000000-0000-4000-8000-000000000001';
const _other = '00000000-0000-4000-8000-000000000002';

Map<String, dynamic> _run(
  String runId, {
  String ownerId = _account,
  int minutes = 10,
  int? timestamp,
}) => {
  TypeConstants.trackIdKey: 'timer-${minutes * 60}',
  TypeConstants.durationIdKey: minutes * 60000,
  TypeConstants.fileIdKey: 'timer-countdown-${minutes * 60000}',
  TypeConstants.guideIdKey: '',
  TypeConstants.timestampIdKey:
      timestamp ?? DateTime(2026, 11, 24, 10).millisecondsSinceEpoch,
  TypeConstants.runIdKey: runId,
  timerOwnerIdKey: ownerId,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final stats = StatsManager();
  late _Service service;
  late _Prefs prefs;

  Future<void> open({bool verified = true}) async {
    stats.resetForTesting();
    await stats.initializeForTesting(
      statsService: service,
      requireVerifiedUser: !verified,
    );
    prefs = _Prefs(await SharedPreferences.getInstance());
    stats.setPrefsForTesting(prefs);
  }

  Map<String, dynamic> record() =>
      jsonDecode(
            prefs.real.getString(SharedPreferenceConstants.localAllStatsKey)!,
          )
          as Map<String, dynamic>;

  setUpAll(() => registerFallbackValue(LocalAllStats.empty()));

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      SharedPreferenceConstants.isLoggedIn: true,
    });
    service = _Service();
    when(() => service.fetchAllStats()).thenAnswer((_) async => null);
    when(
      () => service.postStats(any(), clientSeq: any(named: 'clientSeq')),
    ).thenAnswer(
      (call) async =>
          (applied: true, clientSeq: call.namedArguments[#clientSeq] as int),
    );
    await open();
  });

  tearDown(stats.resetForTesting);

  test('el mismo runId dos veces es duplicado, también al recargar', () async {
    expect(await stats.recordTimerRun(_run('a')), TimerRecordResult.accepted);
    expect(await stats.recordTimerRun(_run('a')), TimerRecordResult.duplicate);
    expect(stats.currentStats!.audioCompleted, hasLength(1));

    await open();
    expect(await stats.recordTimerRun(_run('a')), TimerRecordResult.duplicate);
    expect(stats.currentStats!.audioCompleted, hasLength(1));
    expect(await handleStats(_run('a')), isTrue);
    expect((await stats.localAllStats).audioCompleted, hasLength(1));
  });

  test('sin verificar, la sesión sin dueño va al historial activo', () async {
    await open(verified: false);
    expect(stats.verifiedUserId, isNull);
    expect(
      await stats.recordTimerRun(_run('a', ownerId: '')),
      TimerRecordResult.accepted,
    );
    expect(stats.currentStats!.audioCompleted, hasLength(1));
    expect(stats.healthPendingRuns(), isEmpty);
    expect(await stats.preVerificationSummary(), isNull);
  });

  test(
    'una sesión sin dueño entregada después de verificar va al historial previo',
    () async {
      String? active() =>
          prefs.real.getString(SharedPreferenceConstants.localAllStatsKey);
      final before = active();
      expect(
        await stats.recordTimerRun(_run('a', ownerId: '', minutes: 12)),
        TimerRecordResult.accepted,
      );
      expect(active(), before);
      expect(stats.currentStats?.audioCompleted ?? const [], isEmpty);
      final summary = await stats.preVerificationSummary();
      expect(summary?.sessions, 1);
      expect(summary?.minutes, 12);
      expect(
        await stats.recordTimerRun(_run('a', ownerId: '')),
        TimerRecordResult.duplicate,
      );
      expect((await stats.preVerificationSummary())?.sessions, 1);
    },
  );

  test('otra cuenta verificada se rechaza sin escribir nada', () async {
    final writes = prefs.statsWrites.length;
    final raw = prefs.real.getString(
      SharedPreferenceConstants.localAllStatsKey,
    );
    expect(
      await stats.recordTimerRun(_run('a', ownerId: _other)),
      TimerRecordResult.rejected,
    );
    expect(prefs.statsWrites, hasLength(writes));
    expect(
      prefs.real.getString(SharedPreferenceConstants.localAllStatsKey),
      raw,
    );
    expect(await handleStats(_run('b', ownerId: _other)), isTrue);
  });

  test(
    'la marca de Salud viaja en la misma escritura y se puede quitar',
    () async {
      final end = DateTime(2026, 11, 24, 10).millisecondsSinceEpoch;
      expect(
        await stats.recordTimerRun(_run('a', timestamp: end)),
        TimerRecordResult.accepted,
      );
      final first = jsonDecode(prefs.statsWrites.first) as Map;
      expect(first['audioCompleted'], hasLength(1));
      expect(first['recorded_runs'], [
        {
          'runId': 'a',
          'healthPending': {
            'startMs': end - 600000,
            'endMs': end,
            'accountId': _account,
          },
        },
      ]);
      final pending = stats.healthPendingRuns().single;
      expect(pending.runId, 'a');
      expect(pending.accountId, _account);

      expect(await stats.clearHealthPending('a'), isTrue);
      expect(stats.healthPendingRuns(), isEmpty);
      await open();
      expect(stats.healthPendingRuns(), isEmpty);
      expect(
        await stats.recordTimerRun(_run('a')),
        TimerRecordResult.duplicate,
      );
    },
  );

  test(
    'si la escritura falla, la memoria no cambia y se pide reintentar',
    () async {
      await stats.localAllStats;
      final before = stats.currentStats;
      prefs.failStats = true;
      expect(await stats.recordTimerRun(_run('a')), TimerRecordResult.failed);
      expect(identical(stats.currentStats, before), isTrue);
      expect(stats.healthPendingRuns(), isEmpty);
      expect(await handleStats(_run('a')), isFalse);

      prefs.failStats = false;
      expect(await handleStats(_run('a')), isTrue);
      expect(stats.currentStats!.audioCompleted, hasLength(1));
    },
  );

  test('tres escrituras a la vez quedan las tres', () async {
    prefs.gate = Completer<void>();
    final writes = [
      stats.recordTimerRun(_run('a', minutes: 5)),
      stats.addAudioCompleted(
        LocalAudioCompleted(
          id: 'guided',
          timestamp: DateTime(2026, 11, 24, 11).millisecondsSinceEpoch,
        ),
        300000,
      ),
      stats.recordTimerRun(_run('b', minutes: 7)),
    ];
    await pumpEventQueue();
    prefs.gate!.complete();
    prefs.gate = null;
    await Future.wait(writes);
    final ids = record()['audioCompleted'] as List;
    expect(ids, hasLength(3));
    expect((record()['recorded_runs'] as List).map((run) => run['runId']), [
      'a',
      'b',
    ]);
  });

  test(
    'aceptar la cuenta durante una escritura pendiente no la pierde',
    () async {
      await open(verified: false);
      prefs.gate = Completer<void>();
      final writing = stats.recordTimerRun(_run('a', ownerId: ''));
      await pumpEventQueue();
      final accepting = stats.acceptServerUser(_account);
      await pumpEventQueue();
      prefs.gate!.complete();
      prefs.gate = null;
      expect(await writing, TimerRecordResult.accepted);
      await accepting;
      expect(stats.verifiedUserId, _account);
      expect((await stats.preVerificationSummary())?.sessions, 1);
    },
  );

  test(
    'un guardado previo que falló no se confirma después como duplicado',
    () async {
      prefs.cacheThenFail = true;
      expect(
        await stats.recordTimerRun(_run('a', ownerId: '')),
        TimerRecordResult.failed,
      );
      prefs.cacheThenFail = false;
      expect(
        await stats.recordTimerRun(_run('a', ownerId: '')),
        TimerRecordResult.accepted,
      );
      expect((await stats.preVerificationSummary())?.sessions, 1);
    },
  );

  test('hay un solo historial sin dueño aunque hubiera varios', () async {
    LocalAllStats withSession(String id, int ms) =>
        LocalAllStats.empty().copyWith(
          audioCompleted: [LocalAudioCompleted(id: id, timestamp: ms)],
          totalTimeListened: 300000,
          totalTracksCompleted: 1,
        );
    Map<String, dynamic> ownerless(String id, int ms, String runId) => {
      'user_id': null,
      'stats': withSession(id, ms).toJson(),
      'recorded_runs': [
        {'runId': runId},
      ],
    };
    await prefs.real.setString(
      'stats_pending_owner',
      jsonEncode({
        ...ownerless('s1', 1000, 'r1'),
        'other_owners': [ownerless('s2', 2000, 'r2')],
      }),
    );
    await open();
    final summary = await stats.preVerificationSummary();
    expect(summary?.sessions, 2);
    expect(summary?.minutes, 10);
    // El duplicado se busca en todo el historial sin dueño.
    expect(
      await stats.recordTimerRun(_run('r1', ownerId: '')),
      TimerRecordResult.duplicate,
    );
    expect(
      await stats.recordTimerRun(_run('r3', ownerId: '')),
      TimerRecordResult.accepted,
    );
    final raw =
        jsonDecode(prefs.real.getString('stats_pending_owner')!)
            as Map<String, dynamic>;
    expect(raw['other_owners'], isEmpty);
    expect((await stats.preVerificationSummary())?.sessions, 3);
  });

  test('el límite de 200 nunca quita una marca de Salud pendiente', () async {
    final start = DateTime(2026, 11, 1).millisecondsSinceEpoch;
    expect(
      await stats.recordTimerRun(_run('salud', timestamp: start)),
      TimerRecordResult.accepted,
    );
    for (var i = 0; i < 200; i++) {
      await stats.recordTimerRun(_run('r$i', timestamp: start + i + 1));
      expect(await stats.clearHealthPending('r$i'), isTrue);
    }
    final runs = (record()['recorded_runs'] as List)
        .map((run) => run['runId'])
        .toList();
    expect(runs, hasLength(200));
    expect(runs.first, 'salud');
    expect(runs, isNot(contains('r0')));
    expect(stats.healthPendingRuns().single.runId, 'salud');
  });
}
