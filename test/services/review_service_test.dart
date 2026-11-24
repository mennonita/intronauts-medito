import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/services/review_service.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Stats extends Mock implements StatsManager {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const timer = SitOutcome(
    isTimer: true,
    naturalEnd: true,
    endCueRang: true,
    pausedMs: 120000,
  );
  const earlyEnd = SitOutcome(
    isTimer: true,
    naturalEnd: false,
    endCueRang: false,
    pausedMs: 0,
  );
  const unconfirmedBell = SitOutcome(
    isTimer: true,
    naturalEnd: true,
    endCueRang: false,
    pausedMs: 0,
  );
  const longPause = SitOutcome(
    isTimer: true,
    naturalEnd: true,
    endCueRang: true,
    pausedMs: 121000,
  );
  const guided = SitOutcome(
    isTimer: false,
    naturalEnd: true,
    endCueRang: false,
    pausedMs: 0,
  );
  const guidedStop = SitOutcome(
    isTimer: false,
    naturalEnd: false,
    endCueRang: false,
    pausedMs: 0,
  );

  group('SitOutcome.isClean', () {
    for (final (name, outcome, clean) in [
      ('timer with exactly two minutes paused', timer, true),
      ('early manual timer close', earlyEnd, false),
      ('timer without an end bell', unconfirmedBell, false),
      ('end bell player stayed idle', unconfirmedBell, false),
      ('stopwatch reached five hours and started its end bell', timer, true),
      ('timer paused for 121 seconds', longPause, false),
      ('guided track completed naturally', guided, true),
      ('user stopped the guided track', guidedStop, false),
      (
        'user closed after the timer end bell started',
        const SitOutcome(
          isTimer: true,
          naturalEnd: false,
          endCueRang: true,
          pausedMs: 0,
        ),
        true,
      ),
      (
        'guided track paused for 121 seconds',
        const SitOutcome(
          isTimer: false,
          naturalEnd: true,
          endCueRang: false,
          pausedMs: 121000,
        ),
        false,
      ),
    ]) {
      test(name, () => expect(outcome.isClean, clean));
    }
  });

  group('ReviewService.maybeRequestAfterSit', () {
    const key = 'last_review_request_timestamp';
    const channel = MethodChannel('dev.britannio.in_app_review');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late _Stats stats;
    late ReviewService service;
    late List<String> calls;
    late bool available;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      stats = _Stats();
      when(() => stats.returns).thenAnswer((_) async => 10);
      service = ReviewService(statsManager: stats);
      calls = [];
      available = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'isAvailable' ? available : null;
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('skips missing and unclean outcomes', () async {
      await service.maybeRequestAfterSit(null);
      await service.maybeRequestAfterSit(earlyEnd);
      await service.maybeRequestAfterSit(longPause);
      expect(calls, isEmpty);
      verifyNever(() => stats.returns);
    });

    test('skips a clean sit before ten returns', () async {
      when(() => stats.returns).thenAnswer((_) async => 9);
      await service.maybeRequestAfterSit(timer);
      expect(calls, isEmpty);
    });

    test('skips a clean sit after an 89-day wait', () async {
      final prefs = await SharedPreferences.getInstance();
      final previous = DateTime.now()
          .subtract(const Duration(days: 89))
          .millisecondsSinceEpoch;
      await prefs.setInt(key, previous);
      await service.maybeRequestAfterSit(timer);
      expect(calls, ['isAvailable']);
      expect(prefs.getInt(key), previous);
    });

    test('skips a clean sit when the system prompt is unavailable', () async {
      available = false;
      await service.maybeRequestAfterSit(timer);
      expect(calls, ['isAvailable']);
      expect((await SharedPreferences.getInstance()).getInt(key), isNull);
    });

    test('requests once after 90 days and saves the timestamp', () async {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      await prefs.setInt(
        key,
        now.subtract(const Duration(days: 90)).millisecondsSinceEpoch,
      );
      await service.maybeRequestAfterSit(guided);
      await service.maybeRequestAfterSit(timer);

      expect(calls.where((method) => method == 'requestReview'), hasLength(1));
      expect(
        prefs.getInt(key),
        inInclusiveRange(
          now.millisecondsSinceEpoch,
          DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  });
}
