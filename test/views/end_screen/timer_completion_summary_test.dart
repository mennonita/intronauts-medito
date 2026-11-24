import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/http/http_constants.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/events/donation/donation_page_model.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/donation/donation_page_provider.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/providers/review_service_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/providers/timer/timer_content_provider.dart';
import 'package:medito/repositories/timer/timer_content_repository.dart';
import 'package:medito/repositories/track/track_repository.dart';
import 'package:medito/services/review_service.dart';
import 'package:medito/utils/health_sync_queue.dart';
import 'package:medito/views/end_screen/end_screen_view.dart';
import 'package:medito/views/end_screen/timer_completion_summary.dart';
import 'package:medito/views/end_screen/timer_health_card.dart';
import 'package:medito/views/end_screen/timer_note_sheet.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/timer/timer_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/firebase_analytics_test_helper.dart';
import '../../helpers/firebase_test_helper.dart';

const _locale = Locale('es');
final _l10n = lookupAppLocalizations(_locale);
const _runId = '0123456789abcdef0123456789abcdef';
const _account = '00000000-0000-4000-8000-000000000001';
final _request = timerPlaybackRequest(
  mode: TimerMode.countdown,
  duration: const Duration(minutes: 20),
  filePath: '/tmp/timer.wav',
  title: 'Temporizador',
  runId: _runId,
);

class _Repository extends Fake implements TimerContentRepository {
  final requests = <({String sessionId, String note})>[];
  final answers = <Completer<TimerNoteSaveResult>>[];

  @override
  Future<TimerNoteSaveResult> submitNote({
    required String sessionId,
    required String note,
  }) {
    requests.add((sessionId: sessionId, note: note));
    final answer = Completer<TimerNoteSaveResult>();
    answers.add(answer);
    return answer.future;
  }
}

class _Access implements TimerHealthAccess {
  bool available = true;
  bool requestGranted = false;
  bool writeGranted = false;
  int authorizationRequests = 0;
  int writeChecks = 0;
  void Function()? onWriteCheck;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> requestAuthorization() async {
    authorizationRequests++;
    return requestGranted;
  }

  @override
  Future<bool> hasWriteAccess() async {
    writeChecks++;
    onWriteCheck?.call();
    return writeGranted;
  }
}

class _Stats extends StatsNotifier {
  @override
  Future<LocalAllStats> build() async => LocalAllStats.empty();
}

class _Review implements ReviewService {
  @override
  Future<void> checkAndRequestReview() async {}
}

class _Player extends PlayerProvider {
  @override
  PlaybackRequest? build() => null;

  @override
  bool get hasActiveSession => false;
}

class _Tracks extends Fake implements TrackRepository {
  @override
  Future<Never> fetchTrack(String trackId) async => throw Exception('sin red');
}

Future<void> _pumpSummary(
  WidgetTester tester, {
  PlaybackRequest? request,
  Duration? elapsed,
  Future<String?>? closingText,
  TimerContentRepository? repository,
}) async {
  await tester.pumpWidget(
    PreviewShell(
      prefs: prefsDark,
      locale: _locale,
      overrides: [
        timerClosingTextProvider.overrideWith(
          (_) async => closingText == null ? null : await closingText,
        ),
        if (repository != null)
          timerContentRepositoryProvider.overrideWithValue(repository),
        playerProvider.overrideWith(_Player.new),
        trackRepositoryProvider.overrideWithValue(_Tracks()),
      ],
      child: Scaffold(
        body: TimerCompletionSummary(
          request: request ?? _request,
          timerElapsed: elapsed,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpHealth(
  WidgetTester tester,
  SharedPreferences prefs,
  TimerHealthAccess access,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        timerHealthAccessProvider.overrideWithValue(access),
      ],
      child: const MaterialApp(
        locale: _locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: TimerHealthCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _queueSession() => HealthSyncQueue.add(
  const HealthSyncEntry(
    key: _runId,
    startMs: 1000,
    endMs: 61000,
    accountId: _account,
    awaitingConsent: true,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (_) async => 0,
    );
    await FirebaseTestHelper.initializeFirebaseForTest();
    FirebaseAnalyticsTestHelper.setupFirebaseAnalyticsMocks();
  });

  testWidgets('muestra el tiempo meditado y el cierre del servidor al llegar', (
    tester,
  ) async {
    final closingText = Completer<String?>();
    await _pumpSummary(
      tester,
      elapsed: const Duration(minutes: 9),
      closingText: closingText.future,
    );
    expect(find.text('Meditaste 9 min'), findsOneWidget);
    expect(find.text(_l10n.timerClosingFallback), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    closingText.complete('Que estés bien.');
    await tester.pumpAndSettle();
    expect(find.text('Que estés bien.'), findsOneWidget);
    expect(find.text(_l10n.timerClosingFallback), findsNothing);
  });

  testWidgets('usa la duración planeada y omite la nota sin id de sesión', (
    tester,
  ) async {
    await _pumpSummary(tester, request: _request.copyWith(timerRunId: ''));
    expect(find.text('Meditaste 20 min'), findsOneWidget);
    expect(find.text(_l10n.timerClosingFallback), findsOneWidget);
    expect(find.text(_l10n.timerSaveNote), findsNothing);
  });

  testWidgets('Repetir reemplaza el resumen y pide los últimos ajustes', (
    tester,
  ) async {
    await _pumpSummary(tester);
    final note = find.widgetWithText(OutlinedButton, _l10n.timerSaveNote);
    final repeat = find.widgetWithText(FilledButton, _l10n.timerRepeat);
    expect(tester.getSize(note).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(repeat).height, greaterThanOrEqualTo(48));

    await tester.tap(repeat);
    await tester.pumpAndSettle();
    final timer = tester.widget<TimerView>(find.byType(TimerView));
    expect(timer.launch?.last, isTrue);
    expect(timer.source, AnalyticsEventConstants.sourceEndScreen);
    expect(
      find.byType(TimerCompletionSummary, skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets('deja la nota confirmada en solo lectura al volver a abrir', (
    tester,
  ) async {
    final repository = _Repository();
    await _pumpSummary(tester, repository: repository);
    await tester.tap(find.text(_l10n.timerSaveNote));
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    final save = find.widgetWithText(FilledButton, _l10n.timerPresetSave);
    final cancel = find.widgetWithText(TextButton, _l10n.timerPresetCancel);
    expect(tester.widget<TextField>(field).autofocus, isTrue);
    expect(tester.widget<TextField>(field).maxLength, 2000);
    expect(find.text(_l10n.timerNoteHint), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(field, '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(field, 'Respiré con calma.');
    await tester.pump();
    await tester.tap(save);
    await tester.pump();

    expect(repository.requests, [
      (sessionId: _runId, note: 'Respiré con calma.'),
    ]);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(tester.widget<TextButton>(cancel).onPressed, isNull);
    repository.answers.single.complete(TimerNoteSaveResult.saved);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).readOnly, isTrue);
    expect(save, findsNothing);
    expect(find.text(_l10n.timerNoteSaved), findsOneWidget);
    await tester.tap(find.text(_l10n.timerDone));
    await tester.pumpAndSettle();
    expect(find.byType(TimerNoteSheet), findsNothing);
    expect(find.text(_l10n.timerNoteSaved), findsOneWidget);

    await tester.tap(find.text(_l10n.timerSaveNote));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).readOnly, isTrue);
    expect(find.text('Respiré con calma.'), findsOneWidget);
    expect(save, findsNothing);
    expect(repository.requests, hasLength(1));
  });

  testWidgets('un error conserva la nota y el reintento usa el mismo id', (
    tester,
  ) async {
    final repository = _Repository();
    await _pumpSummary(tester, repository: repository);
    await tester.tap(find.text(_l10n.timerSaveNote));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    final save = find.widgetWithText(FilledButton, _l10n.timerPresetSave);
    await tester.enterText(field, 'Mi primera nota.');
    await tester.pump();
    await tester.tap(save);
    repository.answers.single.complete(TimerNoteSaveResult.failed);
    await tester.pumpAndSettle();

    expect(find.text(_l10n.timerNoteError), findsOneWidget);
    expect(find.text('Mi primera nota.'), findsOneWidget);
    await tester.enterText(field, 'Mi nota editada.');
    await tester.pump();
    await tester.tap(save);
    expect(repository.requests, [
      (sessionId: _runId, note: 'Mi primera nota.'),
      (sessionId: _runId, note: 'Mi nota editada.'),
    ]);
    repository.answers.last.complete(TimerNoteSaveResult.saved);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).readOnly, isTrue);
  });

  for (final result in [
    TimerNoteSaveResult.conflict,
    TimerNoteSaveResult.unconfirmed,
  ]) {
    testWidgets('conserva el borrador sin confirmar el guardado ($result)', (
      tester,
    ) async {
      final repository = _Repository();
      await _pumpSummary(tester, repository: repository);
      await tester.tap(find.text(_l10n.timerSaveNote));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      await tester.enterText(field, 'Mi borrador.');
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, _l10n.timerPresetSave),
      );
      repository.answers.single.complete(result);
      await tester.pumpAndSettle();

      expect(find.text('Mi borrador.'), findsOneWidget);
      expect(find.text(_l10n.timerNoteError), findsOneWidget);
      expect(find.text(_l10n.timerNoteSaved), findsNothing);
      expect(
        tester.widget<TextField>(field).readOnly,
        result == TimerNoteSaveResult.conflict,
      );
    });
  }

  group('Salud', () {
    late SharedPreferences prefs;
    late _Access access;
    late List<HealthSyncEntry> writes;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        SharedPreferenceConstants.serverUserId: _account,
      });
      prefs = await SharedPreferences.getInstance();
      access = _Access();
      writes = [];
      HealthSyncQueue.dependencies = HealthSyncDependencies(
        prefs: () async => prefs,
        ready: () async {},
        currentAccountId: (_) => _account,
        isIOS: false,
        pendingRuns: () async => const [],
        write: (entry) async {
          writes.add(entry);
          return true;
        },
        markSynced: (_) async {},
      );
    });
    tearDown(HealthSyncQueue.resetForTesting);

    testWidgets('la tarjeta se oculta si Salud no está disponible', (
      tester,
    ) async {
      access.available = false;
      await _pumpHealth(tester, prefs, access);
      expect(find.text(_l10n.timerHealthCardTitle), findsNothing);
      expect(access.authorizationRequests, 0);
    });

    testWidgets('la tarjeta se oculta si la cuenta ya dio permiso', (
      tester,
    ) async {
      await HealthSyncQueue.setConsent(true);
      await _pumpHealth(tester, prefs, access);
      expect(find.text(_l10n.timerHealthCardTitle), findsNothing);
      expect(access.authorizationRequests, 0);
    });

    testWidgets('Ahora no guarda la decisión y quita la sesión de la cola', (
      tester,
    ) async {
      await _queueSession();
      await _pumpHealth(tester, prefs, access);
      expect(find.text(_l10n.timerHealthCardTitle), findsOneWidget);
      await tester.tap(find.text(_l10n.timerHealthCardLater));
      await tester.pumpAndSettle();
      expect(
        prefs.getBool(SharedPreferenceConstants.healthPromptDismissed),
        isTrue,
      );
      expect(
        prefs.getString(SharedPreferenceConstants.pendingHealthSessions),
        isNull,
      );
      expect(find.text(_l10n.timerHealthCardTitle), findsNothing);
      expect(writes, isEmpty);
      expect(access.authorizationRequests, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpHealth(tester, prefs, access);
      expect(find.text(_l10n.timerHealthCardTitle), findsNothing);
    });

    for (final requestGranted in [false, true]) {
      testWidgets(
        'Activar sin permiso de escritura deja la tarjeta visible ($requestGranted)',
        (tester) async {
          access.requestGranted = requestGranted;
          await _queueSession();
          await _pumpHealth(tester, prefs, access);

          await tester.tap(find.text(_l10n.timerHealthCardEnable));
          await tester.pumpAndSettle();
          expect(access.authorizationRequests, 1);
          expect(access.writeChecks, requestGranted ? 1 : 0);
          expect(HealthSyncQueue.hasConsent(prefs), isFalse);
          expect(writes, isEmpty);
          expect(find.text(_l10n.timerHealthCardTitle), findsOneWidget);
        },
      );
    }

    testWidgets('Activar confirma el permiso y envía la sesión pendiente', (
      tester,
    ) async {
      access
        ..requestGranted = true
        ..writeGranted = true
        ..onWriteCheck = () =>
            expect(HealthSyncQueue.hasConsent(prefs), isFalse);
      await _queueSession();
      await _pumpHealth(tester, prefs, access);
      expect(access.authorizationRequests, 0);
      expect(writes, isEmpty);

      await tester.tap(find.text(_l10n.timerHealthCardEnable));
      await tester.pumpAndSettle();
      expect(access.authorizationRequests, 1);
      expect(access.writeChecks, 1);
      expect(HealthSyncQueue.hasConsent(prefs), isTrue);
      expect(writes.single.key, _runId);
      expect(find.text(_l10n.timerHealthCardTitle), findsNothing);
    });
  });

  for (final isTimer in [false, true]) {
    testWidgets('la pantalla final respeta el movimiento reducido ($isTimer)', (
      tester,
    ) async {
      await tester.pumpWidget(
        PreviewShell(
          prefs: prefsDark,
          locale: _locale,
          overrides: [
            timerClosingTextProvider.overrideWith((_) async => null),
            statsProvider.overrideWith(_Stats.new),
            reviewServiceProvider.overrideWithValue(_Review()),
            fetchDonationPageProvider.overrideWith(
              (_) async =>
                  const DonationPageModel(title: '', text: '', buttons: []),
            ),
          ],
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: EndScreenView(
                request: isTimer
                    ? _request
                    : _request.copyWith(trackId: 'guiada'),
              ),
            ),
          ),
        ),
      );

      final end = find.byType(EndScreenView);
      final slides = tester.widgetList<SlideTransition>(
        find.descendant(of: end, matching: find.byType(SlideTransition)),
      );
      expect(slides.length, donationsEnabled ? 3 : 2);
      for (final slide in slides) {
        expect(slide.position.status, AnimationStatus.completed);
        expect(slide.position.value, Offset.zero);
      }
      expect(
        find.byType(TimerCompletionSummary),
        isTimer ? findsOneWidget : findsNothing,
      );
      await tester.pumpAndSettle();
    });
  }
}
