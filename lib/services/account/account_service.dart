import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/http/http_constants.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/exceptions/app_error.dart';
import 'package:medito/providers/favorites/favorites_provider.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/providers/network/http_api_service_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/repositories/auth/auth_repository.dart';
import 'package:medito/services/network/http_api_service.dart';
import 'package:medito/services/secure_storage_service.dart';
import 'package:medito/services/stats_backup_service.dart';
import 'package:medito/services/timer/mantra_counter_store.dart';
import 'package:medito/utils/completed_tracks_storage.dart';
import 'package:medito/utils/health_sync_queue.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/utils/practice_history.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

final dev = const AppLoggerAdapter('ACCOUNT_SERVICE');

/// Reason codes sent with `DELETE me`. The server stores them as-is (max 64
/// chars), so keep these stable — they're what the deletion log is grouped by.
enum DeleteAccountReason {
  notUsing('not_using'),
  privacy('privacy'),
  switchingApp('switching_app'),
  technicalIssues('technical_issues'),
  tooManyNotifications('too_many_notifications'),
  other('other');

  const DeleteAccountReason(this.code);

  final String code;
}

const _deletionRequestedKey = 'account_deletion_requested';
const _replacementPendingKey = 'account_replacement_pending';

/// Account-scoped local data wiped after a deletion. Device preferences
/// (theme, reminders, downloads, onboarding) are kept.
const _accountPrefKeys = [
  SharedPreferenceConstants.userId,
  SharedPreferenceConstants.userEmail,
  SecureStorageService.userEmailPrefsKey,
  SharedPreferenceConstants.favorites,
  SharedPreferenceConstants.removedFavorites,
  SharedPreferenceConstants.favoritesPendingSync,
  SharedPreferenceConstants.favoritePacks,
  SharedPreferenceConstants.consistencyScoreHistory,
  SharedPreferenceConstants.emailAddressForReceipt,
  SharedPreferenceConstants.lastSuccessfulDonationAtMs,
  SharedPreferenceConstants.lastSuccessfulDonationFrequency,
  SharedPreferenceConstants.signedInUserHistory,
  SharedPreferenceConstants.upNextPackId,
  SharedPreferenceConstants.upNextReturnPackId,
  SharedPreferenceConstants.incompleteAudioSession,
  // Sesiones del temporizador de iOS en curso o por guardar (R76).
  SharedPreferenceConstants.iosTimerRuns,
  // Permiso de Salud y sesiones por escribir: son de la cuenta que lo dio.
  SharedPreferenceConstants.pendingHealthSessions,
  SharedPreferenceConstants.healthSyncEnabled,
  SharedPreferenceConstants.healthSyncAccountId,
  // Contador de mantras: dato religioso sensible, solo de esta cuenta (R89).
  SharedPreferenceConstants.mantraCounter,
  // Track completions still waiting to be posted as stats.
  CompletedTracksStorage.completedTracksKey,
  // Legacy keys no current code writes: the v3.x plaintext API token and the
  // monthly-donor flag mirrored from /me until 265e12b7.
  'userToken',
  'has_active_subscription',
];

/// The deletion request never got a definite answer (network dropped or
/// timed out, even after retries), so the account may or may not be gone.
class AccountDeletionUnconfirmed implements Exception {
  const AccountDeletionUnconfirmed(this.cause);

  final Object cause;

  @override
  String toString() => 'AccountDeletionUnconfirmed($cause)';
}

class AccountService {
  final HttpApiService _httpApiService;
  final AuthRepository _authRepository;
  final SharedPreferences _preferences;
  final StatsManager _statsManager;
  final Future<void> Function() _clearPlayback;
  final Future<void> Function()? _clearFavorites;
  final Future<void> Function() _clearMantraCounter;
  final HealthSyncRelease Function() _holdHealthSync;
  final Future<void> Function() _clearHealthQueue;
  final void Function() Function(String? persistedClientId)
  _holdPlaybackForWipe;

  /// Base delay between DELETE retries (multiplied by the attempt number).
  final Duration retryDelay;

  AccountService({
    required HttpApiService httpApiService,
    required AuthRepository authRepository,
    required SharedPreferences preferences,
    required StatsManager statsManager,
    Future<void> Function() clearPlayback = PlaybackAccount.clear,
    Future<void> Function()? clearFavorites,
    Future<void> Function() clearMantraCounter =
        MantraCounterStore.clearForAccountChange,
    HealthSyncRelease Function() holdHealthSync =
        HealthSyncQueue.holdForAccountChange,
    Future<void> Function() clearHealthQueue = HealthSyncQueue.invalidate,
    void Function() Function(String? persistedClientId) holdPlaybackForWipe =
        PlaybackAccount.holdForWipe,
    this.retryDelay = const Duration(seconds: 1),
  }) : _httpApiService = httpApiService,
       _authRepository = authRepository,
       _preferences = preferences,
       _statsManager = statsManager,
       _clearPlayback = clearPlayback,
       _clearFavorites = clearFavorites,
       _clearMantraCounter = clearMantraCounter,
       _holdHealthSync = holdHealthSync,
       _clearHealthQueue = clearHealthQueue,
       _holdPlaybackForWipe = holdPlaybackForWipe;

  bool get needsReplacement =>
      _preferences.getBool(_deletionRequestedKey) == true ||
      _preferences.getBool(_replacementPendingKey) == true;

  Future<void> _setAccountFlag(String key, bool value) async {
    final saved = value
        ? await _preferences.setBool(key, true)
        : await _preferences.remove(key);
    if (!saved) throw StateError('Could not persist the account change');
  }

  Future<void> signInAnonymously() async {
    if (_preferences.getBool(_deletionRequestedKey) == true) {
      await _finishLocalDeletion();
    }

    try {
      await _authRepository.signInAnonymously();
    } on AccountDeletedError {
      await _setAccountFlag(_deletionRequestedKey, true);
      await _finishLocalDeletion();
      await _authRepository.signInAnonymously();
    }

    if (_preferences.getBool(_replacementPendingKey) == true) {
      await _setAccountFlag(_replacementPendingKey, false);
    }
  }

  /// Cierra la sesión y borra lo que no debe pasar a la siguiente cuenta de
  /// este teléfono.
  ///
  /// Al cerrar sesión la identidad del teléfono no cambia, así que el dueño
  /// guardado del contador de mantras no basta: se borra aquí. Va primero y
  /// debe confirmarse; si falla, la sesión sigue abierta y quien llama avisa
  /// del error (MANTRA-01).
  ///
  /// Los envíos a Salud se detienen al empezar, antes de cualquier espera, y
  /// no vuelven a salir hasta que el historial ya no es de esta cuenta
  /// (REV-02). Las sesiones que esperaban ir a Salud se borran.
  Future<void> signOut() async {
    final releaseHealth = _holdHealthSync();
    try {
      await _clearMantraCounter();
      await _clearHealthQueue();
      await _authRepository.signOut();
      await _statsManager.clearAllStats();
      // Si no, la siguiente cuenta que entre en este teléfono mezclaría (y
      // subiría) los favoritos de esta.
      await _clearFavorites?.call();
    } finally {
      releaseHealth();
    }
  }

  /// Guarda la solicitud antes de borrar la cuenta y limpiar los datos locales.
  ///
  /// Si el servidor no confirma, el siguiente inicio completa la limpieza.
  Future<void> deleteAccount({
    DeleteAccountReason? reason,
    String? details,
  }) async {
    final trimmedDetails = details?.trim();
    final body = <String, dynamic>{
      if (reason != null) 'reason': reason.code,
      if (trimmedDetails != null && trimmedDetails.isNotEmpty)
        'details': trimmedDetails,
    };

    await _setAccountFlag(_deletionRequestedKey, true);
    final response = await _deleteWithRetry(body.isEmpty ? null : body);
    if (response['deleted'] != true) {
      throw Exception('Account deletion was not confirmed');
    }
    dev.log('[ACCOUNT_SERVICE] Account deleted', level: 500);

    await _finishLocalDeletion();
  }

  /// DELETE me is idempotent (an already-deleted account still gets 200), so
  /// a lost or timed-out response is retried rather than reported as a
  /// failure. A 5xx is a definite failure: the user stays signed in.
  Future<Map<String, dynamic>> _deleteWithRetry(
    Map<String, dynamic>? body,
  ) async {
    const attempts = 3;
    for (var attempt = 1; ; attempt++) {
      try {
        return await _httpApiService.deleteRequest(
          HTTPConstants.me,
          body: body,
        );
      } on ServerError {
        rethrow;
      } on AppError catch (e) {
        final transient =
            e is NetworkConnectionError ||
            e is TimeoutError ||
            e is UnknownError;
        if (!transient) rethrow;
        if (attempt >= attempts) throw AccountDeletionUnconfirmed(e);
        dev.log(
          '[ACCOUNT_SERVICE] Delete attempt $attempt failed ($e), retrying',
          level: 800,
        );
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
  }

  /// The access token stays valid for up to 2 hours after deletion and any
  /// authenticated call would recreate a profile, so drop it before anything
  /// else can fire. The server session is already gone, so no tokens/signout.
  ///
  /// Antes de la primera espera: Salud deja de enviar y la reproducción no
  /// vuelve a vincular la identidad borrada, ni siquiera al reanudar la
  /// eliminación antes de la primera vinculación (REV-02, REV-06).
  Future<void> _finishLocalDeletion() async {
    final releaseHealth = _holdHealthSync();
    final releasePlayback = _holdPlaybackForWipe(
      _preferences.getString(SharedPreferenceConstants.userId),
    );
    try {
      final owner = _preferences.getString(
        SharedPreferenceConstants.serverUserId,
      );
      await _setAccountFlag(_replacementPendingKey, true);
      _httpApiService.clearAuthHeader();
      await _authRepository.signOutLocally();
      await PracticeHistory.clear(_preferences, owner);
      await _clearPlayback();
      await _clearFavorites?.call();
      await _statsManager.clearAllStats(preservePending: false);
      await StatsBackupService(prefs: _preferences).clearAll();
      for (final key in _accountPrefKeys) {
        if (!await _preferences.remove(key)) {
          throw StateError('Could not remove account data');
        }
      }
      await _setAccountFlag(_deletionRequestedKey, false);
    } finally {
      // Si algo falló, la identidad borrada sigue retirada mientras siga
      // guardada; el siguiente inicio termina la limpieza.
      releasePlayback();
      releaseHealth();
    }
  }
}

final accountServiceProvider = Provider<AccountService>((ref) {
  return AccountService(
    httpApiService: ref.watch(httpApiServiceProvider),
    authRepository: ref.watch(authRepositorySyncProvider),
    preferences: ref.watch(sharedPreferencesProvider),
    statsManager: ref.watch(statsManagerProvider),
    clearFavorites: () =>
        ref.read(favoritesNotifierProvider.notifier).clearLocal(),
  );
});
