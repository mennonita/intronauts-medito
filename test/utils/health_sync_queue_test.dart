import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/utils/health_sync_queue.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _account = '00000000-0000-4000-8000-000000000001';
const _other = '00000000-0000-4000-8000-000000000002';

/// Entorno falso: marcas del historial, escritor de Salud y cuenta actual.
class _Env {
  _Env({this.isIOS = false});

  final bool isIOS;
  String account = _account;
  bool available = true;
  bool clearFails = false;
  final marks = <HealthPendingRun>[];
  final cleared = <String>[];
  final writes = <HealthSyncEntry>[];
  final synced = <int>[];
  final results = <bool>[];
  Completer<void>? writeGate;

  HealthSyncDependencies deps() => HealthSyncDependencies(
    ready: () async {},
    currentAccountId: (_) => account,
    isIOS: isIOS,
    healthAvailable: () async => available,
    pendingRuns: () async => List.of(marks),
    clearPending: (runId) async {
      if (clearFails) return false;
      marks.removeWhere((m) => m.runId == runId);
      cleared.add(runId);
      return true;
    },
    write: (entry) async {
      final gate = writeGate;
      if (gate != null) await gate.future;
      writes.add(entry);
      return results.isEmpty ? true : results.removeAt(0);
    },
    markSynced: (endMs) async => synced.add(endMs),
  );

  void mark(String runId, {String accountId = _account, int endMs = 2000}) {
    marks.add(
      HealthPendingRun(
        runId: runId,
        startMs: endMs - 1000,
        endMs: endMs,
        accountId: accountId,
      ),
    );
  }
}

HealthSyncEntry _entry(
  String key, {
  String accountId = _account,
  int endMs = 2000,
  bool attempting = false,
  bool awaitingConsent = false,
}) => HealthSyncEntry(
  key: key,
  startMs: endMs - 1000,
  endMs: endMs,
  accountId: accountId,
  attempting: attempting,
  awaitingConsent: awaitingConsent,
);

Future<List<HealthSyncEntry>> _queue() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(SharedPreferenceConstants.pendingHealthSessions);
  if (raw == null) return [];
  return [
    for (final item in jsonDecode(raw) as List)
      HealthSyncEntry.fromJson(item as Map<String, dynamic>),
  ];
}

Future<void> _giveConsent([String account = _account]) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(SharedPreferenceConstants.healthSyncEnabled, true);
  await prefs.setString(SharedPreferenceConstants.healthSyncAccountId, account);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Env env;

  void use(_Env e) {
    env = e;
    HealthSyncQueue.dependencies = e.deps();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HealthSyncQueue.resetForTesting();
    use(_Env());
  });

  tearDown(HealthSyncQueue.resetForTesting);

  group('consentimiento', () {
    test('sin permiso guardado no hay consentimiento', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(HealthSyncQueue.hasConsent(prefs), isFalse);
      await prefs.setBool(SharedPreferenceConstants.healthSyncEnabled, true);
      expect(HealthSyncQueue.hasConsent(prefs), isFalse);
    });

    test('el permiso es de la cuenta que lo dio', () async {
      await HealthSyncQueue.setConsent(true);
      final prefs = await SharedPreferences.getInstance();
      expect(HealthSyncQueue.hasConsent(prefs), isTrue);
      expect(
        prefs.getString(SharedPreferenceConstants.healthSyncAccountId),
        _account,
      );
      env.account = _other;
      expect(HealthSyncQueue.hasConsent(prefs), isFalse);
    });

    test('quitar el permiso vacía la cola', () async {
      await HealthSyncQueue.setConsent(true);
      env.results.add(false);
      await HealthSyncQueue.add(_entry('a'));
      await HealthSyncQueue.flush();
      expect(await _queue(), hasLength(1));

      await HealthSyncQueue.setConsent(false);
      final prefs = await SharedPreferences.getInstance();
      expect(HealthSyncQueue.hasConsent(prefs), isFalse);
      expect(
        prefs.getBool(SharedPreferenceConstants.healthSyncEnabled),
        isFalse,
      );
      expect(await _queue(), isEmpty);
    });
  });

  group('cola', () {
    test('agrega, no repite claves y respeta el límite', () async {
      await HealthSyncQueue.add(_entry('a'));
      await HealthSyncQueue.add(_entry('a', endMs: 9999));
      expect((await _queue()).single.endMs, 2000);

      for (var i = 0; i < HealthSyncQueue.maxEntries + 5; i++) {
        await HealthSyncQueue.add(_entry('k$i'));
      }
      final keys = [for (final e in await _queue()) e.key];
      expect(keys, hasLength(HealthSyncQueue.maxEntries));
      expect(keys.first, 'k5');
      expect(keys.last, 'k${HealthSyncQueue.maxEntries + 4}');
    });

    test('lee entradas viejas sin awaitingConsent', () {
      final entry = HealthSyncEntry.fromJson({
        'key': 'a',
        'startMs': 1,
        'endMs': 2,
        'accountId': _account,
        'attempting': false,
      });
      expect(entry.awaitingConsent, isFalse);
    });

    test('sin permiso no escribe nada', () async {
      await HealthSyncQueue.add(_entry('a'));
      await HealthSyncQueue.flush();
      expect(env.writes, isEmpty);
      expect(await _queue(), hasLength(1));
    });

    test('escribe en orden, del más viejo al más nuevo', () async {
      await _giveConsent();
      await HealthSyncQueue.add(_entry('a', endMs: 1000));
      await HealthSyncQueue.add(_entry('b', endMs: 3000));
      await HealthSyncQueue.add(_entry('c', endMs: 2000));
      await HealthSyncQueue.flush();
      expect([for (final w in env.writes) w.key], ['a', 'b', 'c']);
      expect(env.synced, [1000, 3000, 2000]);
      expect(await _queue(), isEmpty);
    });

    test('se detiene en la primera falla y conserva el resto', () async {
      await _giveConsent();
      env.results.addAll([true, false]);
      await HealthSyncQueue.add(_entry('a'));
      await HealthSyncQueue.add(_entry('b'));
      await HealthSyncQueue.add(_entry('c'));
      await HealthSyncQueue.flush();
      expect([for (final w in env.writes) w.key], ['a', 'b']);
      expect([for (final e in await _queue()) e.key], ['b', 'c']);
    });

    test('un solo envío a la vez', () async {
      await _giveConsent();
      await HealthSyncQueue.add(_entry('a'));
      env.writeGate = Completer<void>();
      final first = HealthSyncQueue.flush();
      final second = HealthSyncQueue.flush();
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      env.writeGate!.complete();
      await Future.wait([first, second]);
      expect([for (final w in env.writes) w.key], ['a']);
      expect(await _queue(), isEmpty);
    });

    test('quita las entradas de otra cuenta sin escribirlas', () async {
      await _giveConsent();
      await HealthSyncQueue.add(_entry('mia'));
      await HealthSyncQueue.add(_entry('ajena', accountId: _other));
      await HealthSyncQueue.flush();
      expect([for (final w in env.writes) w.key], ['mia']);
      expect(await _queue(), isEmpty);
    });

    test('Android: reintenta con la misma clave como clientRecordId', () async {
      await _giveConsent();
      env.results.add(false);
      await HealthSyncQueue.add(_entry('run-1'));
      await HealthSyncQueue.flush();
      expect(await _queue(), hasLength(1));
      await HealthSyncQueue.flush();
      expect([for (final w in env.writes) w.key], ['run-1', 'run-1']);
      expect(await _queue(), isEmpty);
    });

    test('iOS: una entrada que quedó a medio intento se descarta', () async {
      use(_Env(isIOS: true));
      await _giveConsent();
      await HealthSyncQueue.add(_entry('cortada', attempting: true));
      await HealthSyncQueue.add(_entry('nueva'));
      await HealthSyncQueue.flush();
      expect([for (final w in env.writes) w.key], ['nueva']);
      expect(await _queue(), isEmpty);
    });

    test('iOS: marca el intento antes de escribir', () async {
      use(_Env(isIOS: true));
      await _giveConsent();
      await HealthSyncQueue.add(_entry('a'));
      env.writeGate = Completer<void>();
      final flushing = HealthSyncQueue.flush();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect((await _queue()).single.attempting, isTrue);
      env.writeGate!.complete();
      await flushing;
      expect(await _queue(), isEmpty);
    });

    test('iOS: una escritura fallida se puede reintentar', () async {
      use(_Env(isIOS: true));
      await _giveConsent();
      env.results.add(false);
      await HealthSyncQueue.add(_entry('a'));
      await HealthSyncQueue.flush();
      expect((await _queue()).single.attempting, isFalse);
      await HealthSyncQueue.flush();
      expect([for (final w in env.writes) w.key], ['a', 'a']);
      expect(await _queue(), isEmpty);
    });

    test('una sesión guiada pasa por la cola con su clave', () async {
      expect(
        await HealthSyncQueue.addConsentedSession(
          key: 'pista@2000',
          startMs: 1000,
          endMs: 2000,
        ),
        isFalse,
      );
      expect(await _queue(), isEmpty);

      await _giveConsent();
      env.results.add(false);
      expect(
        await HealthSyncQueue.addConsentedSession(
          key: 'pista@2000',
          startMs: 1000,
          endMs: 2000,
        ),
        isTrue,
      );
      await HealthSyncQueue.flush();
      // Falló: queda para el siguiente envío.
      final entry = (await _queue()).single;
      expect(entry.key, 'pista@2000');
      expect(entry.accountId, _account);
      await HealthSyncQueue.flush();
      expect(await _queue(), isEmpty);
      expect(env.writes, hasLength(2));
    });
  });

  group('marcas del temporizador (R78, R85)', () {
    test('cierre entre el historial y la cola: se pasa una vez', () async {
      await _giveConsent();
      env.mark('run-1');
      await HealthSyncQueue.flush();
      expect(env.cleared, ['run-1']);
      expect(env.marks, isEmpty);
      expect([for (final w in env.writes) w.key], ['run-1']);
      await HealthSyncQueue.flush();
      expect(env.writes, hasLength(1));
    });

    test('mientras la marca exista no se escribe esa clave', () async {
      await _giveConsent();
      env.clearFails = true;
      env.mark('run-1');
      await HealthSyncQueue.add(_entry('otra'));
      await HealthSyncQueue.flush();
      expect([for (final w in env.writes) w.key], ['otra']);
      expect([for (final e in await _queue()) e.key], ['run-1']);

      env.clearFails = false;
      await HealthSyncQueue.flush();
      expect([for (final w in env.writes) w.key], ['otra', 'run-1']);
      expect(await _queue(), isEmpty);
    });

    test('cierre entre agregar y quitar la marca: una entrada, '
        'una escritura', () async {
      await _giveConsent();
      await HealthSyncQueue.add(_entry('run-1'));
      env.mark('run-1');
      await HealthSyncQueue.flush();
      expect(env.cleared, ['run-1']);
      expect([for (final w in env.writes) w.key], ['run-1']);
      expect(await _queue(), isEmpty);
    });

    test('la marca de otra cuenta se quita sin escribir', () async {
      await _giveConsent();
      env.mark('ajena', accountId: _other);
      await HealthSyncQueue.flush();
      expect(env.cleared, ['ajena']);
      expect(env.writes, isEmpty);
      expect(await _queue(), isEmpty);
    });

    test('sin permiso queda UNA sesión esperando, sin escribirse; '
        '«Activar» la escribe una vez', () async {
      env.mark('run-1', endMs: 1000);
      await HealthSyncQueue.flush();
      expect(env.cleared, ['run-1']);
      expect(env.writes, isEmpty);
      var queue = await _queue();
      expect(queue.single.key, 'run-1');
      expect(queue.single.awaitingConsent, isTrue);

      // Una segunda sesión reemplaza a la primera.
      env.mark('run-2', endMs: 2000);
      await HealthSyncQueue.flush();
      queue = await _queue();
      expect(queue.single.key, 'run-2');
      expect(env.writes, isEmpty);

      await HealthSyncQueue.setConsent(true);
      expect([for (final w in env.writes) w.key], ['run-2']);
      expect(await _queue(), isEmpty);
      await HealthSyncQueue.flush();
      expect(env.writes, hasLength(1));
    });

    test('«Ahora no» quita la sesión que esperaba', () async {
      env.mark('run-1');
      await HealthSyncQueue.flush();
      expect(await _queue(), hasLength(1));
      await HealthSyncQueue.dropAwaitingConsent();
      expect(await _queue(), isEmpty);
      await HealthSyncQueue.setConsent(true);
      expect(env.writes, isEmpty);
    });

    test(
      'tarjeta descartada o Salud no disponible: no se guarda nada',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(
          SharedPreferenceConstants.healthPromptDismissed,
          true,
        );
        env.mark('run-1');
        await HealthSyncQueue.flush();
        expect(env.cleared, ['run-1']);
        expect(await _queue(), isEmpty);

        await prefs.remove(SharedPreferenceConstants.healthPromptDismissed);
        env.available = false;
        env.mark('run-2');
        await HealthSyncQueue.flush();
        expect(env.cleared, ['run-1', 'run-2']);
        expect(await _queue(), isEmpty);
      },
    );
  });
}
