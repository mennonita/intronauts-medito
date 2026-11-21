import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/constants.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/services/network/http_api_service.dart';
import 'package:medito/services/stats_backup_service.dart';
import 'package:medito/services/stats_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

@GenerateMocks([HttpApiService])
import 'stats_service_test.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockHttpApiService api;
  late StatsBackupService backups;
  late StatsService stats;
  const userId = '00000000-0000-4000-8000-000000000001';
  final sample = LocalAllStats.empty().copyWith(
    totalTracksCompleted: 1,
    audioCompleted: [LocalAudioCompleted(id: 'track-1', timestamp: 100)],
  );

  setUp(() async {
    api = MockHttpApiService();
    SharedPreferences.setMockInitialValues({
      SharedPreferenceConstants.isLoggedIn: true,
      SharedPreferenceConstants.serverUserId: userId,
    });
    final prefs = await SharedPreferences.getInstance();
    stats = StatsService(httpApiService: api, prefs: prefs);
    backups = StatsBackupService(prefs: prefs);
  });

  test('reads the wire-format server snapshot', () async {
    when(api.getRequest(HTTPConstants.allStats)).thenAnswer(
      (_) async => {...sample.toAllStats().toJson(), 'client_seq': 42},
    );

    final fetched = await stats.fetchAllStats();
    expect(fetched?.stats.totalTracksCompleted, 1);
    expect(fetched?.clientSeq, 42);
    expect(fetched?.stats.audioCompleted?.single.id, 'track-1');
  });

  test('accepts empty server stats even when a local backup exists', () async {
    await backups.backupStats(sample, userId);
    when(
      api.getRequest(HTTPConstants.allStats),
    ).thenAnswer((_) async => LocalAllStats.empty().toAllStats().toJson());

    final fetched = await stats.fetchAllStats();
    expect(fetched?.stats.audioCompleted, isEmpty);
    expect(fetched?.stats.totalTracksCompleted, 0);
  });

  test(
    'returns null on fetch failure even when a local backup exists',
    () async {
      await backups.backupStats(sample, userId);
      when(
        api.getRequest(HTTPConstants.allStats),
      ).thenThrow(Exception('offline'));

      expect(await stats.fetchAllStats(), isNull);
    },
  );

  test(
    'posts empty history with the sequence and returns the acknowledgment',
    () async {
      when(
        api.postRequest(HTTPConstants.allStats, body: anyNamed('body')),
      ).thenAnswer((_) async => {'applied': true, 'client_seq': 7});

      expect(await stats.postStats(LocalAllStats.empty(), clientSeq: 7), (
        applied: true,
        clientSeq: 7,
      ));
      final body =
          verify(
                api.postRequest(
                  HTTPConstants.allStats,
                  body: captureAnyNamed('body'),
                ),
              ).captured.single
              as Map<String, dynamic>;
      expect(body['audio_completed'], isEmpty);
      expect(body['client_seq'], 7);
    },
  );

  test('reports a failed POST without uploading any backup', () async {
    when(
      api.postRequest(HTTPConstants.allStats, body: anyNamed('body')),
    ).thenAnswer((_) async => throw Exception('offline'));

    expect(await stats.postStats(sample, clientSeq: 1), isNull);
    expect((await backups.getLatestBackup(userId))?.totalTracksCompleted, 1);
    verify(
      api.postRequest(HTTPConstants.allStats, body: anyNamed('body')),
    ).called(1);
  });
}
