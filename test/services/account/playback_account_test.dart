import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('intronauts/playback_account');
  late List<MethodCall> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlaybackAccount.resetForTesting();
    PlaybackAccount.bindsNatively = true;
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    PlaybackAccount.resetForTesting();
  });

  group('identidad local antes de abrir una sesión (TIMER-REVIEW-03)', () {
    test('sin cuenta crea, guarda y vincula una identidad local', () async {
      final prefs = await SharedPreferences.getInstance();

      await PlaybackAccount.ensureBound(prefs: prefs);

      final saved = prefs.getString(SharedPreferenceConstants.userId);
      expect(saved, isNotNull);
      expect(calls.single.method, 'bind');
      expect((calls.single.arguments as Map)['clientId'], saved);
      expect(PlaybackAccount.isBound, isTrue);
    });

    test('dos rutas a la vez vinculan una sola identidad', () async {
      final prefs = await SharedPreferences.getInstance();

      await Future.wait([
        PlaybackAccount.ensureBound(prefs: prefs),
        PlaybackAccount.ensureBound(prefs: prefs),
      ]);
      await PlaybackAccount.ensureBound(prefs: prefs);

      expect(calls, hasLength(1));
    });

    test('la identidad local es la que el inicio de sesión reutiliza: '
        'no descarta el historial sin dueño', () async {
      final prefs = await SharedPreferences.getInstance();
      await PlaybackAccount.ensureBound(prefs: prefs);
      final local = prefs.getString(SharedPreferenceConstants.userId)!;
      final generation = PlaybackAccount.generation;

      // Lo que hacen el inicio normal y /me con el identificador guardado.
      await PlaybackAccount.bind(local);
      await PlaybackAccount.bind(local, userId: 'usuario-verificado');

      expect(PlaybackAccount.generation, generation);
      expect(calls.map((c) => c.method), everyElement('bind'));
      expect(PlaybackAccount.isCurrent(generation), isTrue);
    });

    test('una vinculación que falló se repite con la misma cuenta', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SharedPreferenceConstants.userId, 'cliente');
      var fail = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (fail) throw PlatformException(code: 'PLAYBACK_ACCOUNT');
            return null;
          });
      await expectLater(
        PlaybackAccount.bind('cliente', userId: 'usuario'),
        throwsA(isA<PlatformException>()),
      );
      expect(PlaybackAccount.isBound, isFalse);

      fail = false;
      await PlaybackAccount.ensureBound(prefs: prefs);

      expect(PlaybackAccount.isBound, isTrue);
      expect(calls.last.arguments, {
        'clientId': 'cliente',
        'userId': 'usuario',
      });
    });
  });

  group('borrar la cuenta mientras se vincula (TMR-05)', () {
    List<String> methodsAfterClear() {
      final i = calls.indexWhere((c) => c.method == 'clear');
      return [for (final c in calls.skip(i + 1)) c.method];
    }

    test('un intento que esperaba las preferencias no vuelve a vincular la '
        'identidad anterior', () async {
      SharedPreferences.setMockInitialValues({
        SharedPreferenceConstants.userId: 'cliente-viejo',
      });

      // Sin preferencias dadas: el intento espera a leerlas.
      final ensuring = expectLater(
        PlaybackAccount.ensureBound(),
        throwsStateError,
      );
      await PlaybackAccount.clear();
      await ensuring;
      await pumpEventQueue();

      expect(calls.map((c) => c.method), contains('clear'));
      expect(methodsAfterClear(), isEmpty);
      expect(PlaybackAccount.isBound, isFalse);
    });

    test(
      'un intento que esperaba guardar la identidad nueva se descarta',
      () async {
        final prefs = await SharedPreferences.getInstance();

        final ensuring = expectLater(
          PlaybackAccount.ensureBound(prefs: prefs),
          throwsStateError,
        );
        await PlaybackAccount.clear();
        await ensuring;
        await pumpEventQueue();

        expect(methodsAfterClear(), isEmpty);
        expect(PlaybackAccount.isBound, isFalse);
      },
    );

    test('un intento que repetía la vinculación de la cuenta anterior no la '
        'deja vinculada', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SharedPreferenceConstants.userId, 'cliente');
      var fail = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (fail && call.method == 'bind') {
              throw PlatformException(code: 'PLAYBACK_ACCOUNT');
            }
            return null;
          });
      await expectLater(
        PlaybackAccount.bind('cliente'),
        throwsA(isA<PlatformException>()),
      );
      fail = false;

      // Sin preferencias dadas: espera antes de repetir con la misma cuenta.
      final ensuring = expectLater(
        PlaybackAccount.ensureBound(),
        throwsStateError,
      );
      await PlaybackAccount.clear();
      await ensuring;
      await pumpEventQueue();

      expect(methodsAfterClear(), isEmpty);
      expect(PlaybackAccount.isBound, isFalse);
    });

    test('mientras la eliminación borra las preferencias, una vinculación '
        'nueva no toma la identidad borrada', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SharedPreferenceConstants.userId, 'cliente-viejo');
      await PlaybackAccount.bind('cliente-viejo');
      await PlaybackAccount.clear();

      // La eliminación aún no quita `userId`.
      await expectLater(
        PlaybackAccount.ensureBound(prefs: prefs),
        throwsStateError,
      );
      expect(methodsAfterClear(), isEmpty);

      // Ya sin la identidad borrada, se crea una nueva.
      await prefs.remove(SharedPreferenceConstants.userId);
      await PlaybackAccount.ensureBound(prefs: prefs);
      final fresh = prefs.getString(SharedPreferenceConstants.userId);
      expect(fresh, isNot('cliente-viejo'));
      expect(methodsAfterClear(), ['bind']);
      expect((calls.last.arguments as Map)['clientId'], fresh);
      expect(PlaybackAccount.isBound, isTrue);
    });
  });

  group('limpieza de una eliminación (REV-06)', () {
    test('al reanudar la eliminación antes de vincular, no se vuelve a '
        'vincular la identidad guardada', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SharedPreferenceConstants.userId, 'cliente-viejo');

      final release = PlaybackAccount.holdForWipe('cliente-viejo');
      // Nada vinculado todavía: clear() no tiene identidad que retirar.
      await PlaybackAccount.clear();
      await expectLater(
        PlaybackAccount.ensureBound(prefs: prefs),
        throwsStateError,
      );
      // Aun sin la identidad en las preferencias, nada se vincula mientras
      // dura la limpieza.
      await prefs.remove(SharedPreferenceConstants.userId);
      await expectLater(
        PlaybackAccount.ensureBound(prefs: prefs),
        throwsStateError,
      );
      expect(calls.where((c) => c.method == 'bind'), isEmpty);

      release();
      await PlaybackAccount.ensureBound(prefs: prefs);
      final fresh = prefs.getString(SharedPreferenceConstants.userId);
      expect(fresh, isNot('cliente-viejo'));
      expect((calls.last.arguments as Map)['clientId'], fresh);
      expect(PlaybackAccount.isBound, isTrue);
    });

    test('un intento que ya esperaba las preferencias se descarta', () async {
      SharedPreferences.setMockInitialValues({
        SharedPreferenceConstants.userId: 'cliente-viejo',
      });

      final ensuring = expectLater(
        PlaybackAccount.ensureBound(),
        throwsStateError,
      );
      final release = PlaybackAccount.holdForWipe('cliente-viejo');
      await ensuring;
      await pumpEventQueue();
      expect(calls.where((c) => c.method == 'bind'), isEmpty);
      release();
    });

    test('si la limpieza no quitó la identidad guardada, sigue sin '
        'vincularse al terminar', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SharedPreferenceConstants.userId, 'cliente-viejo');

      PlaybackAccount.holdForWipe('cliente-viejo')();

      await expectLater(
        PlaybackAccount.ensureBound(prefs: prefs),
        throwsStateError,
      );
      expect(calls.where((c) => c.method == 'bind'), isEmpty);
    });
  });
}
