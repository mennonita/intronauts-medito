import 'dart:math';

import 'timer_session.dart';

const timerIntervalMinutes = [0, 1, 2, 3, 5, 10, 15, 20, 30];
const timerMaxRandomBells = 10;
const timerBellSpacingMs = 8000;

class TimerBellSettings {
  const TimerBellSettings({
    this.start = true,
    this.end = true,
    this.intervalMinutes = 0,
    this.randomCount = 0,
  });

  final bool start;
  final bool end;
  final int intervalMinutes;
  final int randomCount;

  TimerBellSettings copyWith({
    bool? start,
    bool? end,
    int? intervalMinutes,
    int? randomCount,
  }) => TimerBellSettings(
    start: start ?? this.start,
    end: end ?? this.end,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    randomCount: randomCount ?? this.randomCount,
  );

  Map<String, Object> toJson() => {
    'start': start,
    'end': end,
    'intervalMinutes': intervalMinutes,
    'randomCount': randomCount,
  };

  factory TimerBellSettings.fromJson(Map<String, Object?> json) {
    final start = json['start'] as bool;
    final end = json['end'] as bool;
    final interval = json['intervalMinutes'] as int;
    final random = json['randomCount'] as int;
    if (!timerIntervalMinutes.contains(interval) ||
        random < 0 ||
        random > timerMaxRandomBells) {
      throw const FormatException('Ajustes de campanas fuera de rango');
    }
    return TimerBellSettings(
      start: start,
      end: end,
      intervalMinutes: interval,
      randomCount: random,
    );
  }
}

typedef TimerBellCues = ({List<int> offsetsMs, int? endOffsetMs});

TimerBellCues buildTimerBellCues({
  required TimerBellSettings settings,
  required TimerMode mode,
  required Duration plannedDuration,
  required bool extraTime,
  required int seed,
}) {
  final stopwatch = mode == TimerMode.stopwatch;
  final end =
      (stopwatch ? kStopwatchMaxDuration : plannedDuration).inMilliseconds;
  final fixed = <int>[];
  if (settings.start) fixed.add(0);
  final endCue = extraTime && !stopwatch ? end : max(end ~/ 2, end - 6000);
  final keptEnd = settings.end && _isFree(fixed, endCue) ? endCue : null;
  if (keptEnd != null) fixed.add(keptEnd);

  final interval = settings.intervalMinutes * Duration.millisecondsPerMinute;
  if (interval > 0) {
    for (var offset = interval; offset < end; offset += interval) {
      if (_isFree(fixed, offset)) fixed.add(offset);
    }
  } else if (stopwatch && _isFree(fixed, end ~/ 2)) {
    fixed.add(end ~/ 2);
  }

  if (!stopwatch && settings.randomCount > 0) {
    var slots = [
      for (var offset = 30000; offset <= end - 30000; offset += 1000)
        if (_isFree(fixed, offset)) offset,
    ];
    final random = Random(seed);
    final count = min(settings.randomCount, _greedyCount(slots));
    for (var remaining = count; remaining > 0; remaining--) {
      final candidates = feasibleRandomBellSlots(slots, remaining);
      final pick = candidates[random.nextInt(candidates.length)];
      fixed.add(pick);
      slots = slots.where((slot) => _spaced(slot, pick)).toList();
    }
  }

  return (offsetsMs: fixed..sort(), endOffsetMs: keptEnd);
}

bool _spaced(int a, int b) => (a - b).abs() >= timerBellSpacingMs;
bool _isFree(List<int> offsets, int slot) =>
    offsets.every((offset) => _spaced(offset, slot));

int _greedyCount(List<int> slots) {
  var next = 0;
  var count = 0;
  for (final slot in slots) {
    if (slot < next) continue;
    count++;
    next = slot + timerBellSpacingMs;
  }
  return count;
}

/// Devuelve las opciones que permiten completar [count] en los espacios ordenados.
List<int> feasibleRandomBellSlots(List<int> slots, int count) {
  final length = slots.length;
  final prefix = List<int>.filled(length + 1, 0);
  final suffix = List<int>.filled(length + 1, 0);
  var next = 0;
  for (var i = 0; i < length; i++) {
    final fits = slots[i] >= next;
    prefix[i + 1] = prefix[i] + (fits ? 1 : 0);
    if (fits) next = slots[i] + timerBellSpacingMs;
  }
  int? previous;
  for (var i = length - 1; i >= 0; i--) {
    final fits = previous == null || _spaced(previous, slots[i]);
    suffix[i] = suffix[i + 1] + (fits ? 1 : 0);
    if (fits) previous = slots[i];
  }

  // Elegir un espacio divide los demás en dos tramos independientes.
  final candidates = <int>[];
  var left = 0;
  var right = 0;
  for (final slot in slots) {
    while (slots[left] <= slot - timerBellSpacingMs) {
      left++;
    }
    while (right < length && slots[right] < slot + timerBellSpacingMs) {
      right++;
    }
    if (prefix[left] + 1 + suffix[right] >= count) candidates.add(slot);
  }
  return candidates;
}
