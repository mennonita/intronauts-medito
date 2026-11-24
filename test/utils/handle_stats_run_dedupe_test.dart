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
  String? gateKey;
  // Falla después de esperar la compuerta: la escritura queda pendiente y
  // luego no se guarda.
  bool failAfterGate = false;
  // Decide por clave si esta escritura falla (simula que el proceso muere).
  bool Function(String key)? failWhen;
  void Function(String key)? onWrite;
  final statsWrites = <String>[];

  @override
  Future<bool> setString(String key, String value) async {
    onWrite?.call(key);
    if (failWhen?.call(key) ?? false) return false;
    if (key == SharedPreferenceConstants.localAllStatsKey ||
        key == 'stats_pending_owner') {
      if (failStats) return false;
      if (cacheThenFail) {
        await real.setString(key, value);
        return false;
      }
      if (gateKey == null || key == gateKey) {
        final waiting = gate;
        if (waiting != null) await waiting.future;
        if (failAfterGate) return false;
      }
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
    expect(await stats.healthPendingRuns(), isEmpty);
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
      final pending = (await stats.healthPendingRuns()).single;
      expect(pending.runId, 'a');
      expect(pending.accountId, _account);

      expect(await stats.clearHealthPending('a'), isTrue);
      expect(await stats.healthPendingRuns(), isEmpty);
      await open();
      expect(await stats.healthPendingRuns(), isEmpty);
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
      expect(await stats.healthPendingRuns(), isEmpty);
      expect(await handleStats(_run('a')), isFalse);

      prefs.failStats = false;
      expect(await handleStats(_run('a')), isTrue);
      expect(stats.currentStats!.audioCompleted, hasLength(1));
    },
  );

  group('el regreso se publica solo con la sesión guardada '
      '(TIMER-REVIEW-04)', () {
    Iterable<String> practiceKeys() => prefs.real.getKeys().where(
      (key) => key.startsWith('practice_history:'),
    );

    test('temporizador: si el guardado falla no queda el regreso', () async {
      await stats.localAllStats;
      prefs.failStats = true;

      expect(await stats.recordTimerRun(_run('a')), TimerRecordResult.failed);
      await pumpEventQueue();

      expect(practiceKeys(), isEmpty);

      prefs.failStats = false;
      expect(await stats.recordTimerRun(_run('a')), TimerRecordResult.accepted);
      await pumpEventQueue();
      expect(practiceKeys(), isNotEmpty);
      expect(await stats.returns, 1);
    });

    test('una lectura durante el guardado no ve la sesión y no deja un '
        'regreso huérfano (TMR-04)', () async {
      await stats.localAllStats;
      prefs.gate = Completer<void>();
      prefs.failAfterGate = true;

      final saving = stats.recordTimerRun(_run('a'));
      await pumpEventQueue();
      // El guardado sigue esperando: la memoria aún no tiene la sesión.
      expect(stats.currentStats?.audioCompleted ?? const [], isEmpty);
      expect(await stats.returns, 0);

      prefs.gate!.complete();
      expect(await saving, TimerRecordResult.failed);
      await pumpEventQueue();
      expect(practiceKeys(), isEmpty);
      expect(stats.currentStats?.audioCompleted ?? const [], isEmpty);
      expect(await stats.returns, 0);
    });

    test('guiada: una lectura durante el guardado no ve la sesión '
        '(TMR-04)', () async {
      await stats.localAllStats;
      prefs.gate = Completer<void>();
      prefs.failAfterGate = true;
      final session = LocalAudioCompleted(
        id: 'guiada',
        timestamp: DateTime(2026, 11, 24, 10).millisecondsSinceEpoch,
      );

      final saving = stats.addAudioCompleted(session, 600000, skipPost: true);
      await pumpEventQueue();
      expect(await stats.returns, 0);

      prefs.gate!.complete();
      await expectLater(saving, throwsA(isA<StateError>()));
      await pumpEventQueue();
      expect(practiceKeys(), isEmpty);
    });

    test('guiada: si el guardado falla no queda el regreso', () async {
      await stats.localAllStats;
      prefs.failStats = true;
      final session = LocalAudioCompleted(
        id: 'guiada',
        timestamp: DateTime(2026, 11, 24, 10).millisecondsSinceEpoch,
      );

      await expectLater(
        stats.addAudioCompleted(session, 600000, skipPost: true),
        throwsA(isA<StateError>()),
      );
      await pumpEventQueue();

      expect(practiceKeys(), isEmpty);
      expect(stats.currentStats!.audioCompleted ?? const [], isEmpty);
    });
  });

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
    expect((await stats.healthPendingRuns()).single.runId, 'salud');
  });

  test(
    'la marca de Salud no se ve mientras el guardado sigue pendiente (TIMER-03)',
    () async {
      await stats.localAllStats;
      prefs.gate = Completer<void>();
      prefs.failAfterGate = true;
      final writing = stats.recordTimerRun(_run('a'));
      await pumpEventQueue();
      // Un envío a Salud al volver a la app lee las marcas en este momento.
      final reading = stats.healthPendingRuns();
      prefs.gate!.complete();
      prefs.gate = null;
      expect(await writing, TimerRecordResult.failed);
      expect(await reading, isEmpty);
      expect(await stats.healthPendingRuns(), isEmpty);

      prefs.failAfterGate = false;
      expect(await stats.recordTimerRun(_run('a')), TimerRecordResult.accepted);
      expect((await stats.healthPendingRuns()).single.runId, 'a');
    },
  );

  test(
    'repetir la verificación cortada no suma dos veces los minutos (REV-09)',
    () async {
      await open(verified: false);
      expect(
        await stats.recordTimerRun(_run('a', ownerId: '', minutes: 12)),
        TimerRecordResult.accepted,
      );
      // El archivado se guarda y el proceso muere antes de reemplazar el
      // historial activo.
      var archived = false;
      prefs.failWhen = (key) {
        if (key == 'stats_pending_owner') {
          archived = true;
          return false;
        }
        return archived;
      };
      await expectLater(stats.acceptServerUser(_account), throwsStateError);
      expect(archived, isTrue);
      prefs.failWhen = null;

      // Al volver a abrir, el historial sin verificar sigue activo y suma
      // otra sesión antes del siguiente intento.
      await open(verified: false);
      expect(stats.verifiedUserId, isNull);
      expect(
        await stats.recordTimerRun(_run('b', ownerId: '', minutes: 5)),
        TimerRecordResult.accepted,
      );
      await stats.acceptServerUser(_account);
      expect(stats.verifiedUserId, _account);
      final summary = await stats.preVerificationSummary();
      expect(summary?.sessions, 2);
      expect(summary?.minutes, 17);

      // Un tercer archivado del mismo historial tampoco cambia el total.
      await open(verified: false);
      final raw =
          jsonDecode(prefs.real.getString('stats_pending_owner')!)
              as Map<String, dynamic>;
      expect(
        LocalAllStats.fromJson(
          raw['stats'] as Map<String, dynamic>,
        ).totalTimeListened,
        17 * 60000,
      );
    },
  );

  group('el historial se publica después de guardarlo (REV-09)', () {
    const statsKey = SharedPreferenceConstants.localAllStatsKey;
    final remote = LocalAllStats.empty().copyWith(
      audioCompleted: [LocalAudioCompleted(id: 'remote', timestamp: 100)],
      totalTracksCompleted: 1,
    );

    Future<void> expectFailedWriteWithOldHistory(
      Future<void> Function() operation, {
      String? owner = _account,
    }) async {
      final before = await stats.localAllStats;
      final started = Completer<void>();
      final gate = Completer<void>();
      prefs.gate = gate;
      prefs.gateKey = statsKey;
      prefs.failAfterGate = true;
      prefs.onWrite = (key) {
        if (key == statsKey && !started.isCompleted) started.complete();
      };

      final finished = expectLater(operation(), throwsStateError);
      await started.future;
      try {
        expect(await stats.localAllStats, same(before));
        expect(stats.verifiedUserId, owner);
      } finally {
        gate.complete();
        await finished;
      }
      expect(await stats.localAllStats, same(before));
      expect(stats.verifiedUserId, owner);
      prefs.gate = null;
      prefs.gateKey = null;
      prefs.failAfterGate = false;
      prefs.onWrite = null;
    }

    test('una descarga fallida conserva el historial para lecturas', () async {
      await stats.localAllStats;
      when(
        () => service.fetchAllStats(),
      ).thenAnswer((_) async => (stats: remote, clientSeq: 12));
      await expectFailedWriteWithOldHistory(() => stats.sync(force: true));
      await stats.sync(force: true);
      expect(record()['stats_local_seq'], 12);
      expect((await stats.localAllStats).audioCompleted!.single.id, 'remote');
    });

    test(
      'una rebase fallida deja los cambios pendientes para reintentar',
      () async {
        await prefs.real.setString(
          statsKey,
          jsonEncode({
            ...LocalAllStats.empty().toJson(),
            'user_id': _account,
            'stats_pending_sync': true,
            'stats_local_seq': 1,
            'stats_changes': [
              {'type': 'repeat', 'duration': 300},
            ],
          }),
        );
        await open(verified: false);
        when(
          () => service.fetchAllStats(),
        ).thenAnswer((_) async => (stats: remote, clientSeq: 12));
        await expectFailedWriteWithOldHistory(stats.flushPendingPost);
        await stats.flushPendingPost();
        expect(record()['stats_local_seq'], 13);
        final saved = await stats.localAllStats;
        expect(saved.audioCompleted!.single.id, 'remote');
        expect(saved.totalTimeListened, 300);
        verify(() => service.postStats(any(), clientSeq: 13)).called(1);
      },
    );

    test('la cuenta anterior sigue visible si falla el cambio', () async {
      await open(verified: false);
      expect(
        await stats.recordTimerRun(_run('local', ownerId: '')),
        TimerRecordResult.accepted,
      );
      await expectFailedWriteWithOldHistory(
        () => stats.acceptServerUser(_account),
        owner: null,
      );
      await stats.acceptServerUser(_account);
      expect(stats.verifiedUserId, _account);
      expect((await stats.preVerificationSummary())?.sessions, 1);
    });

    test('un fallo al guardar el dueño deja la cuenta anterior', () async {
      await stats.localAllStats;
      prefs.failWhen = (key) => key == SharedPreferenceConstants.serverUserId;
      await expectLater(stats.acceptServerUser(_other), throwsStateError);
      expect(stats.verifiedUserId, _account);
      prefs.failWhen = null;
      await stats.acceptServerUser(_other);
      expect(stats.verifiedUserId, _other);
    });
  });

  group('el historial confirma la sesión guardada (END-01)', () {
    test('cambiar de cuenta termina la espera pendiente (REV-10)', () async {
      final confirming = stats.confirmTimerRun(
        'pendiente',
        timeout: const Duration(seconds: 1),
      );
      expect(stats.hasTimerRunConfirmationListeners, isTrue);
      await stats.acceptServerUser(_other);
      expect(
        await confirming.timeout(const Duration(milliseconds: 100)),
        isFalse,
      );
      expect(stats.hasTimerRunConfirmationListeners, isFalse);
    });

    test('cerrar la cuenta termina la espera pendiente (REV-10)', () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      prefs.gate = gate;
      prefs.onWrite = (_) => started.complete();
      final confirming = stats.confirmTimerRun(
        'pendiente',
        timeout: const Duration(seconds: 1),
      );
      final clearing = stats.clearAllStats(preservePending: false);
      await started.future;
      try {
        expect(
          await confirming.timeout(const Duration(milliseconds: 100)),
          isFalse,
        );
        final whileClearing = stats.confirmTimerRun(
          'otra',
          timeout: const Duration(seconds: 1),
        );
        expect(stats.hasTimerRunConfirmationListeners, isFalse);
        expect(await whileClearing, isFalse);
      } finally {
        gate.complete();
        await clearing;
      }
    });

    test('confirma una sesión ya guardada sin esperar', () async {
      expect(await stats.recordTimerRun(_run('a')), TimerRecordResult.accepted);
      expect(
        await stats.confirmTimerRun('a', timeout: Duration.zero),
        isTrue,
      );
    });

    test('espera la sesión que llega después', () async {
      final confirming = stats.confirmTimerRun(
        'b',
        timeout: const Duration(seconds: 5),
      );
      expect(await stats.recordTimerRun(_run('b')), TimerRecordResult.accepted);
      expect(await confirming, isTrue);
      expect(stats.hasTimerRunConfirmationListeners, isFalse);
    });

    test('un guardado fallido no se confirma', () async {
      prefs.failStats = true;
      final confirming = stats.confirmTimerRun(
        'c',
        timeout: const Duration(milliseconds: 50),
      );
      expect(await stats.recordTimerRun(_run('c')), TimerRecordResult.failed);
      expect(await confirming, isFalse);
      expect(stats.hasTimerRunConfirmationListeners, isFalse);
    });

    test('la sesión de otra cuenta no se confirma', () async {
      final confirming = stats.confirmTimerRun(
        'd',
        timeout: const Duration(milliseconds: 50),
      );
      expect(
        await stats.recordTimerRun(_run('d', ownerId: _other)),
        TimerRecordResult.rejected,
      );
      expect(await confirming, isFalse);
    });

    test('confirma una sesión del historial de antes de verificar', () async {
      expect(
        await stats.recordTimerRun(_run('e', ownerId: '')),
        TimerRecordResult.accepted,
      );
      expect(
        await stats.confirmTimerRun('e', timeout: Duration.zero),
        isTrue,
      );
    });
  });
}
