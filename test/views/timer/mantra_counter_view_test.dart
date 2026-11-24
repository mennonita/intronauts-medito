import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_house_content.dart';
import 'package:medito/providers/timer/timer_content_provider.dart';
import 'package:medito/services/timer/mantra_counter_store.dart';
import 'package:medito/services/timer/timer_device_channel.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/timer/mantra/mantra_counter_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

final l10n = lookupAppLocalizations(const Locale('es'));

const _deviceChannel = MethodChannel('intronauts/timer_device');
const _analyticsChannel = MethodChannel(
  'plugins.flutter.io/firebase_analytics',
);
const _tapArea = ValueKey('mantra-tap-area');

/// Contenido de la casa fijo, sin red.
class _FakeContent extends TimerHouseContentNotifier {
  _FakeContent(this.content);

  final TimerHouseContent content;

  @override
  TimerHouseContent build() => content;
}

late int _now;
late List<MethodCall> _deviceCalls;
late List<String> _haptics;
late List<MethodCall> _analyticsCalls;
late List<Map<Object?, Object?>> _announcements;
late MantraCounterStore _store;

int _vibrations() =>
    _deviceCalls.where((c) => c.method == 'vibrateBell').length;

Future<void> _open(
  WidgetTester tester, {
  Map<String, Object> saved = const {},
  TimerHouseContent content = const TimerHouseContent.empty(),
}) async {
  SharedPreferences.setMockInitialValues(saved);
  _store = MantraCounterStore(clock: () => _now);
  MantraCounterStore.instance = _store;
  await tester.pumpWidget(
    PreviewShell(
      locale: const Locale('es'),
      prefs: prefsDark,
      overrides: [
        timerHouseContentProvider.overrideWith(() => _FakeContent(content)),
      ],
      child: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const MantraCounterView(),
                ),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Un toque que cuenta: 200 ms después del anterior.
Future<void> _tap(WidgetTester tester, {Finder? at}) async {
  _now += 200;
  await tester.tap(at ?? find.byKey(_tapArea), warnIfMissed: false);
  await tester.pump();
}

Future<Map<String, dynamic>?> _saved() async {
  final raw = (await SharedPreferences.getInstance()).getString(
    SharedPreferenceConstants.mantraCounter,
  );
  return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _now = 0;
    _deviceCalls = [];
    _haptics = [];
    _analyticsCalls = [];
    _announcements = [];
    TimerDeviceChannel.debugIsAndroid = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_deviceChannel, (call) async {
      _deviceCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        _haptics.add(call.arguments as String);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_analyticsChannel, (call) async {
      _analyticsCalls.add(call);
      return null;
    });
    messenger.setMockDecodedMessageHandler<Object?>(
      SystemChannels.accessibility,
      (message) async {
        if (message is Map && message['type'] == 'announce') {
          _announcements.add(message['data'] as Map<Object?, Object?>);
        }
        return null;
      },
    );
  });

  tearDown(() {
    TimerDeviceChannel.debugIsAndroid = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_deviceChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(_analyticsChannel, null);
    messenger.setMockDecodedMessageHandler<Object?>(
      SystemChannels.accessibility,
      null,
    );
    MantraCounterStore.resetForTesting();
  });

  testWidgets('al abrir: título, pista, nota de privacidad y pantalla '
      'encendida', (tester) async {
    await _open(tester);
    expect(find.text(l10n.mantraCounterTitle), findsOneWidget);
    expect(find.text(l10n.mantraCounterBeads(0, 108)), findsOneWidget);
    expect(find.text(l10n.mantraCounterRounds(0)), findsOneWidget);
    expect(find.text(l10n.mantraCounterHint), findsOneWidget);
    expect(find.text(l10n.mantraPrivacyNote), findsOneWidget);
    expect(find.text(l10n.mantraTotalValue(0)), findsNothing);
    final screen = _deviceCalls.where((c) => c.method == 'keepScreenOn');
    expect(screen.single.arguments, {'on': true});
  });

  testWidgets('la palabra de la casa reemplaza el título', (tester) async {
    await _open(
      tester,
      content: TimerHouseContent.fromJson({
        'words': {'counter': 'Japa'},
      }),
    );
    expect(find.text('Japa'), findsOneWidget);
    expect(find.text(l10n.mantraCounterTitle), findsNothing);
  });

  testWidgets('un toque en cualquier parte cuenta con vibración ligera y la '
      'pista se va', (tester) async {
    await _open(tester);
    await _tap(tester);
    expect(find.text(l10n.mantraCounterBeads(1, 108)), findsOneWidget);
    expect(find.text(l10n.mantraCounterHint), findsNothing);
    expect(_haptics, ['HapticFeedbackType.lightImpact']);

    // Sobre la nota de privacidad y en una esquina también cuenta.
    await _tap(tester, at: find.text(l10n.mantraPrivacyNote));
    final area = tester.getRect(find.byKey(_tapArea));
    _now += 200;
    await tester.tapAt(area.bottomLeft + const Offset(4, -4));
    await tester.pump();
    expect(_store.count, 3);
  });

  testWidgets('doble toque = dos cuentas, salvo a menos de 150 ms', (
    tester,
  ) async {
    await _open(tester);
    await _tap(tester);
    await _tap(tester);
    expect(_store.count, 2);

    _now += 100;
    await tester.tap(find.byKey(_tapArea));
    await tester.pump();
    expect(_store.count, 2);
    expect(find.text(l10n.mantraCounterBeads(2, 108)), findsOneWidget);
  });

  testWidgets('108 toques: una vuelta, una vibración fuerte y un aviso', (
    tester,
  ) async {
    await _open(tester);
    for (var i = 0; i < 107; i++) {
      await _tap(tester);
    }
    expect(_vibrations(), 0);
    await _tap(tester);
    expect(_vibrations(), 1);
    final call = _deviceCalls.singleWhere((c) => c.method == 'vibrateBell');
    expect(call.arguments, {'repeats': 1});
    expect(find.text(l10n.mantraCounterBeads(0, 108)), findsOneWidget);
    expect(find.text(l10n.mantraCounterRounds(1)), findsOneWidget);
    expect(_announcements.single['message'], l10n.mantraCounterRounds(1));
    // La vuelta no lleva además la vibración ligera.
    expect(_haptics, hasLength(107));
  });

  testWidgets('cuentas por vuelta de la organización', (tester) async {
    await _open(
      tester,
      content: TimerHouseContent.fromJson({'beadsPerRound': 21}),
      saved: {
        SharedPreferenceConstants.mantraCounter: jsonEncode({
          'count': 60,
          'rounds': 4,
          'totalEnabled': false,
          'total': 0,
        }),
      },
    );
    // La cuenta guardada se ajusta a la última antes de la vuelta.
    expect(find.text(l10n.mantraCounterBeads(20, 21)), findsOneWidget);
    await _tap(tester);
    expect(find.text(l10n.mantraCounterRounds(5)), findsOneWidget);
    expect(_vibrations(), 1);
  });

  testWidgets('lector de pantalla: acción «Contar» y valor «N de M»', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _open(tester);
    final finder = find.byKey(_tapArea);
    expect(
      tester.getSemantics(finder),
      isSemantics(
        value: l10n.mantraCounterBeads(0, 108),
        hasTapAction: true,
        onTapHint: l10n.mantraCounterTapAction,
      ),
    );
    final node = tester.getSemantics(finder);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pump();
    expect(_store.count, 1);
    expect(
      tester.getSemantics(finder),
      isSemantics(value: l10n.mantraCounterBeads(1, 108)),
    );
    semantics.dispose();
  });

  testWidgets('opciones: total, sumar, borrar y empezar de cero', (
    tester,
  ) async {
    await _open(tester);
    await _tap(tester);
    await _tap(tester);

    await tester.tap(find.byTooltip(l10n.mantraCounterMenu));
    await _settle(tester);
    expect(find.text(l10n.mantraTotalSwitch), findsOneWidget);
    expect(find.text(l10n.mantraTotalAdd), findsNothing);

    await tester.tap(find.text(l10n.mantraTotalSwitch));
    await _settle(tester);
    expect(_store.totalEnabled, isTrue);

    // «Sumar cuentas»: solo dígitos, de 1 a 1 000 000.
    await tester.tap(find.text(l10n.mantraTotalAdd));
    await _settle(tester);
    final field = find.byKey(const ValueKey('mantra-add-field'));
    expect(find.text(l10n.mantraTotalAddHint), findsOneWidget);
    await tester.enterText(field, '5a0-0');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '500');
    await tester.tap(find.text(l10n.mantraTotalAddConfirm));
    await _settle(tester);
    expect(_store.total, 500);
    expect(find.byKey(const ValueKey('mantra-add-field')), findsNothing);

    // «Borrar mi total» pregunta antes; «Cancelar» no borra.
    await tester.tap(find.text(l10n.mantraTotalClear));
    await _settle(tester);
    expect(find.text(l10n.mantraTotalClearConfirm), findsOneWidget);
    await tester.tap(find.text(l10n.timerPresetCancel));
    await _settle(tester);
    expect(_store.total, 500);
    await tester.tap(find.text(l10n.mantraTotalClear));
    await _settle(tester);
    await tester.tap(find.text(l10n.mantraTotalClear).last);
    await _settle(tester);
    expect(_store.total, 0);
    expect(_store.totalEnabled, isFalse);

    // «Empezar de cero» pregunta antes y deja el total.
    await tester.tap(find.text(l10n.mantraCounterReset));
    await _settle(tester);
    expect(find.text(l10n.mantraCounterResetConfirm), findsOneWidget);
    await tester.tap(find.text(l10n.mantraCounterReset).last);
    await _settle(tester);
    expect(_store.count, 0);
    expect(_store.rounds, 0);
  });

  testWidgets('con el total encendido se ve y suma cada cuenta', (
    tester,
  ) async {
    await _open(
      tester,
      saved: {
        SharedPreferenceConstants.mantraCounter: jsonEncode({
          'count': 3,
          'rounds': 0,
          'totalEnabled': true,
          'total': 41,
        }),
      },
    );
    expect(find.text(l10n.mantraTotalValue(41)), findsOneWidget);
    await _tap(tester);
    expect(find.text(l10n.mantraTotalValue(42)), findsOneWidget);
  });

  testWidgets('salir guarda de inmediato y apaga la pantalla encendida', (
    tester,
  ) async {
    await _open(tester);
    await _tap(tester);
    await _tap(tester);
    expect(await _saved(), isNull);

    await tester.tap(find.byTooltip(l10n.goBack));
    await _settle(tester);
    expect(find.byType(MantraCounterView), findsNothing);
    expect((await _saved())?['count'], 2);
    final screen = _deviceCalls
        .where((c) => c.method == 'keepScreenOn')
        .map((c) => c.arguments)
        .toList();
    expect(screen, [
      {'on': true},
      {'on': false},
    ]);
  });

  testWidgets('ir a segundo plano guarda de inmediato', (tester) async {
    await _open(tester);
    await _tap(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect((await _saved())?['count'], 1);
    // De vuelta en primer plano, por los estados permitidos.
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  });

  testWidgets('un cambio de cuenta deja la pantalla abierta en cero', (
    tester,
  ) async {
    await _open(tester);
    await _tap(tester);
    await _tap(tester);
    await MantraCounterStore.clearForAccountChange();
    await tester.pump();
    expect(find.text(l10n.mantraCounterBeads(0, 108)), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(await _saved(), isNull);
  });

  testWidgets('sin analítica en esta pantalla', (tester) async {
    await _open(tester);
    await _tap(tester);
    await tester.tap(find.byTooltip(l10n.mantraCounterMenu));
    await _settle(tester);
    expect(_analyticsCalls, isEmpty);
  });

  test('solo toques sencillos y sin rutas a Salud, estadísticas, servidor '
      'o analítica', () {
    const files = [
      'lib/views/timer/mantra/mantra_counter_view.dart',
      'lib/views/timer/mantra/mantra_total_sheet.dart',
      'lib/services/timer/mantra_counter_store.dart',
    ];
    final view = File(files.first).readAsStringSync();
    expect(view, isNot(contains('onDoubleTap')));
    expect(view, isNot(contains('onLongPress')));
    for (final path in files) {
      final source = File(path).readAsStringSync();
      for (final forbidden in [
        'analytics',
        'Analytics',
        'health',
        'Health',
        'stats',
        'Stats',
        'http',
        'export',
      ]) {
        expect(
          source.contains(RegExp("import '[^']*$forbidden")),
          isFalse,
          reason: '$path importa algo de «$forbidden»',
        );
      }
    }
  });
}
