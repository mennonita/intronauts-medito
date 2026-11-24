import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/services/export/practice_export.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _es = lookupAppLocalizations(const Locale('es'));

LocalAudioCompleted _completion(String id, int minute) => LocalAudioCompleted(
  id: id,
  timestamp: DateTime.utc(2026, 11, 25, 2, minute).millisecondsSinceEpoch,
);

String _csv({
  List<LocalAudioCompleted> account = const [],
  List<LocalAudioCompleted> device = const [],
  bool accountVerified = true,
}) => buildPracticeCsv(
  account: account,
  accountVerified: accountVerified,
  device: device,
  l10n: _es,
  toLocal: (ms) => DateTime.fromMillisecondsSinceEpoch(
    ms,
    isUtc: true,
  ).subtract(const Duration(hours: 6)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('writes localized rows in chronological order with local dates', () {
    expect(
      _csv(
        account: [_completion('timer-179', 9), _completion('track-1', 3)],
        device: [_completion('manual2', 5)],
      ),
      'fecha,hora,tipo,minutos,contenido,origen\r\n'
      '2026-11-24,20:03,guiada,,track-1,cuenta\r\n'
      '2026-11-24,20:05,manual,,,este teléfono\r\n'
      '2026-11-24,20:09,temporizador,2,,cuenta\r\n',
    );
  });

  test(
    'quotes commas, quotes and newlines, and guards spreadsheet formulas',
    () {
      expect(
        _csv(
          account: [
            _completion('a,b', 1),
            _completion('a"b', 2),
            _completion('a\nb\rc', 3),
            _completion('=SUM(1,2)', 4),
            _completion('+1', 5),
            _completion('-1', 6),
            _completion('@SUM(1)', 7),
          ],
          accountVerified: false,
        ),
        '${_es.exportCsvHeader}\r\n'
        '2026-11-24,20:01,guiada,,"a,b",este teléfono\r\n'
        '2026-11-24,20:02,guiada,,"a""b",este teléfono\r\n'
        '2026-11-24,20:03,guiada,,"a\nb\rc",este teléfono\r\n'
        '2026-11-24,20:04,guiada,,"\'=SUM(1,2)",este teléfono\r\n'
        "2026-11-24,20:05,guiada,,'+1,este teléfono\r\n"
        "2026-11-24,20:06,guiada,,'-1,este teléfono\r\n"
        "2026-11-24,20:07,guiada,,'@SUM(1),este teléfono\r\n",
      );
    },
  );

  test('empty input produces only the header', () {
    expect(_csv(), '${_es.exportCsvHeader}\r\n');
  });

  test(
    'startup removes expired exports and account changes clear the rest',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'practice-export-test-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(pathChannel, (_) async => temp.path);
      addTearDown(() => messenger.setMockMethodCallHandler(pathChannel, null));

      final pluginCache = await Directory('${temp.path}/share_plus').create();
      final expiredAndroid = File(
        '${pluginCache.path}/mi-practica-2026-11-25-expired.csv',
      );
      final expiredIos = File(
        '${temp.path}/practice-export-expired/mi-practica-2026-11-25.csv',
      );
      final fresh = File(
        '${pluginCache.path}/mi-practica-2026-11-25-fresh.csv',
      );
      final unrelated = File('${pluginCache.path}/quote.png');
      for (final file in [expiredAndroid, expiredIos, fresh, unrelated]) {
        await file.create(recursive: true);
      }
      final expired = DateTime.now().subtract(const Duration(minutes: 61));
      for (final file in [expiredAndroid, expiredIos, unrelated]) {
        await file.setLastModified(expired);
      }

      await PracticeExport.cleanupExpiredCopies();
      expect(expiredAndroid.existsSync(), isFalse);
      expect(expiredIos.parent.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(unrelated.existsSync(), isTrue);

      await PracticeExport.clearForAccountChange();
      expect(fresh.existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);
    },
  );

  for (final shareResult in ['completed', 'dismissed', 'failed']) {
    testWidgets(
      'writes BOM, anchors sharing, and lets the receiver read after $shareResult',
      (tester) async {
        final isAndroid = defaultTargetPlatform == TargetPlatform.android;
        final stats = StatsManager()..resetForTesting();
        addTearDown(stats.resetForTesting);
        final temp = Directory.systemTemp.createTempSync(
          'practice-export-test-',
        );
        addTearDown(() => temp.deleteSync(recursive: true));
        final messenger = tester.binding.defaultBinaryMessenger;
        const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
        const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
        messenger.setMockMethodCallHandler(pathChannel, (_) async => temp.path);
        addTearDown(
          () => messenger.setMockMethodCallHandler(pathChannel, null),
        );
        final expired =
            File('${temp.path}/share_plus/mi-practica-2026-11-25-old.csv')
              ..createSync(recursive: true)
              ..setLastModifiedSync(
                DateTime.now().subtract(const Duration(minutes: 61)),
              );

        const activeOwner = '00000000-0000-4000-8000-000000000001';
        const previousOwner = '00000000-0000-4000-8000-000000000002';
        Map<String, dynamic> record(String id, int minute) =>
            LocalAllStats.empty()
                .copyWith(audioCompleted: [_completion(id, minute)])
                .toJson();
        SharedPreferences.setMockInitialValues({
          SharedPreferenceConstants.localAllStatsKey: jsonEncode({
            ...record('timer-120', 2),
            'user_id': activeOwner,
          }),
          'stats_pending_owner': jsonEncode({
            'user_id': previousOwner,
            'stats': record('another-account-track', 1),
            'other_owners': [
              {'user_id': null, 'stats': record('manual1', 3)},
            ],
          }),
        });

        late Map<Object?, Object?> args;
        late File file;
        late File sharedFile;
        late List<int> offeredBytes;
        final offeredPaths = <String>[];
        messenger.setMockMethodCallHandler(shareChannel, (call) async {
          expect(expired.existsSync(), isFalse);
          args = call.arguments as Map<Object?, Object?>;
          file = File((args['paths'] as List).single as String);
          sharedFile = file;
          if (isAndroid) {
            // Android comparte cacheDir/share_plus/<nombre>, como share_plus.
            final cache = Directory('${temp.path}/share_plus')
              ..createSync(recursive: true);
            for (final entry in cache.listSync()) {
              entry.deleteSync();
            }
            sharedFile = file.copySync(
              '${cache.path}/${file.uri.pathSegments.last}',
            );
          }
          offeredPaths.add(sharedFile.path);
          offeredBytes = sharedFile.readAsBytesSync();
          return switch (shareResult) {
            'completed' => 'com.example/.ShareReceiver',
            'dismissed' => '',
            _ => throw PlatformException(code: 'share-failed'),
          };
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(shareChannel, null),
        );

        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ListTile(key: key, title: Text(_es.settingsExportPractice)),
            ),
          ),
        );
        final anchor = tester.getRect(find.byKey(key));
        await tester.runAsync(() => sharePracticeCsv(key.currentContext!));
        await tester.pumpAndSettle();

        final completed = shareResult == 'completed';
        expect(sharedFile.existsSync(), completed);
        expect(file.existsSync(), completed && !isAndroid);
        expect(expired.existsSync(), isFalse);
        // El destino abre el archivo después de que se cerró el selector.
        final bytes = completed ? sharedFile.readAsBytesSync() : offeredBytes;
        expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
        final csv = utf8.decode(bytes.skip(3).toList());
        expect(csv, startsWith('${_es.exportCsvHeader}\r\n'));
        expect(csv, contains(',temporizador,2,,cuenta\r\n'));
        expect(csv, contains(',manual,,,este teléfono\r\n'));
        expect(csv, isNot(contains('another-account-track')));
        expect(
          file.uri.pathSegments.last,
          matches(
            isAndroid
                ? r'^mi-practica-\d{4}-\d{2}-\d{2}-[a-zA-Z0-9_-]+\.csv$'
                : r'^mi-practica-\d{4}-\d{2}-\d{2}\.csv$',
          ),
        );
        expect(args['mimeTypes'], ['text/csv']);
        expect(args['subject'], _es.exportShareSubject);
        expect(args['originX'], anchor.left);
        expect(args['originY'], anchor.top);
        expect(args['originWidth'], anchor.width);
        expect(args['originHeight'], anchor.height);
        expect(
          find.text(_es.exportFailed),
          shareResult == 'failed' ? findsOneWidget : findsNothing,
        );
        if (completed) {
          await tester.runAsync(() => sharePracticeCsv(key.currentContext!));
          expect(offeredPaths.toSet(), hasLength(2));
        }
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }
}
