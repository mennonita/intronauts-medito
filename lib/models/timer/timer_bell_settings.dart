import 'dart:math';

import 'bell_sound.dart';
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
    this.startSound = defaultBellSoundId,
    this.endSound = defaultBellSoundId,
    this.intervalSound = defaultBellSoundId,
    this.randomSound = defaultBellSoundId,
  });

  final bool start;
  final bool end;
  final int intervalMinutes;
  final int randomCount;
  final BellSoundId startSound;
  final BellSoundId endSound;
  final BellSoundId intervalSound;
  final BellSoundId randomSound;

  TimerBellSettings copyWith({
    bool? start,
    bool? end,
    int? intervalMinutes,
    int? randomCount,
    BellSoundId? startSound,
    BellSoundId? endSound,
    BellSoundId? intervalSound,
    BellSoundId? randomSound,
  }) => TimerBellSettings(
    start: start ?? this.start,
    end: end ?? this.end,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    randomCount: randomCount ?? this.randomCount,
    startSound: startSound ?? this.startSound,
    endSound: endSound ?? this.endSound,
    intervalSound: intervalSound ?? this.intervalSound,
    randomSound: randomSound ?? this.randomSound,
  );

  Map<String, Object> toJson() => {
    'start': start,
    'end': end,
    'intervalMinutes': intervalMinutes,
    'randomCount': randomCount,
    'startSound': startSound,
    'endSound': endSound,
    'intervalSound': intervalSound,
    'randomSound': randomSound,
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
      startSound: BellSound.resolve(json['startSound']).id,
      endSound: BellSound.resolve(json['endSound']).id,
      intervalSound: BellSound.resolve(json['intervalSound']).id,
      randomSound: BellSound.resolve(json['randomSound']).id,
    );
  }
}

enum TimerBellKind { start, interval, random, end, midpoint }

class TimerBellCue {
  const TimerBellCue(this.offsetMs, this.kind, this.assetKey);

  final int offsetMs;
  final TimerBellKind kind;
  final String assetKey;

  Map<String, Object> toJson() => {
    'offsetMs': offsetMs,
    'kind': kind.name,
    'assetKey': assetKey,
  };

  factory TimerBellCue.fromJson(Map<String, Object?> json) => TimerBellCue(
    json['offsetMs'] as int,
    TimerBellKind.values.byName(json['kind'] as String),
    json['assetKey'] as String,
  );

  @override
  bool operator ==(Object other) =>
      other is TimerBellCue &&
      other.offsetMs == offsetMs &&
      other.kind == kind &&
      other.assetKey == assetKey;

  @override
  int get hashCode => Object.hash(offsetMs, kind, assetKey);
}

List<TimerBellCue> buildTimerBellCues({
  required TimerBellSettings settings,
  required TimerMode mode,
  required Duration plannedDuration,
  required bool extraTime,
  required int seed,
}) {
  final stopwatch = mode == TimerMode.stopwatch;
  final end =
      (stopwatch ? kStopwatchMaxDuration : plannedDuration).inMilliseconds;
  final cues = <TimerBellCue>[];
  void add(int offset, TimerBellKind kind, BellSound sound) {
    cues.add(TimerBellCue(offset, kind, sound.assetKey));
  }

  if (settings.start) {
    add(0, TimerBellKind.start, BellSound.resolve(settings.startSound));
  }
  final endSound = BellSound.resolve(settings.endSound);
  final endCue = extraTime && !stopwatch
      ? end
      : max(end ~/ 2, end - endSound.durationMs - 500);
  if (settings.end && _isFree(cues, endCue)) {
    add(endCue, TimerBellKind.end, endSound);
  }

  final interval = settings.intervalMinutes * Duration.millisecondsPerMinute;
  final intervalSound = BellSound.resolve(settings.intervalSound);
  if (interval > 0) {
    for (var offset = interval; offset < end; offset += interval) {
      if (_isFree(cues, offset)) {
        add(offset, TimerBellKind.interval, intervalSound);
      }
    }
  } else if (stopwatch && _isFree(cues, end ~/ 2)) {
    add(end ~/ 2, TimerBellKind.midpoint, intervalSound);
  }

  if (!stopwatch && settings.randomCount > 0) {
    var slots = [
      for (var offset = 30000; offset <= end - 30000; offset += 1000)
        if (_isFree(cues, offset)) offset,
    ];
    final random = Random(seed);
    final randomSound = BellSound.resolve(settings.randomSound);
    final count = min(settings.randomCount, _greedyCount(slots));
    for (var remaining = count; remaining > 0; remaining--) {
      final candidates = feasibleRandomBellSlots(slots, remaining);
      final pick = candidates[random.nextInt(candidates.length)];
      add(pick, TimerBellKind.random, randomSound);
      slots = slots.where((slot) => _spaced(slot, pick)).toList();
    }
  }

  return cues..sort((a, b) => a.offsetMs.compareTo(b.offsetMs));
}

bool _spaced(int a, int b) => (a - b).abs() >= timerBellSpacingMs;
bool _isFree(List<TimerBellCue> cues, int slot) =>
    cues.every((cue) => _spaced(cue.offsetMs, slot));

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
