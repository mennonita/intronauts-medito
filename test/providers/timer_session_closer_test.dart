import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/providers/timer/timer_session_closer.dart';

void main() {
  test('dos cierres simultáneos detienen y registran una sola vez', () async {
    final closer = TimerSessionCloser();
    final playback = Completer<TimerCloseResult>();
    var stops = 0;
    final recorded = <TimerCloseResult>[];
    Future<TimerCloseResult> stop() => closer.close(
      stopPlayback: () {
        stops++;
        expect(closer.isClosing, isTrue);
        return playback.future;
      },
      onStopped: recorded.add,
    );

    final first = stop();
    final second = stop();
    expect(identical(first, second), isTrue);
    expect(stops, 1);
    expect(recorded, isEmpty);

    const result = TimerCloseResult(Duration(seconds: 95));
    playback.complete(result);
    expect(await first, same(result));
    expect(await second, same(result));
    expect(await stop(), same(result));
    expect(recorded, [result]);
    expect(result.recorded, isTrue);
  });

  test('un cierre debajo de un minuto no cuenta como sesión', () {
    expect(const TimerCloseResult(Duration(seconds: 59)).recorded, isFalse);
    expect(const TimerCloseResult(Duration(minutes: 1)).recorded, isTrue);
  });

  test('un cierre sin confirmar ni registra ni impide reintentar', () async {
    final closer = TimerSessionCloser();
    final recorded = <TimerCloseResult>[];
    Future<TimerCloseResult> stop(bool stopped) => closer.close(
      stopPlayback: () async =>
          TimerCloseResult(const Duration(seconds: 95), stopped: stopped),
      onStopped: recorded.add,
    );

    expect((await stop(false)).recorded, isFalse);
    expect(closer.isClosing, isFalse);
    expect(recorded, isEmpty);
    final success = await stop(true);
    expect(success.recorded, isTrue);
    expect(recorded, [success]);
  });
}
