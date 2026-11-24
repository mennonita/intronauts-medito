import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/http/http_constants.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/exceptions/app_error.dart';
import 'package:medito/repositories/auth/auth_repository.dart';
import 'package:medito/services/account/account_service.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/services/secure_storage_service.dart';
import 'package:medito/services/stats_backup_service.dart';
import 'package:medito/services/timer/mantra_counter_store.dart';
import 'package:medito/utils/completed_tracks_storage.dart';
import 'package:medito/utils/health_sync_queue.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stats_service_test.mocks.dart';

class _FakeAuthRepository implements AuthRepository {
  Future<void> Function()? signIn;
  int signOutLocallyCalls = 0;
  int signOutCalls = 0;

  @override
  Future<void> signInAnonymously() async => signIn?.call();

  @override
  Future<void> signOutLocally() async => signOutLocallyCalls++;

  @override
  Future<bool> signOut() async {
    signOutCalls++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeStatsManager implements StatsManager {
  int clearCalls = 0;

  @override
  Future<void> clearAllStats({bool preservePending = false}) async =>
      clearCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late MockHttpApiService http;
  late _FakeAuthRepository auth;
  late _FakeStatsManager stats;
  late SharedPreferences prefs;
  late AccountService service;
  late int nativeClears;

  setUp(() async {
    PlaybackAccount.resetForTesting();
    PlaybackAccount.bindsNatively = false;
    HealthSyncQueue.resetForTesting();
    addTearDown(PlaybackAccount.resetForTesting);
    addTearDown(HealthSyncQueue.resetForTesting);
    SharedPreferences.setMockInitialValues({
      SharedPreferenceConstants.userId: 'old-client-id',
      SharedPreferenceConstants.favorites: '[]',
      SharedPreferenceConstants.themePreference: 'dark',
      SecureStorageService.userEmailPrefsKey: 'gone@example.com',
      CompletedTracksStorage.completedTracksKey: ['{"trackId":"t1"}'],
      'userToken': 'legacy-v3-token',
      'has_active_subscription': true,
      'stats_backup_0': '{"userId":"old-client-id"}',
      'stats_backup_7': '{"userId":"earlier-fork-id"}',
      'stats_backup_index': 8,
      'stats_backup_richest_slot': 0,
      'stats_backup_richest_total': 42,
    });
    prefs = await SharedPreferences.getInstance();
    http = MockHttpApiService();
    auth = _FakeAuthRepository();
    stats = _FakeStatsManager();
    nativeClears = 0;
    service = AccountService(
      httpApiService: http,
      authRepository: auth,
      preferences: prefs,
      statsManager: stats,
      clearPlayback: () async {
        nativeClears++;
        expect(stats.clearCalls, 0);
        expect(
          prefs.containsKey(CompletedTracksStorage.completedTracksKey),
          true,
        );
      },
      retryDelay: Duration.zero,
    );
  });

  test('sends reason + details and wipes the local account', () async {
    when(
      http.deleteRequest(HTTPConstants.me, body: anyNamed('body')),
    ).thenAnswer((_) async => {'deleted': true});

    await service.deleteAccount(
      reason: DeleteAccountReason.switchingApp,
      details: '  Trying something else ’ 🙏  ',
    );

    final body =
        verify(
              http.deleteRequest(
                HTTPConstants.me,
                body: captureAnyNamed('body'),
              ),
            ).captured.single
            as Map<String, dynamic>;
    expect(body, {
      'reason': 'switching_app',
      'details': 'Trying something else ’ 🙏',
    });
    verify(http.clearAuthHeader()).called(1);
    expect(auth.signOutLocallyCalls, 1);
    expect(auth.signOutCalls, 0, reason: 'session is already gone');
    expect(stats.clearCalls, 1);
    expect(nativeClears, 1);
    expect(prefs.getString(SharedPreferenceConstants.userId), isNull);
    expect(prefs.getString(SharedPreferenceConstants.favorites), isNull);
    expect(prefs.getString(SharedPreferenceConstants.themePreference), 'dark');
    expect(prefs.getString(SecureStorageService.userEmailPrefsKey), isNull);
    expect(prefs.get(CompletedTracksStorage.completedTracksKey), isNull);
    expect(prefs.get('userToken'), isNull);
    expect(prefs.get('has_active_subscription'), isNull);
    expect(
      prefs.getKeys().where((k) => k.startsWith('stats_backup_')),
      isEmpty,
    );
    expect(
      await StatsBackupService(prefs: prefs).getAllBackupsAcrossUsers(),
      isEmpty,
    );
  });

  test('retries a lost response and then wipes', () async {
    var calls = 0;
    when(
      http.deleteRequest(HTTPConstants.me, body: anyNamed('body')),
    ).thenAnswer((_) async {
      if (++calls == 1) throw const TimeoutError();
      return {'deleted': true};
    });

    await service.deleteAccount(reason: DeleteAccountReason.other);

    expect(calls, 2);
    expect(auth.signOutLocallyCalls, 1);
  });

  test(
    'reports an unconfirmed outcome after repeated network failures',
    () async {
      when(
        http.deleteRequest(HTTPConstants.me, body: anyNamed('body')),
      ).thenThrow(const NetworkConnectionError());

      await expectLater(
        service.deleteAccount(),
        throwsA(isA<AccountDeletionUnconfirmed>()),
      );

      verify(
        http.deleteRequest(HTTPConstants.me, body: anyNamed('body')),
      ).called(3);
      expect(auth.signOutLocallyCalls, 0);
      expect(
        prefs.getString(SharedPreferenceConstants.userId),
        'old-client-id',
      );
    },
  );

  test('does not retry a server error', () async {
    when(
      http.deleteRequest(HTTPConstants.me, body: anyNamed('body')),
    ).thenThrow(const ServerError());

    await expectLater(service.deleteAccount(), throwsA(isA<ServerError>()));

    verify(
      http.deleteRequest(HTTPConstants.me, body: anyNamed('body')),
    ).called(1);
    expect(auth.signOutLocallyCalls, 0);
  });

  test(
    'resumes local deletion on startup after a lost DELETE response',
    () async {
      when(
        http.deleteRequest(HTTPConstants.me, body: anyNamed('body')),
      ).thenAnswer((_) async {
        expect(prefs.getBool('account_deletion_requested'), true);
        throw const TimeoutError();
      });
      await expectLater(
        service.deleteAccount(),
        throwsA(isA<AccountDeletionUnconfirmed>()),
      );
      expect(service.needsReplacement, true);
      expect(stats.clearCalls, 0);

      auth.signIn = () async {
        expect(prefs.containsKey(SharedPreferenceConstants.userId), false);
        expect(prefs.containsKey('account_deletion_requested'), false);
        expect(stats.clearCalls, 1);
        expect(nativeClears, 1);
        await prefs.setString(
          SharedPreferenceConstants.userId,
          'new-client-id',
        );
      };
      final restarted = AccountService(
        httpApiService: http,
        authRepository: auth,
        preferences: prefs,
        statsManager: stats,
        clearPlayback: () async => nativeClears++,
      );
      await restarted.signInAnonymously();

      expect(restarted.needsReplacement, false);
      expect(
        prefs.getString(SharedPreferenceConstants.userId),
        'new-client-id',
      );
      verify(http.deleteRequest(HTTPConstants.me, body: null)).called(3);
    },
  );

  test('al reanudar la eliminación antes de vincular, nada vuelve a vincular '
      'la identidad borrada ni envía a Salud hasta quitarla (REV-02, '
      'REV-06)', () async {
    await prefs.setBool('account_deletion_requested', true);
    final steps = <String>[];
    var healthHeld = false;
    Future<void> tryToBind(String step) async {
      try {
        await PlaybackAccount.ensureBound(prefs: prefs);
        steps.add('$step: vinculó');
      } on StateError {
        steps.add('$step: bloqueado');
      }
    }

    final resumed = AccountService(
      httpApiService: http,
      authRepository: auth,
      preferences: prefs,
      statsManager: stats,
      holdHealthSync: () {
        healthHeld = true;
        return () => healthHeld = false;
      },
      clearPlayback: () async {
        expect(healthHeld, isTrue);
        await tryToBind('reproducción');
      },
      clearFavorites: () async {
        expect(healthHeld, isTrue);
        // `userId` todavía no se borra.
        expect(
          prefs.getString(SharedPreferenceConstants.userId),
          'old-client-id',
        );
        await tryToBind('favoritos');
      },
    );
    auth.signIn = () async {
      expect(healthHeld, isFalse);
      expect(prefs.containsKey(SharedPreferenceConstants.userId), isFalse);
    };

    await resumed.signInAnonymously();

    expect(steps, ['reproducción: bloqueado', 'favoritos: bloqueado']);
    expect(PlaybackAccount.isBound, isFalse);
    // Ya sin la identidad borrada, se crea una nueva.
    await PlaybackAccount.ensureBound(prefs: prefs);
    expect(
      prefs.getString(SharedPreferenceConstants.userId),
      isNot('old-client-id'),
    );
  });

  test('si la limpieza no se confirma, la identidad borrada sigue sin '
      'vincularse (REV-06)', () async {
    await prefs.setBool('account_deletion_requested', true);
    var healthHeld = false;
    final failing = AccountService(
      httpApiService: http,
      authRepository: auth,
      preferences: prefs,
      statsManager: stats,
      holdHealthSync: () {
        healthHeld = true;
        return () => healthHeld = false;
      },
      clearPlayback: () async {},
      clearFavorites: () async => throw StateError('sin confirmar'),
    );

    await expectLater(failing.signInAnonymously(), throwsStateError);

    expect(healthHeld, isFalse);
    expect(prefs.getString(SharedPreferenceConstants.userId), 'old-client-id');
    await expectLater(
      PlaybackAccount.ensureBound(prefs: prefs),
      throwsStateError,
    );
    expect(PlaybackAccount.isBound, isFalse);
  });

  test('a tombstoned client ID is cleared before a fresh signin', () async {
    final clientIds = <String?>[];
    auth.signIn = () async {
      final clientId = prefs.getString(SharedPreferenceConstants.userId);
      clientIds.add(clientId);
      if (clientId == 'old-client-id') throw const AccountDeletedError();
      expect(clientId, isNull);
      await prefs.setString(SharedPreferenceConstants.userId, 'new-client-id');
    };

    await service.signInAnonymously();

    expect(clientIds, ['old-client-id', null]);
    expect(auth.signOutLocallyCalls, 1);
    expect(stats.clearCalls, 1);
    expect(nativeClears, 1);
    expect(service.needsReplacement, false);
    verifyNever(http.deleteRequest(HTTPConstants.me));
  });

  test('sends no body when nothing was picked', () async {
    when(
      http.deleteRequest(HTTPConstants.me, body: anyNamed('body')),
    ).thenAnswer((_) async => {'deleted': true});

    await service.deleteAccount(details: '   ');

    verify(http.deleteRequest(HTTPConstants.me, body: null)).called(1);
  });

  test('keeps the user signed in when the server fails', () async {
    when(
      http.deleteRequest(HTTPConstants.me, body: anyNamed('body')),
    ).thenThrow(Exception('500'));

    await expectLater(
      service.deleteAccount(reason: DeleteAccountReason.other),
      throwsException,
    );

    verifyNever(http.clearAuthHeader());
    expect(auth.signOutLocallyCalls, 0);
    expect(prefs.getString(SharedPreferenceConstants.userId), 'old-client-id');
  });

  test('treats a response without deleted:true as a failure', () async {
    when(
      http.deleteRequest(HTTPConstants.me, body: anyNamed('body')),
    ).thenAnswer((_) async => {});

    await expectLater(service.deleteAccount(), throwsException);
    expect(auth.signOutLocallyCalls, 0);
  });

  group('cerrar sesión (MANTRA-01)', () {
    late List<String> steps;
    late bool wipeFails;

    AccountService signOutService() {
      steps = [];
      wipeFails = false;
      auth.signOutCalls = 0;
      return AccountService(
        httpApiService: http,
        authRepository: _StepAuth(auth, () => steps.add('signOut')),
        preferences: prefs,
        statsManager: stats,
        clearFavorites: () async => steps.add('favorites'),
        clearMantraCounter: () async {
          steps.add('mantras');
          if (wipeFails) throw StateError('sin confirmar');
        },
        holdHealthSync: () {
          steps.add('pausa Salud');
          return () => steps.add('suelta Salud');
        },
        clearHealthQueue: () async => steps.add('vacía Salud'),
        retryDelay: Duration.zero,
      );
    }

    test('borra el contador de mantras antes de cerrar la sesión', () async {
      final service = signOutService();

      await service.signOut();

      expect(steps, containsAllInOrder(['mantras', 'signOut', 'favorites']));
      expect(stats.clearCalls, 1);
    });

    test('Salud se pausa al EMPEZAR, antes de cualquier espera, y se suelta '
        'solo al terminar (REV-02)', () async {
      final service = signOutService();

      final signingOut = service.signOut();
      // Sin esperar nada: la pausa ya empezó.
      expect(steps.first, 'pausa Salud');
      await signingOut;

      expect(steps, [
        'pausa Salud',
        'mantras',
        'vacía Salud',
        'signOut',
        'favorites',
        'suelta Salud',
      ]);
      expect(stats.clearCalls, 1);
    });

    test('si el borrado del contador no se confirma, la sesión sigue '
        'abierta y se avisa', () async {
      final service = signOutService();
      wipeFails = true;

      await expectLater(service.signOut(), throwsStateError);

      // La cola de Salud sigue intacta y vuelve a enviar.
      expect(steps, ['pausa Salud', 'mantras', 'suelta Salud']);
      expect(stats.clearCalls, 0);
    });

    test('por defecto usa el contador de mantras real', () async {
      final saved = {
        'owner': 'old-client-id',
        'count': 9,
        'rounds': 1,
        'totalEnabled': false,
        'total': 0,
      };
      await prefs.setString(
        SharedPreferenceConstants.mantraCounter,
        jsonEncode(saved),
      );
      final service = AccountService(
        httpApiService: http,
        authRepository: auth,
        preferences: prefs,
        statsManager: stats,
      );
      MantraCounterStore.instance = MantraCounterStore(
        prefs: () async => prefs,
      );
      addTearDown(MantraCounterStore.resetForTesting);

      await service.signOut();

      expect(prefs.getString(SharedPreferenceConstants.mantraCounter), isNull);
      expect(auth.signOutCalls, 1);
    });
  });
}

/// Anota cuándo se cierra la sesión.
class _StepAuth implements AuthRepository {
  _StepAuth(this._inner, this._onSignOut);

  final _FakeAuthRepository _inner;
  final void Function() _onSignOut;

  @override
  Future<bool> signOut() async {
    _onSignOut();
    return _inner.signOut();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
