import 'dart:math';

import 'package:medito/models/player/playback_request.dart';

import 'timer_session.dart';

/// Calcula cada fase a partir de la posición del audio, en milisegundos.
class TimerTimeline {
  const TimerTimeline({
    required this.prepMs,
    required this.plannedMs,
    required this.extraTime,
    required this.isStopwatch,
    this.stageDurationsMs = const [],
  });

  factory TimerTimeline.fromRequest(PlaybackRequest request) => TimerTimeline(
    prepMs: request.timerPrepMs,
    plannedMs: request.plannedDurationMs,
    extraTime: request.hasExtraTime,
    isStopwatch: request.timerMode == TimerMode.stopwatch,
    stageDurationsMs: request.timerStageDurationsMs,
  );

  final int prepMs;
  final int plannedMs;
  final bool extraTime;
  final bool isStopwatch;
  final List<int> stageDurationsMs;

  /// Indica si sigue la preparación.
  bool inPrep(int positionMs) => positionMs < prepMs;

  /// Tiempo que falta para terminar la preparación.
  int prepRemainingMs(int positionMs) => max(0, prepMs - positionMs);

  /// Posición desde el inicio de la sesión, después de la preparación.
  int sessionPositionMs(int positionMs) => max(0, positionMs - prepMs);

  /// Tiempo meditado, con el límite del modo y del tiempo extra.
  int elapsedMs(int positionMs) {
    final fiveHoursMs = kStopwatchMaxDuration.inMilliseconds;
    final limit = isStopwatch
        ? fiveHoursMs
        : plannedMs + (extraTime ? fiveHoursMs : 0);
    return min(sessionPositionMs(positionMs), limit);
  }

  /// Tiempo que falta de la duración planeada; el cronómetro no lleva cuenta regresiva.
  int? remainingMs(int positionMs) =>
      isStopwatch ? null : max(0, plannedMs - sessionPositionMs(positionMs));

  /// Tiempo hasta la campana final de la cuenta regresiva, incluida la preparación.
  int? untilEndCueMs(int positionMs) =>
      isStopwatch ? null : max(0, prepMs + plannedMs - positionMs);

  /// Indica si la sesión llegó al tiempo extra.
  bool isExtraTime(int positionMs) =>
      extraTime && sessionPositionMs(positionMs) >= plannedMs;

  /// Índice desde cero en una sesión con etapas; conserva el último al terminar.
  int? stageIndexAt(int positionMs) {
    if (stageDurationsMs.length < 2) return null;
    final position = sessionPositionMs(positionMs);
    var stageEnd = 0;
    for (var index = 0; index < stageDurationsMs.length; index++) {
      stageEnd += stageDurationsMs[index];
      if (position < stageEnd) return index;
    }
    return stageDurationsMs.length - 1;
  }

  /// Tiempo que falta para terminar la etapa actual.
  int? stageRemainingMs(int positionMs) {
    final index = stageIndexAt(positionMs);
    if (index == null) return null;
    final stageEnd = stageDurationsMs
        .take(index + 1)
        .fold(0, (end, duration) => end + duration);
    return max(0, stageEnd - sessionPositionMs(positionMs));
  }
}
