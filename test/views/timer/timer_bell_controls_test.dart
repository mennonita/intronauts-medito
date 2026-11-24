import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/l10n/app_localizations_es.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/timer/timer_settings_provider.dart';
import 'package:medito/views/timer/widgets/timer_bell_controls.dart';

class _TimerSettingsNotifier extends TimerSettingsNotifier {
  _TimerSettingsNotifier(this.settings);

  final TimerSettings settings;

  @override
  TimerSettings build() => settings;
}

Future<void> _pumpControls(
  WidgetTester tester, {
  TimerBellSettings bells = const TimerBellSettings(),
  TimerMode mode = TimerMode.countdown,
  List<TimerStage> stages = const [],
  bool? showSpokenCues,
  ValueChanged<TimerBellSettings>? onChanged,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      timerSettingsProvider.overrideWith(
        () => _TimerSettingsNotifier(
          TimerSettings(mode: mode, minutes: 10, stages: stages, bells: bells),
        ),
      ),
    ],
    child: MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: StatefulBuilder(
            builder: (context, setState) => TimerBellControls(
              bells: bells,
              showRandom: mode == TimerMode.countdown,
              showSpokenCues: showSpokenCues,
              onChanged: (updated) {
                setState(() => bells = updated);
                onChanged?.call(updated);
              },
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _dropdownFor(String label) => find.descendant(
  of: find.widgetWithText(ListTile, label),
  matching: find.byType(DropdownButton<int>),
);

void main() {
  test('resume las campanas en español y toma el primer sonido activo', () {
    final l10n = AppLocalizationsEs();
    const all = TimerBellSettings(
      endSound: 'cuenco_tibetano',
      intervalMinutes: 5,
      intervalSound: 'bloque_madera',
      randomCount: 2,
      randomSound: 'handpan',
      output: TimerBellOutput.vibration,
    );
    expect(
      timerBellsSummary(l10n, const TimerBellSettings(), isStopwatch: false),
      'Al empezar, al terminar · Campana clásica',
    );
    expect(
      timerBellsSummary(l10n, all, isStopwatch: false),
      'Al empezar, al terminar, cada 5 min, 2 al azar · Campana clásica · vibración',
    );
    expect(
      timerBellsSummary(l10n, all.copyWith(start: false), isStopwatch: true),
      'Al terminar, cada 5 min · Cuenco tibetano · vibración',
    );
    final noEnds = all.copyWith(start: false, end: false);
    expect(
      timerBellsSummary(l10n, noEnds, isStopwatch: true),
      'Cada 5 min · Bloque de madera · vibración',
    );
    final randomOnly = noEnds.copyWith(
      intervalMinutes: 0,
      output: TimerBellOutput.soundAndVibration,
    );
    expect(
      timerBellsSummary(l10n, randomOnly, isStopwatch: false),
      '2 al azar · Handpan',
    );
    expect(
      timerBellsSummary(l10n, randomOnly, isStopwatch: true),
      'Sin campanas',
    );
    expect(
      timerBellsSummary(
        l10n,
        randomOnly.copyWith(randomCount: 0, output: TimerBellOutput.vibration),
        isStopwatch: false,
      ),
      'Sin campanas',
    );
  });

  testWidgets('muestra el resumen y los cuatro grupos en español', (
    tester,
  ) async {
    await _pumpControls(tester);
    expect(find.text('Al empezar, al terminar · Campana clásica'), findsOne);
    await _tap(tester, find.text('Campanas'));

    for (final label in [
      'Al empezar',
      'Al terminar',
      'Campana cada…',
      'Campanas al azar',
      'Cómo te avisan',
    ]) {
      expect(find.text(label), findsOne);
    }
    expect(find.text('Sonido: Campana clásica'), findsNWidgets(2));
  });

  testWidgets('el cronómetro solo muestra ajustes de campanas activas', (
    tester,
  ) async {
    await _pumpControls(
      tester,
      bells: const TimerBellSettings(start: false, end: false, randomCount: 2),
      mode: TimerMode.stopwatch,
      showSpokenCues: true,
    );
    expect(find.text('Sin campanas'), findsOne);
    await _tap(tester, find.text('Campanas'));
    expect(find.text('Campanas al azar'), findsNothing);
    expect(find.text('Decir el tiempo que queda'), findsNothing);
    expect(find.textContaining('Sonido:'), findsNothing);
    expect(find.text('Veces que suena'), findsNothing);

    await _tap(tester, _dropdownFor('Campana cada…'));
    await _tap(tester, find.text('Cada 5 minutos').hitTestable().last);
    expect(find.text('Cada 5 min · Campana clásica'), findsOne);
    expect(find.text('Sonido: Campana clásica'), findsOne);
    expect(find.text('Veces que suena'), findsOne);
  });

  testWidgets('cada campana permite elegir cuántas veces suena', (
    tester,
  ) async {
    const initial = TimerBellSettings(intervalMinutes: 1, randomCount: 1);
    var settings = initial;
    await _pumpControls(
      tester,
      bells: initial,
      onChanged: (updated) => settings = updated,
    );
    await _tap(tester, find.text('Campanas'));

    final repeatDropdowns = _dropdownFor('Veces que suena');
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
      await _tap(tester, dropdown);
      await _tap(tester, find.text(label).hitTestable().last);
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

  testWidgets('cambia los avisos y muestra la nota de solo vibración', (
    tester,
  ) async {
    var settings = const TimerBellSettings();
    await _pumpControls(tester, onChanged: (updated) => settings = updated);
    await _tap(tester, find.text('Campanas'));

    for (final (label, output) in [
      ('Solo vibración', TimerBellOutput.vibration),
      ('Sonido y vibración', TimerBellOutput.soundAndVibration),
      ('Sonido', TimerBellOutput.sound),
    ]) {
      await _tap(tester, find.text(label));
      expect(settings.output, output);
      expect(
        find.textContaining('Útil si meditas junto a otras personas.'),
        output == TimerBellOutput.vibration ? findsOne : findsNothing,
      );
    }
  });

  testWidgets('Android permite activar los avisos hablados', (tester) async {
    var settings = const TimerBellSettings();
    await _pumpControls(tester, onChanged: (updated) => settings = updated);
    await _tap(tester, find.text('Campanas'));
    await _tap(tester, find.text('Decir el tiempo que queda'));
    expect(settings.spokenCues, isTrue);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('iOS oculta los avisos hablados de forma predeterminada', (
    tester,
  ) async {
    await _pumpControls(tester);
    await _tap(tester, find.text('Campanas'));
    expect(find.text('Decir el tiempo que queda'), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('la sesión por partes omite la campana de inicio', (
    tester,
  ) async {
    await _pumpControls(
      tester,
      bells: const TimerBellSettings(startSound: 'cuenco_tibetano'),
      stages: const [
        TimerStage(kind: TimerStageKind.sit, minutes: 5),
        TimerStage(kind: TimerStageKind.walk, minutes: 5),
      ],
    );
    expect(find.text('Al terminar · Campana clásica'), findsOne);
    await _tap(tester, find.text('Campanas'));
    expect(find.text('Al empezar'), findsNothing);
    expect(find.text('Sonido: Cuenco tibetano'), findsNothing);
    expect(find.text('Al terminar'), findsOne);
  });
}
