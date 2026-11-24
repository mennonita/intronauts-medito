import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/timer/widgets/timer_prep_selector.dart';

Future<List<int>> _pump(WidgetTester tester, {int prepSeconds = 0}) async {
  final changes = <int>[];
  await tester.pumpWidget(
    PreviewShell(
      locale: const Locale('es'),
      prefs: prefsDark,
      child: Scaffold(
        body: TimerPrepSelector(
          prepSeconds: prepSeconds,
          onChanged: changes.add,
        ),
      ),
    ),
  );
  return changes;
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('es'));

  testWidgets('opciones en español con título y explicación', (tester) async {
    await _pump(tester);
    expect(find.text('Antes de empezar'), findsOneWidget);
    for (final label in ['Sin espera', '10 s', '30 s', '1 min', '2 min']) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
    }
    expect(find.text(l10n.timerPrepDescription), findsOneWidget);
  });

  testWidgets('marca la opción actual y avisa al elegir otra', (tester) async {
    final changes = await _pump(tester, prepSeconds: 60);
    final selected = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '1 min'),
    );
    expect(selected.selected, isTrue);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '30 s'))
          .selected,
      isFalse,
    );

    await tester.tap(find.text('30 s'));
    await tester.tap(find.text('1 min'));
    await tester.tap(find.text('Sin espera'));
    expect(changes, [30, 0]);
  });

  testWidgets('cada opción mide al menos 48 dp de alto', (tester) async {
    await _pump(tester);
    for (final chip in tester.widgetList(find.byType(ChoiceChip))) {
      final size = tester.getSize(find.byWidget(chip));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });
}
