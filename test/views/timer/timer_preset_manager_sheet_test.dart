import 'dart:convert';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_preset.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_settings.dart';
import 'package:medito/providers/timer/timer_presets_provider.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/timer/widgets/timer_preset_manager_sheet.dart';

final l10n = lookupAppLocalizations(const Locale('es'));

const _presets = [
  TimerPreset(
    id: 'a',
    name: 'Mañana',
    settings: TimerSettings(mode: TimerMode.countdown, minutes: 20),
    sound: null,
  ),
  TimerPreset(
    id: 'b',
    name: 'Noche',
    settings: TimerSettings(mode: TimerMode.stopwatch, minutes: 10),
    sound: null,
  ),
  TimerPreset(
    id: 'c',
    name: 'Retiro',
    settings: TimerSettings(mode: TimerMode.countdown, minutes: 90),
    sound: null,
  ),
];

const _open = Key('abrir');

Future<ProviderContainer> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(
    PreviewShell(
      locale: const Locale('es'),
      prefs: {
        ...prefsDark,
        SharedPreferenceConstants.timerPresets: jsonEncode([
          for (final preset in _presets) preset.toJson(),
        ]),
      },
      child: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: _open,
            onPressed: () => showTimerPresetManagerSheet(context),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_open));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byKey(_open)));
}

List<String> _ids(ProviderContainer container) =>
    container.read(timerPresetsProvider).map((preset) => preset.id).toList();

void main() {
  testWidgets('muestra nombre y duración de cada temporizador', (tester) async {
    await _openSheet(tester);
    expect(find.text('Mañana'), findsOneWidget);
    expect(find.text('20 min'), findsOneWidget);
    expect(find.text(l10n.timerModeStopwatch), findsOneWidget);
    expect(find.text('1 ${l10n.hours} 30 min'), findsOneWidget);
    expect(find.byTooltip(l10n.timerPresetRename), findsNWidgets(3));
    expect(find.byTooltip(l10n.timerPresetDelete), findsNWidgets(3));
  });

  testWidgets('arrastrar reordena con el id', (tester) async {
    final container = await _openSheet(tester);
    final first = tester.getCenter(find.text('Mañana'));
    final gesture = await tester.startGesture(first);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    final last = tester.getCenter(find.text('Retiro'));
    // Se arrastra en pasos, hasta pasar el centro del último.
    final distance = last.dy - first.dy + 60;
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(Offset(0, distance / 6));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_ids(container), ['b', 'c', 'a']);
  });

  testWidgets('cambia el nombre', (tester) async {
    final container = await _openSheet(tester);
    await tester.tap(find.byTooltip(l10n.timerPresetRename).at(1));
    await tester.pumpAndSettle();
    expect(find.text(l10n.timerPresetRename), findsWidgets);
    await tester.enterText(find.byType(TextField), '  Tarde  ');
    await tester.tap(find.text(l10n.timerPresetSave));
    await tester.pumpAndSettle();
    expect(container.read(timerPresetsProvider)[1].name, 'Tarde');
    expect(find.text('Tarde'), findsOneWidget);
  });

  testWidgets('borra después de confirmar y «Listo» cierra', (tester) async {
    final container = await _openSheet(tester);
    await tester.tap(find.byTooltip(l10n.timerPresetDelete).first);
    await tester.pumpAndSettle();
    expect(find.text(l10n.timerDeletePresetQuestion('Mañana')), findsOne);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(l10n.timerPresetDelete),
      ),
    );
    await tester.pumpAndSettle();
    expect(_ids(container), ['b', 'c']);

    await tester.tap(find.text(l10n.timerDone));
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableListView), findsNothing);
  });

  testWidgets('cancelar el borrado no cambia nada', (tester) async {
    final container = await _openSheet(tester);
    await tester.tap(find.byTooltip(l10n.timerPresetDelete).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.timerPresetCancel));
    await tester.pumpAndSettle();
    expect(_ids(container), ['a', 'b', 'c']);
  });
}
