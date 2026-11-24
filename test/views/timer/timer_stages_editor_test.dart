import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_settings.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/timer/widgets/timer_stages_editor.dart';

final l10n = lookupAppLocalizations(const Locale('es'));

/// Guarda las partes como lo haría la pantalla del temporizador.
class _Harness extends StatefulWidget {
  const _Harness({required this.initial, required this.currentMinutes});

  final List<TimerStage> initial;
  final int currentMinutes;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<TimerStage> stages = widget.initial;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SingleChildScrollView(
      child: TimerStagesEditor(
        stages: stages,
        currentMinutes: widget.currentMinutes,
        onChanged: (next) => setState(() => stages = next),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  List<TimerStage> initial = const [],
  int currentMinutes = 20,
}) async {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    PreviewShell(
      locale: const Locale('es'),
      prefs: prefsDark,
      child: _Harness(initial: initial, currentMinutes: currentMinutes),
    ),
  );
}

List<TimerStage> _stages(WidgetTester tester) =>
    tester.state<_HarnessState>(find.byType(_Harness)).stages;

Finder _button(String tooltip) => find.ancestor(
  of: find.byTooltip(tooltip),
  matching: find.byType(IconButton),
);

TimerStage _sit(int minutes) =>
    TimerStage(kind: TimerStageKind.sit, minutes: minutes);

void main() {
  testWidgets('prender siembra sentado, caminando, sentado', (tester) async {
    await _pump(tester, currentMinutes: 20);
    expect(find.text(l10n.timerStagesTitle), findsOneWidget);
    expect(find.text(l10n.timerStagesDescription), findsOneWidget);

    await tester.tap(find.text(l10n.timerStagesTitle));
    await tester.pump();

    expect(_stages(tester).map((s) => (s.kind, s.minutes)), [
      (TimerStageKind.sit, 20),
      (TimerStageKind.walk, 5),
      (TimerStageKind.sit, 20),
    ]);
    expect(find.text(l10n.timerStagesTotal('45 min')), findsOneWidget);
    expect(find.text(l10n.timerStageSit), findsNWidgets(2));
    expect(find.text(l10n.timerStageWalk), findsOneWidget);
    expect(find.byTooltip(l10n.timerStageRemove), findsNWidgets(3));

    await tester.tap(find.text(l10n.timerStagesTitle));
    await tester.pump();
    expect(_stages(tester), isEmpty);
  });

  testWidgets('sin minutos elegidos usa 20 y respeta el máximo', (
    tester,
  ) async {
    expect(seedTimerStages(0).map((s) => s.minutes), [20, 5, 20]);
    final long = seedTimerStages(200);
    expect(long.map((s) => s.minutes), [147, 5, 147]);
    expect(
      long.fold<int>(0, (sum, s) => sum + s.minutes),
      lessThanOrEqualTo(kMaxTimerMinutes),
    );
  });

  testWidgets('más y menos cambian los minutos dentro del rango', (
    tester,
  ) async {
    await _pump(tester, initial: [_sit(1), _sit(10)]);
    final minus = _button(l10n.timerStageMinus);
    final plus = _button(l10n.timerStagePlus);

    // En 1 minuto no se puede bajar más.
    expect(tester.widget<IconButton>(minus.first).onPressed, isNull);
    await tester.tap(plus.first);
    await tester.pump();
    expect(_stages(tester).first.minutes, 2);
    await tester.tap(minus.last);
    await tester.pump();
    expect(_stages(tester).last.minutes, 9);
    expect(find.text(l10n.timerStagesTotal('11 min')), findsOneWidget);
  });

  testWidgets('con el total en 299 no se puede subir ni agregar', (
    tester,
  ) async {
    await _pump(tester, initial: [_sit(150), _sit(149)]);
    for (final button in tester.widgetList<IconButton>(
      _button(l10n.timerStagePlus),
    )) {
      expect(button.onPressed, isNull);
    }
    final add = tester.widget<TextButton>(
      find.widgetWithText(TextButton, l10n.timerStageAdd),
    );
    expect(add.onPressed, isNull);
  });

  testWidgets('agregar hasta 6, luego avisa el límite; quitar hasta 2', (
    tester,
  ) async {
    await _pump(tester, initial: [_sit(10), _sit(10)]);
    expect(find.byTooltip(l10n.timerStageRemove), findsNothing);

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.widgetWithText(TextButton, l10n.timerStageAdd));
      await tester.pump();
    }
    expect(_stages(tester), hasLength(kMaxTimerStages));
    expect(find.text(l10n.timerStageLimit), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, l10n.timerStageAdd),
          )
          .onPressed,
      isNull,
    );
    expect(find.text(l10n.timerStagesTotal('40 min')), findsOneWidget);

    while (_stages(tester).length > kMinTimerStages) {
      await tester.tap(find.byTooltip(l10n.timerStageRemove).last);
      await tester.pump();
    }
    expect(find.byTooltip(l10n.timerStageRemove), findsNothing);
    expect(find.text(l10n.timerStageLimit), findsNothing);
  });

  testWidgets('el tipo de cada parte se cambia en su lista', (tester) async {
    await _pump(tester, initial: [_sit(10), _sit(10)]);
    await tester.tap(find.text(l10n.timerStageSit).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.timerStageRest).last);
    await tester.pumpAndSettle();
    expect(_stages(tester).last.kind, TimerStageKind.rest);
  });

  testWidgets('cada parte muestra su campana', (tester) async {
    await _pump(
      tester,
      initial: [
        const TimerStage(
          kind: TimerStageKind.sit,
          minutes: 10,
          sound: 'cuenco_tibetano',
        ),
        _sit(10),
      ],
    );
    expect(
      find.text(l10n.bellSoundSelection(l10n.bellSoundTibetanBowl)),
      findsOneWidget,
    );
    expect(
      find.text(l10n.bellSoundSelection(l10n.bellSoundActual)),
      findsOneWidget,
    );
  });

  testWidgets('con letra al doble no hay desbordes', (tester) async {
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PreviewShell(
        locale: const Locale('es'),
        prefs: prefsDark,
        child: MediaQuery.withClampedTextScaling(
          minScaleFactor: 2,
          maxScaleFactor: 2,
          child: _Harness(
            initial: [_sit(120), _sit(10), _sit(10)],
            currentMinutes: 20,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
