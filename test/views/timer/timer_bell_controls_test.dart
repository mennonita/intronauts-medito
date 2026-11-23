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
}
