import 'package:medito/constants/constants.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/stats/all_stats_model.dart';
import 'package:medito/services/network/http_api_service.dart';
import 'package:medito/services/stats_backup_service.dart';
import 'package:medito/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final dev = const AppLoggerAdapter('STATS_SERVICE');

typedef StatsSnapshot = ({LocalAllStats stats, int clientSeq});
typedef StatsPostResult = ({bool applied, int clientSeq});

class StatsService {
  final HttpApiService _httpApiService;
  final SharedPreferences _prefs;
  final StatsBackupService _backupService;

  static const _lastSyncKey = 'last_stats_sync';
  static const _minTimeBetweenRequests =
      2000; // 2 seconds minimum between syncs

  StatsService({
    required HttpApiService httpApiService,
    required SharedPreferences prefs,
  }) : _httpApiService = httpApiService,
       _prefs = prefs,
       _backupService = StatsBackupService(prefs: prefs);

  Future<bool> hasRecentlySync() async {
    var lastSync = _prefs.getInt(_lastSyncKey);
    if (lastSync == null) return false;

    var now = DateTime.now().millisecondsSinceEpoch;
    return now - lastSync < _minTimeBetweenRequests;
  }

  Future<StatsSnapshot?> fetchAllStats() async {
    if (_prefs.getBool(SharedPreferenceConstants.isLoggedIn) != true) {
      return null;
    }

    await _prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);
    try {
      final response = await _httpApiService.getRequest(HTTPConstants.allStats);
      return (
        stats: LocalAllStats.fromAllStats(AllStats.fromJson(response)),
        clientSeq: response['client_seq'] as int? ?? 0,
      );
    } catch (e) {
      dev.log('Stats fetch failed', error: e);
      return null;
    }
  }

  Future<StatsPostResult?> postStats(
    LocalAllStats stats, {
    required int clientSeq,
  }) async {
    if (_prefs.getBool(SharedPreferenceConstants.isLoggedIn) != true) {
      return null;
    }

    final userId =
        _prefs.getString(SharedPreferenceConstants.serverUserId) ?? '';
    final backup = _backupService
        .backupStats(stats, userId)
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            dev.log(
              'Local stats backup failed',
              error: error,
              stackTrace: stack,
            );
          },
        );
    final body = stats.toAllStats().toJson();
    body['audio_completed'] ??= [];
    body['client_seq'] = clientSeq;
    try {
      final response = await _httpApiService.postRequest(
        HTTPConstants.allStats,
        body: body,
      );
      final acknowledgedSeq = response['client_seq'];
      return acknowledgedSeq is int
          ? (applied: response['applied'] == true, clientSeq: acknowledgedSeq)
          : null;
    } catch (e) {
      dev.log('Stats post failed', error: e);
      return null;
    } finally {
      await backup;
    }
  }
}
