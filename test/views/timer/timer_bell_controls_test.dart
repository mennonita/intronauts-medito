import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/views/timer/widgets/timer_bell_controls.dart';
import 'package:mocktail/mocktail.dart';

class _Preview extends Mock implements SessionBellPreview {}

void main() {
  testWidgets('el cronómetro permite elegir el sonido de la mitad', (
    tester,
  ) async {
    final preview = _Preview();
    final selected = BellSound.resolve('cuenco_tibetano');
    when(
      () => preview.play(any(), assetKey: selected.assetKey),
    ).thenAnswer((_) async {});
    when(preview.stop).thenAnswer((_) async {});
    var settings = const TimerBellSettings(start: false, end: false);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionBellPreviewProvider.overrideWithValue(preview)],
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => TimerBellControls(
                bells: settings,
                showRandom: false,
                onChanged: (updated) => setState(() => settings = updated),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Campanas'));
    await tester.pumpAndSettle();
    final soundRow = find.text('Sonido: Campana actual');
    expect(soundRow, findsOneWidget);
    expect(find.text('Veces que suena'), findsOneWidget);
    await tester.tap(soundRow);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Escucha una muestra de Cuenco tibetano'));
    await tester.pump();
    expect(settings.intervalSound, 'actual');
    await tester.tap(find.text('Cuenco tibetano'));
    await tester.pump();
    expect(settings.intervalSound, 'cuenco_tibetano');

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('Sonido: Cuenco tibetano'), findsOneWidget);
    verify(() => preview.play(any(), assetKey: selected.assetKey)).called(2);
    verify(preview.stop).called(1);
  });

  testWidgets('cada campana permite elegir cuántas veces suena', (
    tester,
  ) async {
    const initial = TimerBellSettings(intervalMinutes: 1, randomCount: 1);
    var settings = initial;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => TimerBellControls(
                bells: settings,
                showRandom: true,
                onChanged: (updated) => setState(() => settings = updated),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Campanas'));
    await tester.pumpAndSettle();

    final repeatDropdowns = find.descendant(
      of: find.widgetWithText(ListTile, 'Veces que suena'),
      matching: find.byType(DropdownButton<int>),
    );
    expect(repeatDropdowns, findsNWidgets(4));
    for (final (index, label) in [
      '2 veces',
      '3 veces',
      '2 veces',
      '3 veces',
    ].indexed) {
      final dropdown = repeatDropdowns.at(index);
      final button = tester.widget<DropdownButton<int>>(dropdown);
      expect(button.value, 1);
      expect(button.items!.map((item) => (item.child as Text).data), [
        '1 vez',
        '2 veces',
        '3 veces',
      ]);
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).hitTestable().last);
      await tester.pumpAndSettle();
    }

    expect(
      settings.toJson(),
      initial
          .copyWith(
            startRepeats: 2,
            endRepeats: 3,
            intervalRepeats: 2,
            randomRepeats: 3,
          )
          .toJson(),
    );
  });
}
