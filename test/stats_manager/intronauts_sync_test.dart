import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/constants.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/services/network/http_api_service.dart';
import 'package:medito/services/stats_backup_service.dart';
import 'package:medito/services/stats_service.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeStatsApi extends Fake implements HttpApiService {
  final posts = <Map<String, dynamic>>[];
  int gets = 0;
  late Future<Map<String, dynamic>> Function() fetch;
  Future<Map<String, dynamic>> Function(int) acknowledge = (seq) async => {
    'applied': true,
    'client_seq': seq,
  };

  @override
  Future<Map<String, dynamic>> getRequest(
    String path, {
    Map<String, dynamic>? queryParams,
  }) {
    expect(path, HTTPConstants.allStats);
    gets++;
    return fetch();
  }

  @override
  Future<Map<String, dynamic>> postRequest(String path, {dynamic body}) async {
    expect(path, HTTPConstants.allStats);
    final snapshot = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    posts.add(snapshot);
    return acknowledge(snapshot['client_seq'] as int);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = '00000000-0000-4000-8000-000000000001';
  const otherOwner = '00000000-0000-4000-8000-000000000002';
  final session = LocalAudioCompleted(id: 'old', timestamp: 100);
  final oldStats = LocalAllStats.empty().copyWith(
    audioCompleted: [session],
    totalTracksCompleted: 1,
  );

  late SharedPreferences prefs;
  late StatsManager manager;
  late FakeStatsApi api;

  Map<String, dynamic> wire(LocalAllStats stats, int seq) => {
    ...stats.toAllStats().toJson(),
    'client_seq': seq,
  };

  Future<void> restartManager() async {
    manager.resetForTesting();
    await manager.initializeForTesting(
      statsService: StatsService(httpApiService: api, prefs: prefs),
      requireVerifiedUser: true,
    );
  }

  Map<String, dynamic> localRecord() =>
      jsonDecode(prefs.getString(SharedPreferenceConstants.localAllStatsKey)!)
          as Map<String, dynamic>;

  Map<String, dynamic> archivedRecord() =>
      jsonDecode(prefs.getString('stats_pending_owner')!)
          as Map<String, dynamic>;

  List<String> postedIds(Map<String, dynamic> post) =>
      (post['audio_completed'] as List)
          .map((item) => item['id'] as String)
          .toList();

  Future<void> start({
    String? userId = owner,
    bool fetchBaseline = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      SharedPreferenceConstants.isLoggedIn: true,
      SharedPreferenceConstants.userId: 'device-a',
      SharedPreferenceConstants.serverUserId: ?userId,
      SharedPreferenceConstants.localAllStatsKey: jsonEncode(oldStats.toJson()),
    });
    prefs = await SharedPreferences.getInstance();
    api = FakeStatsApi()..fetch = () async => wire(oldStats, 0);
    manager = StatsManager();
    await restartManager();
    if (fetchBaseline) await manager.sync(force: true);
  }

  Future<void> recover() async {
    await prefs.setBool(SharedPreferenceConstants.isLoggedIn, false);
    await manager.clearAllStats();
    await restartManager();
    await prefs.setBool(SharedPreferenceConstants.isLoggedIn, true);
  }

  setUp(start);
  tearDown(() => manager.resetForTesting());

  test(
    'last deletion survives an acknowledged POST, restart and failed GET',
    () async {
      await StatsBackupService(prefs: prefs).backupStats(oldStats, owner);
      await manager.removeAudioCompleted(session);

      expect(localRecord()['audioCompleted'], isEmpty);
      expect(localRecord()['stats_local_seq'], 1);
      expect(localRecord()['stats_pending_sync'], false);
      expect(api.posts.single['audio_completed'], isEmpty);

      await restartManager();
      api.fetch = () async => throw Exception('offline');
      await manager.sync(force: true);

      expect((await manager.localAllStats).audioCompleted, isEmpty);
      expect(api.posts, hasLength(1));
    },
  );

  test('discards a GET that started before a local change', () async {
    final response = Completer<Map<String, dynamic>>();
    final started = Completer<void>();
    api.fetch = () {
      started.complete();
      return response.future;
    };
    final sync = manager.sync(force: true);
    await started.future;

    await manager.removeAudioCompleted(session);
    response.complete(oldStats.toAllStats().toJson());
    await sync;

    expect((await manager.localAllStats).audioCompleted, isEmpty);
    expect(api.posts.single['audio_completed'], isEmpty);
  });

  test('does not POST data merely read from the server', () async {
    api.fetch = () async => oldStats.toAllStats().toJson();
    await manager.sync(force: true);
    expect((await manager.localAllStats).audioCompleted, hasLength(1));
    expect(api.posts, isEmpty);
  });

  test('a late POST response leaves the newer change pending', () async {
    final olderStarted = Completer<void>();
    final newerStarted = Completer<void>();
    final older = Completer<Map<String, dynamic>>();
    final newer = Completer<Map<String, dynamic>>();
    api.acknowledge = (seq) {
      if (seq == 1) {
        olderStarted.complete();
        return older.future;
      }
      newerStarted.complete();
      return newer.future;
    };

    final firstEdit = manager.addTrackChecked('checked-without-playing');
    await olderStarted.future;
    final secondEdit = manager.removeTrackChecked('checked-without-playing');
    await pumpEventQueue();

    expect(api.posts, hasLength(1));
    expect(localRecord()['stats_local_seq'], 2);
    older.complete({'applied': true, 'client_seq': 1});
    await newerStarted.future;
    expect(localRecord()['stats_pending_sync'], true);
    expect(api.posts.last['tracks_checked'], isEmpty);
    newer.complete({'applied': true, 'client_seq': 2});
    await Future.wait([firstEdit, secondEdit]);
    expect(localRecord()['stats_pending_sync'], false);
  });

  Future<void> forceLogoutWithPendingDeletion() async {
    api.acknowledge = (_) async => throw Exception('offline');
    await manager.removeAudioCompleted(session);
    await recover();
    expect(archivedRecord()['user_id'], owner);
    api.acknowledge = (seq) async => {'applied': true, 'client_seq': seq};
  }

  test(
    'forced logout re-posts pending stats only for a verified UUID match',
    () async {
      await forceLogoutWithPendingDeletion();
      await manager.sync(force: true);
      expect(api.posts, hasLength(1));
      await manager.acceptServerUser('device-a');
      expect(api.posts, hasLength(1));

      await manager.acceptServerUser(owner);
      await manager.flushPendingPost();

      expect(api.posts, hasLength(2));
      expect(api.posts.last['audio_completed'], isEmpty);
      expect(api.posts.last['client_seq'], 1);
      expect(prefs.containsKey('stats_pending_owner'), false);
      expect(localRecord()['stats_pending_sync'], false);
    },
  );

  test(
    'a different verified UUID leaves archived edits on the device',
    () async {
      await forceLogoutWithPendingDeletion();
      await manager.acceptServerUser(otherOwner);
      api.fetch = () async => wire(LocalAllStats.empty(), 0);
      await manager.sync(force: true);

      expect(archivedRecord()['user_id'], owner);
      expect(api.posts, hasLength(1));
      expect((await manager.localAllStats).audioCompleted, isEmpty);
    },
  );

  test(
    'account deletion discards the saved pending snapshot and baseline',
    () async {
      await forceLogoutWithPendingDeletion();
      await manager.clearAllStats(preservePending: false);
      await manager.acceptServerUser(owner);
      await manager.flushPendingPost();

      expect(prefs.containsKey('stats_pending_owner'), false);
      expect(localRecord().containsKey('stats_synced'), false);
      expect(api.posts, hasLength(1));
    },
  );

  test(
    'same client ID does not authorize replay of unknown-owner stats',
    () async {
      await start(userId: null, fetchBaseline: false);
      await manager.removeAudioCompleted(session);
      await recover();
      expect(archivedRecord()['user_id'], isNull);
      expect(archivedRecord()['stats_pending_sync'], true);

      await manager.acceptServerUser(owner);
      await manager.flushPendingPost();

      expect(prefs.getString(SharedPreferenceConstants.userId), 'device-a');
      expect(archivedRecord()['user_id'], isNull);
      expect(archivedRecord()['stats_changes'], hasLength(1));
      expect(api.posts, isEmpty);
    },
  );

  test(
    'same UUID restores synced history even when the first GET fails',
    () async {
      await recover();
      expect(archivedRecord()['user_id'], owner);
      expect(archivedRecord()['stats_pending_sync'], false);
      api.fetch = () async => throw Exception('offline');
      await manager.acceptServerUser(owner);
      await manager.sync(force: true);
      await manager.addAudioCompleted(
        LocalAudioCompleted(id: 'new', timestamp: 200),
        50,
      );

      expect(postedIds(api.posts.single), ['old', 'new']);
    },
  );

  test(
    'without a baseline, retains new completions until a GET succeeds',
    () async {
      await start(fetchBaseline: false);
      await recover();
      await manager.acceptServerUser(owner);
      api.fetch = () async => throw Exception('offline');
      await manager.sync(force: true);
      await manager.addAudioCompleted(
        LocalAudioCompleted(id: 'new', timestamp: 200),
        50,
      );
      expect(api.posts, isEmpty);
      expect(localRecord()['stats_changes'], hasLength(1));

      await restartManager();
      api.fetch = () async => wire(oldStats, 7);
      await manager.sync(force: true);

      expect(postedIds(api.posts.single), ['old', 'new']);
      expect(api.posts.single['client_seq'], 8);
      expect(localRecord()['stats_pending_sync'], false);
    },
  );

  test(
    'does not count repeated listening twice after a lost POST response',
    () async {
      api.acknowledge = (_) async => throw Exception('lost response');
      await manager.addRepeatListeningTime(300);
      expect(localRecord()['stats_pending_sync'], true);

      final applied = api.posts.single;
      await restartManager();
      api.fetch = () async => applied;
      api.acknowledge = (seq) async => {'applied': true, 'client_seq': seq};

      await manager.sync(force: true);

      expect(api.posts.last['client_seq'], 2);
      expect(api.posts.last['total_time_listened'], 300);
      expect(localRecord()['stats_pending_sync'], false);
    },
  );

  test(
    'uses GET sequence for the next write without echoing the GET',
    () async {
      api.fetch = () async => wire(oldStats, 12);
      await manager.sync(force: true);
      expect(localRecord()['stats_local_seq'], 12);
      expect(api.posts, isEmpty);

      await manager.removeAudioCompleted(session);

      expect(api.posts.single['client_seq'], 13);
      expect(postedIds(api.posts.single), isEmpty);
    },
  );

  test(
    'applied:false reloads remote history and retries pending deletions once',
    () async {
      final otherTrack = LocalAudioCompleted(id: 'remote', timestamp: 300);
      api.fetch = () async {
        expect(localRecord()['stats_pending_sync'], true);
        return wire(
          oldStats.copyWith(
            audioCompleted: [session, otherTrack],
            totalTracksCompleted: 2,
          ),
          9,
        );
      };
      final initialGets = api.gets;
      api.acknowledge = (seq) async => {
        'applied': false,
        'client_seq': seq + 5,
      };
      await manager.removeAudioCompleted(session);

      expect(api.gets, initialGets + 1);
      expect(api.posts.map((post) => post['client_seq']), [1, 10]);
      expect(postedIds(api.posts.last), ['remote']);
      expect(localRecord()['stats_pending_sync'], true);
      expect(localRecord()['stats_changes'], hasLength(1));

      api.acknowledge = (seq) async => {'applied': true, 'client_seq': seq};
      await manager.sync(force: true);

      expect(postedIds(api.posts.last), ['remote']);
      expect(localRecord()['stats_pending_sync'], false);
    },
  );
}
