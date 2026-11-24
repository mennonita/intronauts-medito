import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_house_content.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_settings.dart';
import 'package:medito/views/timer/widgets/timer_house_practices.dart';

final l10n = lookupAppLocalizations(const Locale('es'));

List<TimerHousePractice> _practices(List<Map<String, Object?>> raw) =>
    TimerHouseContent.fromJson({'practices': raw}).practices;

// Menos de 300 letras (el límite del servidor), pero más de 3 líneas.
const _longDescription =
    'Una práctica para empezar el día con calma. Nos sentamos con la espalda '
    'derecha y la mirada baja. Contamos las respiraciones del uno al diez y '
    'volvemos a empezar cada vez que nos distraemos. Al final caminamos '
    'unos minutos en silencio.';

Future<void> _pump(
  WidgetTester tester, {
  required List<TimerHousePractice> practices,
  void Function(TimerHousePractice, TimerSettings)? onLoad,
  bool enabled = true,
}) => tester.pumpWidget(
  MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox(
        width: 360,
        child: TimerHousePractices(
          practices: practices,
          enabled: enabled,
          onLoad: onLoad ?? (_, _) {},
        ),
      ),
    ),
  ),
);

void main() {
  final practices = _practices([
    {
      'id': 'zazen',
      'name': 'Zazen',
      'description': _longDescription,
      'mode': 'countdown',
      'minutes': 20,
      'bells': {'startSound': 'cuenco_tibetano'},
    },
    {'id': 'libre', 'name': 'Sentada libre', 'mode': 'stopwatch'},
  ]);

  testWidgets('sin prácticas no muestra nada', (tester) async {
    await _pump(tester, practices: const []);
    expect(find.text(l10n.timerHousePracticesTitle), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('muestra título, nombre, duración y descripción en 3 líneas', (
    tester,
  ) async {
    await _pump(tester, practices: practices);
    expect(find.text(l10n.timerHousePracticesTitle), findsOneWidget);
    expect(find.text('Zazen'), findsOneWidget);
    expect(find.text('20 min · Cuenco tibetano'), findsOneWidget);
    expect(find.text('Sentada libre'), findsOneWidget);
    expect(find.text('Cronómetro · Campana clásica'), findsOneWidget);
    final description = tester.widget<Text>(find.text(_longDescription));
    expect(description.maxLines, 3);
    expect(description.overflow, TextOverflow.ellipsis);
  });

  testWidgets('para el lector de pantalla cada tarjeta es un botón', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, practices: practices);
    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Zazen, 20 min · Cuenco tibetano'),
      ),
      matchesSemantics(
        label: 'Zazen, 20 min · Cuenco tibetano',
        hint: _longDescription,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('tocar una tarjeta entrega sus ajustes', (tester) async {
    final loaded = <(String, TimerSettings)>[];
    await _pump(
      tester,
      practices: practices,
      onLoad: (practice, settings) => loaded.add((practice.id, settings)),
    );
    await tester.tap(find.text('Zazen'));
    await tester.tap(find.text('Sentada libre'));
    expect(loaded.map((item) => item.$1), ['zazen', 'libre']);
    expect(loaded.first.$2.minutes, 20);
    expect(loaded.last.$2.mode, TimerMode.stopwatch);
  });

  testWidgets('desactivada no carga nada', (tester) async {
    final loaded = <String>[];
    await _pump(
      tester,
      practices: practices,
      enabled: false,
      onLoad: (practice, _) => loaded.add(practice.id),
    );
    await tester.tap(find.text('Zazen'));
    expect(loaded, isEmpty);
  });
}
