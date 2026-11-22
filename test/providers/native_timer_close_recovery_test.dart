import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/providers/timer/native_timer_close_recovery.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final closedAt = DateTime(2026, 11, 22, 0, 1).millisecondsSinceEpoch;
  final completion = CompletionData(
    trackId: 'timer-98',
    duration: 98000,
    fileId: 'timer-countdown-60000',
    timestamp: closedAt,
    timerEnded: TimerEndedData(
      positionMs: 98742,
      mode: 'countdown',
      elapsedSeconds: 98,
      recorded: true,
    ),
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'una entrega simultánea y otro motor reconocen el mismo cierre',
    () async {
      final gate = Completer<bool>();
      final events = <Map<String, Object>>[];
      var writes = 0;
      NativeTimerCloseRecovery engine() => NativeTimerCloseRecovery(
        record: (payload) {
          writes++;
          expect(payload.values, containsAll(['timer-98', 98000, closedAt]));
          return gate.future;
        },
        logEnded: (parameters) async => events.add(parameters),
      );

      final firstEngine = engine();
      final first = firstEngine.handle(completion);
      final retry = firstEngine.handle(completion);
      expect(identical(first, retry), isTrue);

      gate.complete(true);
      expect(await first, isTrue);
      expect(await engine().handle(completion), isTrue);
      expect(writes, 1);
      expect(events.single, {
        'timer_mode': 'countdown',
        'elapsed_seconds': 98,
        'recorded': 1,
      });
    },
  );

  test('un cierre guardado antes del acuse no duplica los minutos', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      SharedPreferenceConstants.localAllStatsKey,
      jsonEncode(
        LocalAllStats.empty()
            .copyWith(
              audioCompleted: [
                LocalAudioCompleted(
                  id: 'timer-98',
                  timestamp: closedAt - 98000,
                ),
              ],
            )
            .toJson(),
      ),
    );
    var events = 0;
    final recovery = NativeTimerCloseRecovery(
      record: (_) async => fail('El historial ya contiene la sesión'),
      logEnded: (_) async => events++,
    );
    expect(await recovery.handle(completion), isTrue);
    expect(events, 1);
  });

  test('un cierre corto emite timer_ended sin registrar minutos', () async {
    final short = CompletionData(
      trackId: 'timer-32',
      duration: 32000,
      fileId: 'timer-stopwatch-0',
      timestamp: closedAt,
      timerEnded: TimerEndedData(
        positionMs: 32500,
        mode: 'stopwatch',
        elapsedSeconds: 32,
        recorded: false,
      ),
    );
    final recovery = NativeTimerCloseRecovery(
      record: (_) async => fail('La sesión dura menos de un minuto'),
      logEnded: (params) async => expect(params['recorded'], 0),
    );
    expect(await recovery.handle(short), isTrue);
  });
}
