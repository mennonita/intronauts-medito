import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/l10n/app_localizations_es.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/views/timer/widgets/timer_bell_sound_picker.dart';
import 'package:mocktail/mocktail.dart';

class _Preview extends Mock implements SessionBellPreview {}

void main() {
  testWidgets('todas las campanas se muestran sin Premium', (tester) async {
    final l10n = AppLocalizationsEs();
    final preview = _Preview();
    final selected = BellSound.resolve('campanas_viento');
    when(
      () => preview.play(any(), assetKey: selected.assetKey),
    ).thenAnswer((_) async {});
    when(preview.stop).thenAnswer((_) async {});
    var selectedId = defaultBellSoundId;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionBellPreviewProvider.overrideWithValue(preview)],
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTimerBellSoundPicker(
                  context,
                  selected: selectedId,
                  onSelected: (id) => selectedId = id,
                ),
                child: Text(l10n.timerBells),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Campanas'));
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    final visibleSounds = <BellSoundId>{};
    while (true) {
      visibleSounds.addAll([
        for (final sound in bellSounds)
          if (find.text(sound.name(l10n)).hitTestable().evaluate().isNotEmpty)
            sound.id,
      ]);
      expect(find.text('Premium'), findsNothing);
      if (position.pixels >= position.maxScrollExtent) break;
      final next = position.pixels + position.viewportDimension / 2;
      position.jumpTo(next.clamp(0, position.maxScrollExtent));
      await tester.pumpAndSettle();
    }
    expect(visibleSounds, unorderedEquals(bellSounds.map((sound) => sound.id)));

    final audition = find.byTooltip(l10n.bellSoundPreview(selected.name(l10n)));
    await tester.tap(audition);
    await tester.pump();
    verify(() => preview.play(any(), assetKey: selected.assetKey)).called(1);
    expect(selectedId, defaultBellSoundId);

    await tester.tap(find.text(selected.name(l10n)));
    await tester.pump();
    expect(selectedId, selected.id);
    verify(() => preview.play(any(), assetKey: selected.assetKey)).called(1);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    verify(preview.stop).called(1);
  });
}
