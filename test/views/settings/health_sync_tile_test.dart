import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/scaffold_messenger_key.dart';
import 'package:medito/utils/health_kit_manager.dart';
import 'package:medito/utils/health_sync_queue.dart';
import 'package:medito/views/settings/health_sync_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _account = '00000000-0000-4000-8000-000000000001';

class _FakeManager extends Fake implements HealthKitManager {
  bool grant = true;
  bool available = true;
  int requests = 0;
  int installs = 0;

  @override
  Future<bool> requestAuthorization() async {
    requests++;
    return grant;
  }

  @override
  Future<bool> hasWriteAccess() async => grant;

  @override
  Future<bool> isHealthConnectAvailable() async => available;

  @override
  Future<void> installHealthConnect() async => installs++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final es = lookupAppLocalizations(const Locale('es'));
  late _FakeManager manager;
  late List<HealthSyncEntry> writes;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    manager = _FakeManager();
    writes = [];
    HealthSyncQueue.resetForTesting();
    HealthSyncQueue.dependencies = HealthSyncDependencies(
      ready: () async {},
      currentAccountId: (_) => _account,
      isIOS: false,
      healthAvailable: () async => true,
      pendingRuns: () async => const [],
      clearPending: (_) async => true,
      write: (entry) async {
        writes.add(entry);
        return true;
      },
      markSynced: (_) async {},
    );
  });

  tearDown(HealthSyncQueue.resetForTesting);

  Future<void> pump(WidgetTester tester, {bool isAndroid = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: scaffoldMessengerKey,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: HealthSyncTile(manager: manager, isAndroid: isAndroid),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool switchValue(WidgetTester tester) =>
      tester.widget<Switch>(find.byType(Switch)).value;

  Future<bool> consent() async =>
      HealthSyncQueue.hasConsent(await SharedPreferences.getInstance());

  testWidgets('encender pide permiso y guarda el consentimiento', (
    tester,
  ) async {
    await pump(tester);
    expect(switchValue(tester), isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(manager.requests, 1);
    expect(switchValue(tester), isTrue);
    expect(await consent(), isTrue);
  });

  testWidgets('apagar quita el consentimiento y vacía la cola', (tester) async {
    await HealthSyncQueue.setConsent(true);
    await HealthSyncQueue.add(
      const HealthSyncEntry(
        key: 'esperando',
        startMs: 1,
        endMs: 2,
        accountId: _account,
        awaitingConsent: true,
      ),
    );
    await pump(tester);
    expect(switchValue(tester), isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(switchValue(tester), isFalse);
    expect(await consent(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(SharedPreferenceConstants.pendingHealthSessions),
      isNull,
    );
    expect(writes, isEmpty);
  });

  testWidgets('sin permiso del sistema se queda apagado y lo explica', (
    tester,
  ) async {
    manager.grant = false;
    await pump(tester);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text(es.permissionExplanation), findsOneWidget);
    expect(switchValue(tester), isFalse);
    expect(await consent(), isFalse);
  });

  testWidgets('Android sin Health Connect ofrece instalarlo', (tester) async {
    manager.available = false;
    await pump(tester, isAndroid: true);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(manager.installs, 1);
    expect(manager.requests, 0);
    expect(find.text(es.healthConnectNotInstalled), findsOneWidget);
    expect(switchValue(tester), isFalse);
  });
}
