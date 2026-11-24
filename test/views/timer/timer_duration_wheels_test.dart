import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/views/timer/widgets/timer_duration_wheels.dart';

Widget _app({
  Key? wheelsKey,
  required int minutes,
  required ValueChanged<int> onChanged,
  double textScale = 1,
  bool disableAnimations = false,
}) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: Center(
          child: SizedBox(
            width: 360,
            child: TimerDurationWheels(
              key: wheelsKey,
              minutes: minutes,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'las acciones accesibles ajustan ambas ruedas dentro de su rango',
    (tester) async {
      final changes = <int>[];
      await tester.pumpWidget(
        _app(minutes: 3 * 60 + 58, onChanged: changes.add),
      );

      final hours = find.semantics.byLabel('Horas: 3');
      final minutes = find.semantics.byLabel('Minutos: 58');
      final hourData = hours.evaluate().single.getSemanticsData();
      expect(hourData.value, '3');
      expect(hourData.increasedValue, '4');
      expect(hourData.decreasedValue, '2');
      expect(find.semantics.byLabel('58'), findsNothing);

      tester.semantics.increase(hours);
      await tester.pump();
      final maxHours = find.semantics.byLabel('Horas: 4');
      expect(
        maxHours.evaluate().single.getSemanticsData().hasAction(
          SemanticsAction.increase,
        ),
        isFalse,
      );
      tester.semantics.increase(minutes);
      await tester.pump();
      final maxMinutes = find.semantics.byLabel('Minutos: 59');
      expect(
        maxMinutes.evaluate().single.getSemanticsData().hasAction(
          SemanticsAction.increase,
        ),
        isFalse,
      );
      tester.semantics.decrease(maxHours);
      await tester.pump();
      tester.semantics.decrease(maxMinutes);
      await tester.pump();

      expect(changes, [298, 299, 239, 238]);

      final key = GlobalKey<TimerDurationWheelsState>();
      await tester.pumpWidget(
        _app(wheelsKey: key, minutes: 0, onChanged: changes.add),
      );
      for (final label in ['Horas: 0', 'Minutos: 0']) {
        final data = find.semantics
            .byLabel(label)
            .evaluate()
            .single
            .getSemanticsData();
        expect(data.hasAction(SemanticsAction.decrease), isFalse);
      }
    },
  );

  testWidgets('letras al doble agrandan las ruedas sin perder la selección', (
    tester,
  ) async {
    final changes = <int>[];
    await tester.pumpWidget(_app(minutes: 127, onChanged: changes.add));
    final wheel = find.byType(ListWheelScrollView);
    final originalExtent = tester
        .widget<ListWheelScrollView>(wheel.first)
        .itemExtent;

    await tester.pumpWidget(
      _app(minutes: 127, textScale: 2, onChanged: changes.add),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<ListWheelScrollView>(wheel.first).itemExtent,
      closeTo(originalExtent * 1.3, 0.01),
    );
    final digit = tester.widget<Text>(find.text('07'));
    expect(digit.textScaler!.scale(64), closeTo(64 * 1.3, 0.01));
    final controllers = tester
        .widgetList<ListWheelScrollView>(wheel)
        .map((view) => view.controller! as FixedExtentScrollController)
        .toList();
    expect(controllers[0].selectedItem, 2);
    expect(controllers[1].selectedItem % 60, 7);
    expect(changes, isEmpty);
  });

  testWidgets('con movimiento reducido la duración cambia sin animarse', (
    tester,
  ) async {
    final key = GlobalKey<TimerDurationWheelsState>();
    final changes = <int>[];
    await tester.pumpWidget(
      _app(
        wheelsKey: key,
        minutes: 58,
        onChanged: changes.add,
        disableAnimations: true,
      ),
    );

    await key.currentState!.animateTo(63);
    final controllers = tester
        .widgetList<ListWheelScrollView>(find.byType(ListWheelScrollView))
        .map((view) => view.controller! as FixedExtentScrollController)
        .toList();
    expect(controllers[0].selectedItem, 1);
    expect(controllers[1].selectedItem % 60, 3);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(changes, isEmpty);
  });
}
