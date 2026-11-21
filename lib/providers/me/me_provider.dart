import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:medito/services/history/app_history_service.dart';
import 'package:medito/services/network/http_api_service.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';

import '../../models/me/me_model.dart';
import '../../repositories/me/me_repository.dart';
import '../../repositories/auth/auth_repository.dart';

part 'me_provider.g.dart';

final _uuidPattern = RegExp(
  r'^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$',
);

@Riverpod(keepAlive: true)
Future<MeModel> me(Ref ref) async {
  AppLogger.d('ME_PROVIDER', 'me provider called');
  try {
    final authRepo = ref.read(authRepositorySyncProvider);
    final http = HttpApiService();
    final epoch = http.authEpoch;
    final currentUser = authRepo.currentUser;
    AppLogger.d('ME_PROVIDER', 'Has current auth user: ${currentUser != null}');

    // Try to refresh the token to ensure we have valid credentials
    try {
      await authRepo.getToken();
      AppLogger.d('ME_PROVIDER', 'Retrieved valid token');

      // Since we have a valid token, try to fetch ME data first
      var repo = ref.read(meRepositoryProvider);
      AppLogger.d('ME_PROVIDER', 'Got repository instance');

      try {
        final meData = await repo.fetchMe();
        if (!ref.mounted || epoch != http.authEpoch) {
          return const MeModel(id: '');
        }
        if (_uuidPattern.hasMatch(meData.id) && await authRepo.isLoggedIn()) {
          if (!ref.mounted || epoch != http.authEpoch) {
            return const MeModel(id: '');
          }
          final prefs = ref.read(sharedPreferencesProvider);
          await StatsManager().acceptServerUser(meData.id);
          if (!ref.mounted || epoch != http.authEpoch) {
            return const MeModel(id: '');
          }
          final clientId = prefs.getString(SharedPreferenceConstants.userId);
          if (clientId != null) {
            await PlaybackAccount.bind(clientId, userId: meData.id);
          }
          if (!ref.mounted || epoch != http.authEpoch) {
            return const MeModel(id: '');
          }
          await AppHistoryService.recordSignIn(
            prefs,
            userId: meData.id,
            email: meData.email,
          );
        }

        // If we got data from /me endpoint, ensure it's stored
        if (meData.email != null && meData.email!.isNotEmpty) {
          await authRepo.migrateEmailToStorage();
        }

        return _uuidPattern.hasMatch(meData.id)
            ? meData
            : meData.copyWith(id: '');
      } catch (e) {
        AppLogger.e('ME_PROVIDER', 'Error fetching me data', e);
        // Fall through to check local state
      }
    } catch (e) {
      AppLogger.e('ME_PROVIDER', 'Failed to get token', e);
      // If token refresh fails but we have a user with email, return that basic info
      if (currentUser != null && currentUser.email != null) {
        AppLogger.d('ME_PROVIDER', 'Using cached user data due to token error');

        return MeModel(id: '', email: currentUser.email);
      }
      // Fall through to check local state
    }

    // Check if user has email locally as fallback
    final email = authRepo.getUserEmail();
    AppLogger.d('ME_PROVIDER', 'User email from auth: $email');

    // If we have an email, ensure it's stored in secure storage
    if (email != null && email.isNotEmpty) {
      await authRepo.migrateEmailToStorage();

      return MeModel(id: '', email: email);
    }

    // If no email found anywhere, return anonymous user
    AppLogger.d('ME_PROVIDER', 'No email found, user likely not authenticated');

    return MeModel(id: '', email: null);
  } catch (e) {
    AppLogger.e('ME_PROVIDER', 'Error checking auth state', e);
    rethrow;
  }
}

/// Provider to refresh the me provider
final meRefreshProvider = Provider<void Function()>((ref) {
  return () {
    AppLogger.d('ME_PROVIDER', 'invalidating me provider');
    ref.invalidate(meProvider);
    AppLogger.d('ME_PROVIDER', 'me provider invalidated');
  };
});
