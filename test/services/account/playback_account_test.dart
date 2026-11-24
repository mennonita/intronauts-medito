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
}
