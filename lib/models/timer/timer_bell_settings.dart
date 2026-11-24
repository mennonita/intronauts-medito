import 'dart:math';

import 'bell_sound.dart';
import 'timer_session.dart';

const timerIntervalMinutes = [0, 1, 2, 3, 5, 10, 15, 20, 30];
const timerMaxRandomBells = 10;
const timerBellSpacingMs = 8000;
const timerBellRepeatOptions = [1, 2, 3];

int timerBellRepeatGapMs(BellSound sound) => sound.durationMs.clamp(2000, 4000);

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
    this.startRepeats = 1,
    this.endRepeats = 1,
    this.intervalRepeats = 1,
    this.randomRepeats = 1,
  });

  final bool start;
  final bool end;
  final int intervalMinutes;
  final int randomCount;
  final BellSoundId startSound;
  final BellSoundId endSound;
  final BellSoundId intervalSound;
  final BellSoundId randomSound;
  final int startRepeats;
  final int endRepeats;
  final int intervalRepeats;
  final int randomRepeats;

  TimerBellSettings copyWith({
    bool? start,
    bool? end,
    int? intervalMinutes,
    int? randomCount,
    BellSoundId? startSound,
    BellSoundId? endSound,
    BellSoundId? intervalSound,
    BellSoundId? randomSound,
    int? startRepeats,
    int? endRepeats,
    int? intervalRepeats,
    int? randomRepeats,
  }) => TimerBellSettings(
    start: start ?? this.start,
    end: end ?? this.end,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    randomCount: randomCount ?? this.randomCount,
    startSound: startSound ?? this.startSound,
    endSound: endSound ?? this.endSound,
    intervalSound: intervalSound ?? this.intervalSound,
    randomSound: randomSound ?? this.randomSound,
    startRepeats: startRepeats ?? this.startRepeats,
    endRepeats: endRepeats ?? this.endRepeats,
    intervalRepeats: intervalRepeats ?? this.intervalRepeats,
    randomRepeats: randomRepeats ?? this.randomRepeats,
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
    'startRepeats': startRepeats,
    'endRepeats': endRepeats,
    'intervalRepeats': intervalRepeats,
    'randomRepeats': randomRepeats,
  };

  factory TimerBellSettings.fromJson(Map<String, Object?> json) {
    const invalidSettings = FormatException(
      'Ajustes de campanas fuera de rango',
    );
    int readRepeats(String key) {
      if (!json.containsKey(key)) return 1;
      final value = json[key];
      if (value is! int || !timerBellRepeatOptions.contains(value)) {
        throw invalidSettings;
      }
      return value;
    }

    final start = json['start'] as bool;
    final end = json['end'] as bool;
    final interval = json['intervalMinutes'] as int;
    final random = json['randomCount'] as int;
    if (!timerIntervalMinutes.contains(interval) ||
        random < 0 ||
        random > timerMaxRandomBells) {
      throw invalidSettings;
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
      startRepeats: readRepeats('startRepeats'),
      endRepeats: readRepeats('endRepeats'),
      intervalRepeats: readRepeats('intervalRepeats'),
      randomRepeats: readRepeats('randomRepeats'),
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

typedef _BellRange = ({int start, int end});

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
  final groups = <_BellRange>[];
  void add(int offset, TimerBellKind kind, BellSound sound, int repeats) {
    final gap = timerBellRepeatGapMs(sound);
    final last = offset + (repeats - 1) * gap;
    if (!_isFree(groups, offset, last)) return;
    groups.add((start: offset, end: last));
    for (var i = 0; i < repeats; i++) {
      cues.add(TimerBellCue(offset + i * gap, kind, sound.assetKey));
    }
  }

  if (settings.start) {
    add(
      0,
      TimerBellKind.start,
      BellSound.resolve(settings.startSound),
      settings.startRepeats,
    );
  }
  final endSound = BellSound.resolve(settings.endSound);
  final endSpan = (settings.endRepeats - 1) * timerBellRepeatGapMs(endSound);
  final endCue = extraTime && !stopwatch
      ? end
      : max(end ~/ 2, end - endSpan - endSound.durationMs - 500);
  if (settings.end) {
    add(endCue, TimerBellKind.end, endSound, settings.endRepeats);
  }

  final interval = settings.intervalMinutes * Duration.millisecondsPerMinute;
  final intervalSound = BellSound.resolve(settings.intervalSound);
  if (interval > 0) {
    for (var offset = interval; offset < end; offset += interval) {
      add(
        offset,
        TimerBellKind.interval,
        intervalSound,
        settings.intervalRepeats,
      );
    }
  } else if (stopwatch) {
    add(
      end ~/ 2,
      TimerBellKind.midpoint,
      intervalSound,
      settings.intervalRepeats,
    );
  }

  if (!stopwatch && settings.randomCount > 0) {
    final randomSound = BellSound.resolve(settings.randomSound);
    final randomSpan =
        (settings.randomRepeats - 1) * timerBellRepeatGapMs(randomSound);
    final spacing = timerBellSpacingMs + randomSpan;
    var slots = [
      for (
        var offset = 30000;
        offset <= end - 30000 - randomSpan;
        offset += 1000
      )
        if (_isFree(groups, offset, offset + randomSpan)) offset,
    ];
    final random = Random(seed);
    final count = min(settings.randomCount, _greedyCount(slots, spacing));
    for (var remaining = count; remaining > 0; remaining--) {
      final candidates = feasibleRandomBellSlots(
        slots,
        remaining,
        spanMs: randomSpan,
      );
      final pick = candidates[random.nextInt(candidates.length)];
      add(pick, TimerBellKind.random, randomSound, settings.randomRepeats);
      slots = slots.where((slot) => (slot - pick).abs() >= spacing).toList();
    }
  }

  return cues..sort((a, b) => a.offsetMs.compareTo(b.offsetMs));
}

bool _isFree(List<_BellRange> groups, int start, int end) => groups.every(
  (group) =>
      start - group.end >= timerBellSpacingMs ||
      group.start - end >= timerBellSpacingMs,
);

int _greedyCount(List<int> slots, int spacing) {
  var next = 0;
  var count = 0;
  for (final slot in slots) {
    if (slot < next) continue;
    count++;
    next = slot + spacing;
  }
  return count;
}

/// Devuelve las opciones que permiten completar [count] grupos en los espacios ordenados.
List<int> feasibleRandomBellSlots(
  List<int> slots,
  int count, {
  int spanMs = 0,
}) {
  final spacing = timerBellSpacingMs + spanMs;
  final length = slots.length;
  final prefix = List<int>.filled(length + 1, 0);
  final suffix = List<int>.filled(length + 1, 0);
  var next = 0;
  for (var i = 0; i < length; i++) {
    final fits = slots[i] >= next;
    prefix[i + 1] = prefix[i] + (fits ? 1 : 0);
    if (fits) next = slots[i] + spacing;
  }
  int? previous;
  for (var i = length - 1; i >= 0; i--) {
    final fits = previous == null || previous - slots[i] >= spacing;
    suffix[i] = suffix[i + 1] + (fits ? 1 : 0);
    if (fits) previous = slots[i];
  }

  // Elegir un espacio divide los demás en dos tramos independientes.
  final candidates = <int>[];
  var left = 0;
  var right = 0;
  for (final slot in slots) {
    while (slots[left] <= slot - spacing) {
      left++;
    }
    while (right < length && slots[right] < slot + spacing) {
      right++;
    }
    if (prefix[left] + 1 + suffix[right] >= count) candidates.add(slot);
  }
  return candidates;
}
