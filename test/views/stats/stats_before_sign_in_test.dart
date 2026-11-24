import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/stats/stats_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Stats extends StatsNotifier {
  @override
  Future<LocalAllStats> build() async => LocalAllStats.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const locale = Locale('es');
  final l10n = lookupAppLocalizations(locale);
  final manager = StatsManager();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await manager.initializeForTesting();
  });
  tearDown(manager.resetForTesting);

  Future<void> pumpStats(WidgetTester tester) async {
    await tester.pumpWidget(
      PreviewShell(
        locale: locale,
        prefs: prefsDark,
        overrides: [statsProvider.overrideWith(_Stats.new)],
        child: const StatsScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('muestra el resumen local de antes de entrar a la cuenta', (
    tester,
  ) async {
    final result = await tester.runAsync(
      () => manager.recordTimerRun({
        TypeConstants.runIdKey: '0123456789abcdef0123456789abcdef',
        TypeConstants.trackIdKey: 'timer-720',
        TypeConstants.timestampIdKey: DateTime(
          2026,
          11,
          24,
        ).millisecondsSinceEpoch,
        TypeConstants.durationIdKey: const Duration(minutes: 12).inMilliseconds,
      }),
    );
    expect(result, TimerRecordResult.accepted);

    await pumpStats(tester);
    expect(find.text(l10n.statsBeforeSignIn(1, 12)), findsOneWidget);
  });

  testWidgets('omite la línea cuando el resumen local es null', (tester) async {
    expect(await manager.preVerificationSummary(), isNull);
    await pumpStats(tester);
    expect(
      find.textContaining(l10n.statsBeforeSignIn(1, 12).split(':').first),
      findsNothing,
    );
  });
}
