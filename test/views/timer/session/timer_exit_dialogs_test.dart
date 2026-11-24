import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_timeline.dart';
import 'package:medito/views/timer/session/timer_exit_dialogs.dart';

const _min = 60000;

TimerTimeline _countdown({bool extraTime = false, int prepMs = 0}) =>
    TimerTimeline(
      prepMs: prepMs,
      plannedMs: 20 * _min,
      extraTime: extraTime,
      isStopwatch: false,
    );

const _stopwatch = TimerTimeline(
  prepMs: 0,
  plannedMs: 5 * 60 * _min,
  extraTime: false,
  isStopwatch: true,
);

Widget _host(Future<void> Function(BuildContext) open) => MaterialApp(
  locale: const Locale('es'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => open(context),
        child: const Text('abrir'),
      ),
    ),
  ),
);

void main() {
  group('timerEndNeedsConfirmation', () {
    test('cuenta regresiva con un minuto o más por delante pregunta', () {
      expect(timerEndNeedsConfirmation(_countdown(), 5 * _min), isTrue);
      expect(timerEndNeedsConfirmation(_countdown(), 19 * _min), isTrue);
      expect(timerEndNeedsConfirmation(_countdown(), 19 * _min + 1), isFalse);
    });

    test('menos de un minuto meditado siempre pregunta', () {
      expect(timerEndNeedsConfirmation(_countdown(), 30000), isTrue);
      expect(timerEndNeedsConfirmation(_stopwatch, 59999), isTrue);
      // La preparación no cuenta como meditado.
      expect(
        timerEndNeedsConfirmation(_countdown(prepMs: 60000), 90000),
        isTrue,
      );
    });

    test('cronómetro y tiempo extra con un minuto o más terminan directo', () {
      expect(timerEndNeedsConfirmation(_stopwatch, _min), isFalse);
      expect(timerEndNeedsConfirmation(_stopwatch, 45 * _min), isFalse);
      expect(
        timerEndNeedsConfirmation(_countdown(extraTime: true), 21 * _min),
        isFalse,
      );
      // Antes del tiempo extra sigue siendo una cuenta regresiva.
      expect(
        timerEndNeedsConfirmation(_countdown(extraTime: true), 10 * _min),
        isTrue,
      );
    });
  });

  testWidgets(
    'salir ofrece seguir, salir sin guardar y guardar, en ese orden',
    (tester) async {
      TimerExitChoice? choice;
      await tester.pumpWidget(
        _host((context) async {
          choice = await showTimerExitDialog(
            context,
            elapsedMs: 12 * _min + 30000,
          );
        }),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(find.text('¿Salir de la sesión?'), findsOneWidget);
      expect(find.text('Llevas 12 min. ¿Quieres guardarlos?'), findsOneWidget);
      final keep = tester.getCenter(find.text('Seguir meditando'));
      final discard = tester.getCenter(find.text('Salir sin guardar'));
      final save = find.widgetWithText(FilledButton, 'Guardar y salir');
      expect(save, findsOneWidget);
      // En fila o apiladas (si no caben), el orden de lectura es el mismo.
      bool before(Offset a, Offset b) =>
          a.dy < b.dy - 1 || ((a.dy - b.dy).abs() <= 1 && a.dx < b.dx);
      expect(before(keep, discard), isTrue);
      expect(before(discard, tester.getCenter(save)), isTrue);

      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(choice, TimerExitChoice.saveAndExit);

      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salir sin guardar'));
      await tester.pumpAndSettle();
      expect(choice, TimerExitChoice.exitWithoutSaving);

      // Tocar fuera del diálogo es seguir meditando.
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(choice, TimerExitChoice.keepMeditating);
    },
  );

  testWidgets('terminar avisa de la sesión corta o dice lo que llevas', (
    tester,
  ) async {
    bool? confirmed;
    var elapsed = 30000;
    await tester.pumpWidget(
      _host((context) async {
        confirmed = await showTimerEndDialog(context, elapsedMs: elapsed);
      }),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.text('¿Terminar la sesión?'), findsOneWidget);
    expect(
      find.text(
        'Llevas menos de un minuto. Las sesiones de menos de un minuto no se guardan.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Seguir meditando'));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);

    elapsed = 7 * _min + 59000;
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.text('Llevas 7 min.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Terminar'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });
}
