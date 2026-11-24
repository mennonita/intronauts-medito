import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/providers/notification/mindfulness_bells_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/timer/timer_preferences_provider.dart';
import 'package:medito/services/reminders/mindfulness_bells_service.dart'
    show MindfulnessBellsService;
import 'package:medito/utils/stats_manager.dart';
import 'package:medito/views/settings/timer_settings_section.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final es = lookupAppLocalizations(const Locale('es'));
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SharedPreferences prefs;
  late _RecordingBellsService bells;
  late ProviderContainer container;

  setUp(() async {
    StatsManager().resetForTesting();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    bells = _RecordingBellsService();
  });

  tearDown(() => messenger.setMockMethodCallHandler(permissions, null));

  ProviderContainer createContainer() => ProviderContainer.test(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      mindfulnessBellsServiceProvider.overrideWithValue(bells),
    ],
  );

  Future<void> pumpSection(
    WidgetTester tester, {
    required bool isAndroid,
  }) async {
    container = createContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: TimerSettingsSection(
                isAndroid: isAndroid,
                buildSectionTitle: (_, title) => Text(title),
                buildSectionCard: (children) =>
                    Card(child: Column(children: children)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder switchTile(String title) => find.widgetWithText(SwitchListTile, title);

  test('a failed schedule is restored before the next update', () async {
    container = createContainer();
    final notifier = container.read(mindfulnessBellsProvider.notifier);
    bells.failNextApply = true;

    final failure = expectLater(notifier.setEnabled(true), throwsStateError);
    final retry = notifier.setEnabled(true);
    await failure;
    await retry;

    expect(bells.applied.map((config) => config.enabled), [true, false, true]);
    expect(container.read(mindfulnessBellsProvider).enabled, isTrue);
    expect(
      prefs.getBool(SharedPreferenceConstants.mindfulnessBellsEnabled),
      isTrue,
    );
  });

  testWidgets('Spanish Android settings show five switches and save changes', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(permissions, (call) async {
      expect(call.method, 'checkPermissionStatus');
      return PermissionStatus.granted.index;
    });
    await pumpSection(tester, isAndroid: true);

    expect(find.text('Temporizador'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(5));
    for (final title in [
      'Música de otras apps',
      'Pantalla encendida',
      'Campanas durante el día',
    ]) {
      final tile = switchTile(title);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    }
    final timer = container.read(timerPreferencesProvider);
    expect(timer.mixWithOthers, isTrue);
    expect(timer.keepScreenOn, isTrue);
    expect(prefs.getBool(SharedPreferenceConstants.timerMixWithOthers), isTrue);
    expect(prefs.getBool(SharedPreferenceConstants.timerKeepScreenOn), isTrue);
    expect(
      prefs.getBool(SharedPreferenceConstants.mindfulnessBellsEnabled),
      isTrue,
    );
    expect(bells.applied.single.enabled, isTrue);
    expect(find.text('Desde las 09:00'), findsOneWidget);
    expect(find.text('Hasta las 18:00'), findsOneWidget);
    expect(find.text('Cada 2 horas'), findsOneWidget);
  });

  testWidgets('iOS shows timer switches and hides daytime bells', (
    tester,
  ) async {
    await prefs.setBool(
      SharedPreferenceConstants.mindfulnessBellsEnabled,
      true,
    );
    await pumpSection(tester, isAndroid: false);

    expect(switchTile(es.timerMixWithOthersTitle), findsOneWidget);
    expect(switchTile(es.timerKeepScreenOnTitle), findsOneWidget);
    expect(switchTile(es.settingsTimerOnlyOpen), findsOneWidget);
    expect(switchTile(es.settingsTimerOnlySkipEnd), findsOneWidget);
    expect(switchTile(es.mindfulnessBellsTitle), findsNothing);
    expect(find.byType(DropdownButton<int>), findsNothing);
  });

  testWidgets('timer-only switches persist when settings are reopened', (
    tester,
  ) async {
    await pumpSection(tester, isAndroid: false);
    expect(find.text(es.settingsTimerOnlyTitle), findsOneWidget);
    for (final title in [
      es.settingsTimerOnlyOpen,
      es.settingsTimerOnlySkipEnd,
    ]) {
      final tile = switchTile(title);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    }

    expect(prefs.getBool(SharedPreferenceConstants.timerOpenOnTimer), isTrue);
    expect(prefs.getBool(SharedPreferenceConstants.timerSkipEndScreen), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpSection(tester, isAndroid: false);
    expect(
      tester.widget<SwitchListTile>(switchTile(es.settingsTimerOnlyOpen)).value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(switchTile(es.settingsTimerOnlySkipEnd))
          .value,
      isTrue,
    );
  });

  testWidgets('export row shows an empty history message', (tester) async {
    await pumpSection(tester, isAndroid: false);
    final row = find.widgetWithText(ListTile, es.settingsExportPractice);
    expect(find.text(es.settingsExportPracticeSubtitle), findsOneWidget);
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text(es.exportEmpty), findsOneWidget);
  });

  testWidgets('dropdowns persist the window and keep the end after the start', (
    tester,
  ) async {
    await prefs.setBool(
      SharedPreferenceConstants.mindfulnessBellsEnabled,
      true,
    );
    await pumpSection(tester, isAndroid: true);

    final dropdowns = find.byType(DropdownButton<int>);
    expect(dropdowns, findsNWidgets(3));
    tester.widget<DropdownButton<int>>(dropdowns.at(1)).onChanged!(6);
    await tester.pumpAndSettle();
    expect(find.text('Hasta las 10:00'), findsOneWidget);

    tester.widget<DropdownButton<int>>(dropdowns.at(0)).onChanged!(22);
    await tester.pumpAndSettle();
    expect(find.text('Desde las 22:00'), findsOneWidget);
    expect(find.text('Hasta las 23:00'), findsOneWidget);

    tester.widget<DropdownButton<int>>(dropdowns.at(2)).onChanged!(4);
    await tester.pumpAndSettle();
    expect(find.text('Cada 4 horas'), findsOneWidget);
    expect(
      prefs.getInt(SharedPreferenceConstants.mindfulnessBellsStartHour),
      22,
    );
    expect(prefs.getInt(SharedPreferenceConstants.mindfulnessBellsEndHour), 23);
    expect(
      prefs.getInt(SharedPreferenceConstants.mindfulnessBellsEveryHours),
      4,
    );
    expect(
      bells.applied.map(
        (config) => (config.startHour, config.endHour, config.everyHours),
      ),
      [(9, 10, 2), (22, 23, 2), (22, 23, 4)],
    );

    await tester.tap(switchTile(es.mindfulnessBellsTitle));
    await tester.pumpAndSettle();
    expect(dropdowns, findsNothing);
    expect(bells.applied.last.enabled, isFalse);
  });

  testWidgets(
    'denied permission leaves bells off and shows the localized message',
    (tester) async {
      var requests = 0;
      messenger.setMockMethodCallHandler(permissions, (call) async {
        switch (call.method) {
          case 'checkPermissionStatus':
            return PermissionStatus.denied.index;
          case 'requestPermissions':
            requests++;
            return {
              Permission.notification.value: PermissionStatus.denied.index,
            };
          default:
            fail('Unexpected permission method ${call.method}');
        }
      });
      await pumpSection(tester, isAndroid: true);

      final tile = switchTile(es.mindfulnessBellsTitle);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.text(es.reminderPrimerContinue));
      await tester.pumpAndSettle();

      expect(requests, 1);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      expect(bells.applied, isEmpty);
      expect(find.text(es.mindfulnessBellsPermissionNeeded), findsOneWidget);
    },
  );
}

class _RecordingBellsService extends MindfulnessBellsService {
  final applied = <MindfulnessBellsConfig>[];
  bool failNextApply = false;

  @override
  Future<void> apply(MindfulnessBellsConfig config) async {
    applied.add(config);
    if (failNextApply) {
      failNextApply = false;
      throw StateError('Scheduling failed');
    }
  }
}
