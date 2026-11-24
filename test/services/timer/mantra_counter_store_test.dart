import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/services/timer/mantra_counter_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _key = SharedPreferenceConstants.mantraCounter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int now;
  late SharedPreferences prefs;

  MantraCounterStore newStore() =>
      MantraCounterStore(clock: () => now, prefs: () async => prefs);

  /// Un toque cada 200 ms: nunca cae en el filtro de 150 ms.
  BeadResult tap(MantraCounterStore store, [int beads = 108]) {
    now += 200;
    return store.bead(beads);
  }

  Map<String, dynamic>? saved() {
    final raw = prefs.getString(_key);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<MantraCounterStore> loaded({
    Map<String, Object>? initial,
    int beads = 108,
  }) async {
    SharedPreferences.setMockInitialValues(initial ?? {});
    prefs = await SharedPreferences.getInstance();
    final store = newStore();
    MantraCounterStore.instance = store;
    await store.load(beadsPerRound: beads);
    return store;
  }

  setUp(() {
    now = 0;
  });

  tearDown(MantraCounterStore.resetForTesting);

  group('cuentas y vueltas', () {
    test('la cuenta 108 suma una vuelta y vuelve a cero', () async {
      final store = await loaded();
      for (var i = 1; i < 108; i++) {
        expect(tap(store), BeadResult.bead);
      }
      expect(store.count, 107);
      expect(tap(store), BeadResult.round);
      expect(store.count, 0);
      expect(store.rounds, 1);
      expect(tap(store), BeadResult.bead);
      expect(store.count, 1);
    });

    test('con 21 cuentas por vuelta de la organización', () async {
      final store = await loaded(beads: 21);
      final results = [for (var i = 0; i < 42; i++) tap(store, 21)];
      expect(results.where((r) => r == BeadResult.round), hasLength(2));
      expect(results[20], BeadResult.round);
      expect(results[41], BeadResult.round);
      expect(store.rounds, 2);
      expect(store.count, 0);
    });

    test('toques a menos de 150 ms del anterior no cuentan', () async {
      final store = await loaded();
      expect(store.bead(108), BeadResult.bead);
      now += 149;
      expect(store.bead(108), BeadResult.ignored);
      // Se mide desde el último toque que contó.
      now += 1;
      expect(store.bead(108), BeadResult.bead);
      now += 150;
      expect(store.bead(108), BeadResult.bead);
      expect(store.count, 3);
    });

    test('antes de leer lo guardado no cuenta', () async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      final store = newStore();
      expect(store.isLoaded, isFalse);
      expect(tap(store), BeadResult.ignored);
      expect(store.count, 0);
    });

    test('«Empezar de cero» deja el total igual', () async {
      final store = await loaded();
      store.setTotalEnabled(true);
      for (var i = 0; i < 110; i++) {
        tap(store);
      }
      expect(store.rounds, 1);
      expect(store.total, 110);
      store.reset();
      expect(store.count, 0);
      expect(store.rounds, 0);
      expect(store.total, 110);
      expect(store.totalEnabled, isTrue);
    });
  });

  group('total privado', () {
    test('apagado por defecto: las cuentas no suman', () async {
      final store = await loaded();
      tap(store);
      expect(store.totalEnabled, isFalse);
      expect(store.total, 0);
    });

    test('encendido suma cada cuenta; apagado deja de sumar y lo '
        'conserva', () async {
      final store = await loaded();
      store.setTotalEnabled(true);
      tap(store);
      tap(store);
      expect(store.total, 2);
      store.setTotalEnabled(false);
      tap(store);
      expect(store.total, 2);
      store.setTotalEnabled(true);
      expect(store.total, 2);
    });

    test('«Sumar cuentas» acepta de 1 a 1 000 000', () async {
      final store = await loaded();
      // Con el total apagado no se suma.
      expect(store.addToTotal(5), isFalse);
      store.setTotalEnabled(true);
      expect(store.addToTotal(0), isFalse);
      expect(store.addToTotal(-3), isFalse);
      expect(store.addToTotal(1000001), isFalse);
      expect(store.total, 0);
      expect(store.addToTotal(1), isTrue);
      expect(store.addToTotal(1000000), isTrue);
      expect(store.total, 1000001);
      // Sumar no toca la cuenta ni las vueltas.
      expect(store.count, 0);
      expect(store.rounds, 0);
    });

    test('«Borrar mi total» lo pone en cero y lo apaga', () async {
      final store = await loaded();
      store.setTotalEnabled(true);
      store.addToTotal(500);
      tap(store);
      store.clearTotal();
      expect(store.total, 0);
      expect(store.totalEnabled, isFalse);
      expect(store.count, 1);
    });
  });

  group('lectura', () {
    test('retoma lo guardado', () async {
      final store = await loaded(
        initial: {
          _key: jsonEncode({
            'owner': '',
            'count': 40,
            'rounds': 3,
            'totalEnabled': true,
            'total': 1234,
          }),
        },
      );
      expect(store.count, 40);
      expect(store.rounds, 3);
      expect(store.totalEnabled, isTrue);
      expect(store.total, 1234);
    });

    test('si la organización bajó las cuentas por vuelta, la cuenta queda '
        'en la última antes de la vuelta', () async {
      final store = await loaded(
        initial: {
          _key: jsonEncode({
            'owner': '',
            'count': 80,
            'rounds': 1,
            'totalEnabled': false,
            'total': 0,
          }),
        },
        beads: 27,
      );
      expect(store.count, 26);
      expect(tap(store, 27), BeadResult.round);
      expect(store.rounds, 2);
    });

    test('un cambio posterior de cuentas por vuelta también ajusta', () async {
      final store = await loaded();
      for (var i = 0; i < 50; i++) {
        tap(store);
      }
      store.clampTo(21);
      expect(store.count, 20);
    });

    for (final raw in [
      'no es json',
      '[1, 2, 3]',
      '{"count": "diez", "rounds": -4, "total": 1.5}',
    ]) {
      test('un dato dañado cuenta como cero: $raw', () async {
        final store = await loaded(initial: {_key: raw});
        expect(store.isLoaded, isTrue);
        expect(store.count, 0);
        expect(store.rounds, 0);
        expect(store.totalEnabled, isFalse);
        expect(store.total, 0);
        expect(tap(store), BeadResult.bead);
      });
    }
  });

  group('guardado', () {
    test('una sola escritura 1 s después del último cambio', () {
      fakeAsync((async) {
        SharedPreferences.setMockInitialValues({});
        late MantraCounterStore store;
        SharedPreferences.getInstance().then((value) {
          prefs = value;
          store = newStore();
          store.load();
        });
        async.flushMicrotasks();

        tap(store);
        async.elapse(const Duration(milliseconds: 500));
        tap(store);
        async.elapse(const Duration(milliseconds: 900));
        expect(saved(), isNull);
        async.elapse(const Duration(milliseconds: 200));
        expect(saved(), {
          'owner': '',
          'count': 2,
          'rounds': 0,
          'totalEnabled': false,
          'total': 0,
        });
      });
    });

    test('flush guarda de inmediato y cancela el guardado programado', () {
      fakeAsync((async) {
        SharedPreferences.setMockInitialValues({});
        late MantraCounterStore store;
        SharedPreferences.getInstance().then((value) {
          prefs = value;
          store = newStore();
          store.load();
        });
        async.flushMicrotasks();

        tap(store);
        store.flush();
        async.flushMicrotasks();
        expect(saved()?['count'], 1);

        // Nada pendiente: el temporizador ya no escribe.
        prefs.remove(_key);
        async.elapse(const Duration(seconds: 2));
        expect(saved(), isNull);
      });
    });

    test('lo guardado se retoma en un contador nuevo', () async {
      final store = await loaded();
      store.setTotalEnabled(true);
      tap(store);
      tap(store);
      await store.flush();

      final again = newStore();
      await again.load();
      expect(again.count, 2);
      expect(again.total, 2);
      expect(again.totalEnabled, isTrue);
    });
  });

  group('cambio de cuenta (R89)', () {
    test('un guardado pendiente no escribe después de borrar', () {
      fakeAsync((async) {
        SharedPreferences.setMockInitialValues({
          _key: jsonEncode({
            'owner': '',
            'count': 7,
            'rounds': 2,
            'totalEnabled': true,
            'total': 99,
          }),
        });
        late MantraCounterStore store;
        SharedPreferences.getInstance().then((value) {
          prefs = value;
          store = newStore();
          MantraCounterStore.instance = store;
          store.load();
        });
        async.flushMicrotasks();
        expect(store.count, 7);

        // Un toque deja un guardado programado a 1 s.
        tap(store);
        MantraCounterStore.clearForAccountChange();
        async.flushMicrotasks();
        expect(saved(), isNull);

        async.elapse(const Duration(seconds: 5));
        expect(saved(), isNull);
        expect(store.count, 0);
        expect(store.rounds, 0);
        expect(store.total, 0);
        expect(store.totalEnabled, isFalse);

        // Tampoco un flush posterior revive lo anterior.
        store.flush();
        async.flushMicrotasks();
        expect(saved(), isNull);
      });
    });

    test('un guardado que esperaba las preferencias se descarta', () async {
      SharedPreferences.setMockInitialValues({});
      final real = await SharedPreferences.getInstance();
      prefs = real;
      var slow = false;
      final store = MantraCounterStore(
        clock: () => now,
        prefs: () async {
          // El guardado espera un poco más que el borrado.
          if (slow) await Future<void>.delayed(Duration.zero);
          return real;
        },
      );
      MantraCounterStore.instance = store;
      await store.load();
      tap(store);
      slow = true;
      final flushing = store.flush();
      slow = false;
      await MantraCounterStore.clearForAccountChange();
      await flushing;
      expect(saved(), isNull);
      expect(store.count, 0);
    });

    test('cambiar de cuenta en PlaybackAccount borra el contador', () async {
      final store = await loaded();
      PlaybackAccount.resetForTesting();
      PlaybackAccount.bindsNatively = true;
      const channel = MethodChannel('intronauts/playback_account');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        PlaybackAccount.resetForTesting();
      });

      await PlaybackAccount.bind('cuenta-a');
      store.setTotalEnabled(true);
      tap(store);
      await store.flush();
      tap(store);
      expect(saved()?['count'], 1);

      await PlaybackAccount.bind('cuenta-b');
      expect(saved(), isNull);
      expect(store.count, 0);
      expect(store.total, 0);

      // Cerrar sesión también borra.
      tap(store);
      await store.flush();
      expect(saved(), isNotNull);
      await PlaybackAccount.clear();
      expect(saved(), isNull);
      expect(store.count, 0);
    });
  });

  group('dueño del contador (MANTRA-01)', () {
    String counts({required String? owner, int count = 40, int total = 900}) =>
        jsonEncode({
          'owner': ?owner,
          'count': count,
          'rounds': 3,
          'totalEnabled': true,
          'total': total,
        });

    test('lo guardado lleva la identidad de este teléfono', () async {
      final store = await loaded(
        initial: {SharedPreferenceConstants.userId: 'cliente-a'},
      );
      tap(store);
      await store.flush();
      expect(saved()?['owner'], 'cliente-a');
      expect(saved()?['count'], 1);
    });

    test('lo guardado de otra identidad se borra al leer, aunque el cambio '
        'pasó con la app cerrada', () async {
      // Nadie llamó al borrado: la primera vinculación tras reiniciar no lo
      // hace. Solo el dueño guardado lo detecta.
      final store = await loaded(
        initial: {
          SharedPreferenceConstants.userId: 'cliente-b',
          _key: counts(owner: 'cliente-a'),
        },
      );
      expect(store.isLoaded, isTrue);
      expect(store.count, 0);
      expect(store.rounds, 0);
      expect(store.total, 0);
      expect(store.totalEnabled, isFalse);
      expect(saved(), isNull);
      // Lo nuevo ya es de la cuenta actual.
      tap(store);
      await store.flush();
      expect(saved()?['owner'], 'cliente-b');
      expect(saved()?['count'], 1);
    });

    test('lo guardado sin dueño cuenta como ajeno y se borra', () async {
      final store = await loaded(
        initial: {
          SharedPreferenceConstants.userId: 'cliente-a',
          _key: counts(owner: null),
        },
      );
      expect(store.count, 0);
      expect(store.total, 0);
      expect(saved(), isNull);
    });

    test('la misma identidad retoma lo suyo', () async {
      final store = await loaded(
        initial: {
          SharedPreferenceConstants.userId: 'cliente-a',
          _key: counts(owner: 'cliente-a'),
        },
      );
      expect(store.count, 40);
      expect(store.total, 900);
    });

    test('si la identidad cambia con la pantalla ya cargada, lo de memoria '
        'no se guarda a nombre de la nueva', () async {
      final store = await loaded(
        initial: {
          SharedPreferenceConstants.userId: 'cliente-a',
          _key: counts(owner: 'cliente-a'),
        },
      );
      tap(store);
      await prefs.setString(SharedPreferenceConstants.userId, 'cliente-b');
      await store.flush();
      expect(saved(), isNull);
      expect(store.count, 0);
      expect(store.total, 0);

      // Y una nueva lectura con la pantalla abierta tampoco lo muestra.
      final other = await loaded(
        initial: {
          SharedPreferenceConstants.userId: 'cliente-a',
          _key: counts(owner: 'cliente-a'),
        },
      );
      expect(other.count, 40);
      await prefs.setString(SharedPreferenceConstants.userId, 'cliente-b');
      await other.load();
      expect(other.count, 0);
      expect(other.total, 0);
      expect(saved(), isNull);
    });

    test('el borrado lanza si el teléfono no lo confirma', () async {
      SharedPreferences.setMockInitialValues({_key: counts(owner: '')});
      final real = await SharedPreferences.getInstance();
      prefs = real;
      final store = MantraCounterStore(
        clock: () => now,
        prefs: () async => _UnconfirmedRemove(real),
      );
      MantraCounterStore.instance = store;
      await expectLater(
        MantraCounterStore.clearForAccountChange(),
        throwsA(isA<StateError>()),
      );
      // La memoria igual quedó en cero.
      expect(store.count, 0);
      expect(store.total, 0);
    });
  });
}

/// Preferencias cuyo borrado el disco no confirma.
class _UnconfirmedRemove implements SharedPreferences {
  _UnconfirmedRemove(this._real);

  final SharedPreferences _real;

  @override
  String? getString(String key) => _real.getString(key);

  @override
  Future<bool> remove(String key) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
