import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_timeline.dart';

void main() {
  const countdown = TimerTimeline(
    prepMs: 10000,
    plannedMs: 120000,
    extraTime: false,
    isStopwatch: false,
  );

  test('la preparación precede al tiempo meditado', () {
    expect(countdown.inPrep(0), isTrue);
    expect(countdown.inPrep(9999), isTrue);
    expect(countdown.inPrep(10000), isFalse);
    expect(countdown.prepRemainingMs(0), 10000);
    expect(countdown.prepRemainingMs(20000), 0);
    expect(countdown.sessionPositionMs(5000), 0);
    expect(countdown.sessionPositionMs(15000), 5000);
    expect(countdown.elapsedMs(9999), 0);
    expect(countdown.remainingMs(5000), 120000);
    expect(countdown.remainingMs(15000), 115000);
  });

  test('la campana incluye la preparación y la cola no cuenta', () {
    expect(countdown.untilEndCueMs(0), 130000);
    expect(countdown.untilEndCueMs(129999), 1);
    expect(countdown.untilEndCueMs(130000), 0);
    expect(countdown.untilEndCueMs(140000), 0);
    expect(countdown.elapsedMs(140000), 120000);
    expect(countdown.remainingMs(140000), 0);
    expect(countdown.isExtraTime(140000), isFalse);
  });

  test('el tiempo extra empieza al llegar a la campana y tiene un límite', () {
    const extra = TimerTimeline(
      prepMs: 10000,
      plannedMs: 120000,
      extraTime: true,
      isStopwatch: false,
    );
    final fiveHoursMs = kStopwatchMaxDuration.inMilliseconds;
    expect(extra.isExtraTime(129999), isFalse);
    expect(extra.isExtraTime(130000), isTrue);
    expect(extra.elapsedMs(140000), 130000);
    expect(extra.remainingMs(140000), 0);
    expect(extra.elapsedMs(140000 + fiveHoursMs), 120000 + fiveHoursMs);
  });

  test('el cronómetro no tiene cuenta regresiva y mide hasta cinco horas', () {
    const stopwatch = TimerTimeline(
      prepMs: 0,
      plannedMs: 18000000,
      extraTime: false,
      isStopwatch: true,
    );
    expect(stopwatch.remainingMs(0), isNull);
    expect(stopwatch.untilEndCueMs(0), isNull);
    expect(stopwatch.elapsedMs(5000), 5000);
    expect(stopwatch.elapsedMs(18010000), 18000000);
  });

  test('lee las etapas de la solicitud y descuenta la preparación', () {
    final request =
        timerPlaybackRequest(
          mode: TimerMode.countdown,
          duration: const Duration(minutes: 3),
          filePath: '/tmp/timer.wav',
          title: '',
        ).copyWith(
          duration: 195000,
          timerPrepMs: 10000,
          timerStageDurationsMs: [60000, 60000, 60000],
        );
    final timeline = TimerTimeline.fromRequest(request);
    expect(timeline.extraTime, isFalse);
    expect(timeline.elapsedMs(195000), 180000);
    expect(timeline.stageIndexAt(0), 0);
    expect(timeline.stageRemainingMs(0), 60000);
    expect(timeline.stageIndexAt(69999), 0);
    expect(timeline.stageRemainingMs(69999), 1);
    expect(timeline.stageIndexAt(70000), 1);
    expect(timeline.stageRemainingMs(70000), 60000);
    expect(timeline.stageRemainingMs(100000), 30000);
    expect(timeline.stageIndexAt(130000), 2);
    expect(timeline.stageRemainingMs(130000), 60000);
    expect(timeline.stageIndexAt(190000), 2);
    expect(timeline.stageRemainingMs(195000), 0);
    expect(
      TimerTimeline.fromRequest(
        request.copyWith(timerExtraTime: true),
      ).extraTime,
      isTrue,
    );
  });

  test('devuelve null cuando hay menos de dos etapas', () {
    const singleStage = TimerTimeline(
      prepMs: 10000,
      plannedMs: 120000,
      extraTime: false,
      isStopwatch: false,
      stageDurationsMs: [120000],
    );
    expect(countdown.stageIndexAt(10000), isNull);
    expect(countdown.stageRemainingMs(10000), isNull);
    expect(singleStage.stageIndexAt(10000), isNull);
    expect(singleStage.stageRemainingMs(10000), isNull);
  });
}
