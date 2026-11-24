import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/services/timer/ios_timer_run_store.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferencias reales cuyas escrituras del registro pueden fallar o esperar.
class _Prefs extends Fake implements SharedPreferences {
  _Prefs(this.real);

  final SharedPreferences real;
  int failNext = 0;
  // Como SharedPreferences: la caché cambia aunque el disco falle.
  int cacheThenFail = 0;
  bool failRemove = false;
  Completer<void>? gate;
  int writes = 0;

  @override
  Future<bool> setString(String key, String value) async {
    if (key == SharedPreferenceConstants.iosTimerRuns) {
      final waiting = gate;
      if (waiting != null) await waiting.future;
      if (failNext > 0) {
        failNext--;
        return false;
      }
      if (cacheThenFail > 0) {
        cacheThenFail--;
        await real.setString(key, value);
        return false;
      }
      writes++;
    }
    return real.setString(key, value);
  }

  @override
  Object? get(String key) => real.get(key);
  @override
  String? getString(String key) => real.getString(key);
  @override
  Future<bool> remove(String key) async {
    if (failRemove && key == SharedPreferenceConstants.iosTimerRuns) {
      return false;
    }
    return real.remove(key);
  }
}

const _owner = '00000000-0000-4000-8000-000000000001';

TimerRunStart _run(
  String runId, {
  int prepMs = 0,
  int plannedMs = 600000,
  bool extraTime = false,
}) => TimerRunStart(
  runId: runId,
  ownerId: _owner,
  fileId: 'timer-countdown-$plannedMs',
  trackId: 'timer-${plannedMs ~/ 1000}',
  prepMs: prepMs,
  plannedMs: plannedMs,
  extraTime: extraTime,
  isStopwatch: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Prefs prefs;
  late List<Map<String, dynamic>> delivered;
  late List<TimerRecordResult> results;
  late int now;
  late IosTimerRunStore store;

  IosTimerRunStore newStore() => IosTimerRunStore(
    prefs: () async => prefs,
    clock: () => now,
    record: (payload) async {
      delivered.add(payload);
      return results.isEmpty ? TimerRecordResult.accepted : results.removeAt(0);
    },
  );

  Map<String, dynamic>? saved() {
    final raw = prefs.real.getString(SharedPreferenceConstants.iosTimerRuns);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = _Prefs(await SharedPreferences.getInstance());
    delivered = [];
    results = [];
    now = 1000000;
    store = newStore();
  });

  test('empezar guarda la sesión en curso en una sola escritura', () async {
    expect(await store.start(_run('a', prepMs: 120000)), isTrue);
    expect(prefs.writes, 1);
    expect(saved()!['active']['runId'], 'a');
    expect(saved()!['active']['prepMs'], 120000);
    expect(saved()!['finished'], isEmpty);
    expect(store.liveRunId, 'a');
  });

  test('la posición se guarda cada 3 s salvo con force', () async {
    await store.start(_run('a'));
    await store.updatePosition('a', 1000);
    now += 1000;
    await store.updatePosition('a', 2000);
    expect(saved()!['active']['lastPositionMs'], 1000);
    await store.updatePosition('a', 2500, force: true);
    expect(saved()!['active']['lastPositionMs'], 2500);
    now += 3000;
    await store.updatePosition('a', 5500);
    expect(saved()!['active']['lastPositionMs'], 5500);
    await store.updatePosition('otra', 9000, force: true);
    expect(saved()!['active']['lastPositionMs'], 5500);
  });

  test('una escritura fallida no cambia la memoria', () async {
    await store.start(_run('a'));
    prefs.failNext = 1;
    expect(await store.updatePosition('a', 90000, force: true), isFalse);
    expect(store.active!['lastPositionMs'], 0);
    expect(saved()!['active']['lastPositionMs'], 0);
  });

  test(
    'guardar y salir: ≥ 60 s pasa a finished y se entrega una vez',
    () async {
      await store.start(_run('a'));
      expect(
        await store.finish(runId: 'a', durationMs: 120000, timestampMs: 5000),
        isTrue,
      );
      expect(saved()!['active'], isNull);
      final item = (saved()!['finished'] as List).single as Map;
      expect(item['durationMs'], 120000);
      expect(item['recovered'], isFalse);
      expect(store.liveRunId, isNull);

      expect(await store.deliver(), isNull);
      expect(delivered.single[TypeConstants.runIdKey], 'a');
      expect(delivered.single[timerOwnerIdKey], _owner);
      expect(delivered.single[TypeConstants.durationIdKey], 120000);
      expect(delivered.single[TypeConstants.timestampIdKey], 5000);
      expect(saved()!['finished'], isEmpty);
    },
  );

  test('menos de 60 s solo borra la sesión en curso', () async {
    await store.start(_run('a'));
    await store.finish(runId: 'a', durationMs: 59000);
    expect(saved()!['active'], isNull);
    expect(saved()!['finished'], isEmpty);
  });

  test('finish reintenta una vez si la escritura falla', () async {
    await store.start(_run('a'));
    prefs.failNext = 1;
    expect(await store.finish(runId: 'a', durationMs: 120000), isTrue);
    expect(saved()!['finished'], hasLength(1));
  });

  test('salir sin guardar: false si no se pudo borrar dos veces', () async {
    await store.start(_run('a'));
    prefs.failNext = 2;
    expect(await store.discard('a'), isFalse);
    expect(saved()!['active']['runId'], 'a');
    expect(await store.discard('a'), isTrue);
    expect(saved()!['active'], isNull);
    expect(saved()!['finished'], isEmpty);
  });

  test(
    'una sesión cortada se recupera con el tiempo sin preparación',
    () async {
      await store.start(_run('a', prepMs: 120000, plannedMs: 600000));
      await store.updatePosition('a', 420000, force: true);
      // El proceso murió: otra instancia abre el registro.
      store = newStore();
      final recovered = await store.recoverTimerRuns();
      expect(recovered?.minutes, 5);
      expect(recovered?.elapsedMs, 300000);
      expect(delivered.single[TypeConstants.durationIdKey], 300000);
      expect(saved()!['active'], isNull);
      expect(saved()!['finished'], isEmpty);
    },
  );

  test('la sesión que sigue sonando no se recupera', () async {
    await store.start(_run('a'));
    await store.updatePosition('a', 300000, force: true);
    expect(await store.recoverTimerRuns(), isNull);
    expect(saved()!['active']['runId'], 'a');
    expect(delivered, isEmpty);
  });

  test('empezar otra pasa la vieja a finished en la misma escritura', () async {
    await store.start(_run('a'));
    await store.updatePosition('a', 200000, force: true);
    store = newStore();
    final writes = prefs.writes;
    await store.start(_run('b'));
    expect(prefs.writes, writes + 1);
    expect(saved()!['active']['runId'], 'b');
    final item = (saved()!['finished'] as List).single as Map;
    expect(item['runId'], 'a');
    expect(item['recovered'], isTrue);
  });

  test('si la entrega falla se detiene y reintenta después', () async {
    await store.start(_run('a'));
    await store.finish(runId: 'a', durationMs: 120000);
    await store.start(_run('b'));
    await store.finish(runId: 'b', durationMs: 180000);
    results = [TimerRecordResult.failed];
    await store.deliver();
    expect(delivered, hasLength(1));
    expect(saved()!['finished'], hasLength(2));

    results = [TimerRecordResult.duplicate, TimerRecordResult.accepted];
    await store.deliver();
    expect(delivered.map((p) => p[TypeConstants.runIdKey]), ['a', 'a', 'b']);
    expect(saved()!['finished'], isEmpty);
  });

  test('una sesión rechazada se quita sin aviso', () async {
    await store.start(_run('a'));
    await store.updatePosition('a', 200000, force: true);
    store = newStore();
    results = [TimerRecordResult.rejected];
    expect(await store.recoverTimerRuns(), isNull);
    expect(saved()!['finished'], isEmpty);
  });

  test('dos recuperaciones a la vez entregan una sola vez', () async {
    await store.start(_run('a'));
    await store.updatePosition('a', 200000, force: true);
    store = newStore();
    await Future.wait([store.recoverTimerRuns(), store.recoverTimerRuns()]);
    expect(delivered, hasLength(1));
  });

  test('una escritura de otra cuenta se descarta (R82)', () async {
    final stale = PlaybackAccount.generation - 1;
    expect(await store.start(_run('a'), generation: stale), isFalse);
    expect(saved(), isNull);
    expect(store.active, isNull);
  });

  test('clear espera la escritura en curso y no deja nada', () async {
    await store.start(_run('a'));
    prefs.gate = Completer<void>();
    final writing = store.updatePosition('a', 90000, force: true);
    final clearing = store.clear();
    await pumpEventQueue();
    prefs.gate!.complete();
    prefs.gate = null;
    await writing;
    await clearing;
    expect(saved(), isNull);
    expect(store.active, isNull);
    expect(store.liveRunId, isNull);
  });

  test('la marca de final pasado queda guardada', () async {
    await store.start(_run('a'));
    expect(store.endPassed('a'), isFalse);
    await store.markEndPassed('a');
    expect(store.endPassed('a'), isTrue);
    expect(saved()!['active']['endPassed'], isTrue);
  });

  test('los reintentos leen el estado confirmado, no la caché', () async {
    await store.start(_run('a'));
    prefs.cacheThenFail = 2;
    // La caché ya no tiene la sesión, pero el disco sí: sigue sonando.
    expect(await store.discard('a'), isFalse);
    expect(store.active!['runId'], 'a');
    expect(await store.discard('a'), isTrue);
    expect(saved()!['active'], isNull);
  });

  test('un cierre natural después del descarte no la reconstruye', () async {
    await store.start(_run('a'));
    expect(await store.discard('a'), isTrue);
    expect(
      await store.finish(
        runId: 'a',
        durationMs: 120000,
        fallback: _run('a'),
        keepForRetry: true,
      ),
      isTrue,
    );
    expect(saved()!['finished'], isEmpty);
    await store.deliver();
    expect(delivered, isEmpty);
  });

  test('un descarte tras el cierre guardado no lo deshace', () async {
    await store.start(_run('a'));
    await store.finish(runId: 'a', durationMs: 120000);
    expect(await store.discard('a'), isTrue);
    expect(saved()!['finished'], hasLength(1));
  });

  test('el cierre natural que no se guardó conserva su tiempo', () async {
    await store.start(_run('a'));
    prefs.failNext = 2;
    expect(
      await store.finish(runId: 'a', durationMs: 120000, keepForRetry: true),
      isFalse,
    );
    expect(saved()!['active']['runId'], 'a');
    await store.deliver();
    expect(delivered.single[TypeConstants.durationIdKey], 120000);
    expect(saved()!['finished'], isEmpty);
    expect(saved()!['active'], isNull);
  });

  test('un cierre manual que no se guardó no se marca como cerrado', () async {
    await store.start(_run('a'));
    prefs.failNext = 2;
    expect(await store.finish(runId: 'a', durationMs: 120000), isFalse);
    expect(await store.finish(runId: 'a', durationMs: 130000), isTrue);
    expect((saved()!['finished'] as List).single['durationMs'], 130000);
  });

  test(
    'si el borrado por cambio de cuenta falla, avisa y no recupera',
    () async {
      await store.start(_run('a'));
      await store.updatePosition('a', 300000, force: true);
      prefs.failRemove = true;
      await expectLater(store.clear(), throwsStateError);
      expect(await store.recoverTimerRuns(), isNull);
      expect(delivered, isEmpty);
    },
  );

  test('el final pasado se guarda una vez y vuelve el intervalo', () async {
    await store.start(_run('a'));
    await store.updatePosition('a', 1000);
    final writes = prefs.writes;
    await store.updatePosition('a', 2000, endPassed: true);
    expect(prefs.writes, writes + 1);
    await store.updatePosition('a', 2500, endPassed: true);
    await store.updatePosition('a', 2600, endPassed: true);
    expect(prefs.writes, writes + 1);
  });
}
