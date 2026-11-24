import 'dart:math';

import 'bell_sound.dart';
import 'timer_session.dart';
import 'timer_stage.dart';

const timerIntervalMinutes = [0, 1, 2, 3, 5, 10, 15, 20, 30];
const timerMaxRandomBells = 10;
const timerBellSpacingMs = 8000;
const timerBellRepeatOptions = [1, 2, 3];

// Cada repetición empieza cuando terminó la anterior.
int timerBellRepeatGapMs(BellSound sound) => sound.durationMs + 500;

/// Cómo avisa cada campana: con sonido, con vibración o con ambos.
enum TimerBellOutput { sound, vibration, soundAndVibration }

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
    this.output = TimerBellOutput.sound,
    this.spokenCues = false,
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
  final TimerBellOutput output;

  /// Avisos hablados de tiempo restante (solo cuenta regresiva).
  final bool spokenCues;

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
    TimerBellOutput? output,
    bool? spokenCues,
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
    output: output ?? this.output,
    spokenCues: spokenCues ?? this.spokenCues,
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
    'output': output.name,
    'spokenCues': spokenCues,
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
      // Valores ausentes o desconocidos (ajustes anteriores) usan el sonido.
      output: TimerBellOutput.values.firstWhere(
        (output) => output.name == json['output'],
        orElse: () => TimerBellOutput.sound,
      ),
      spokenCues: json['spokenCues'] == true,
    );
  }
}

// `midpoint` solo se conserva para leer datos anteriores; ya no se genera.
enum TimerBellKind { start, interval, random, end, midpoint, stage, spoken }

/// Las campanas de inicio, de cambio de parte y de cierre nunca se pierden,
/// aunque lleguen tarde.
bool isMandatoryTimerBell(TimerBellKind kind) => switch (kind) {
  TimerBellKind.start || TimerBellKind.stage || TimerBellKind.end => true,
  TimerBellKind.interval ||
  TimerBellKind.random ||
  TimerBellKind.spoken ||
  TimerBellKind.midpoint => false,
};

/// Prefijo de los avisos hablados; el resto de la clave es el texto a decir.
const kTimerSpokenCuePrefix = 'spoken:';

/// Minutos restantes en los que se ofrece un aviso hablado.
const kTimerSpokenMarks = [10, 5, 1];

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

/// Arma las campanas de una sesión. Todos los tiempos incluyen la preparación
/// ([prepMs]). Prioridad cuando chocan: inicio, cierre, partes, intervalos,
/// al azar y avisos hablados. Cada grupo ocupa desde su primer golpe hasta que
/// se apaga el último (duración real del sonido) y entre grupos quedan al
/// menos [timerBellSpacingMs] de silencio.
///
/// [extraTime] ya no cambia nada: el cierre suena siempre al terminar el
/// tiempo previsto. Se conserva para no romper llamadas anteriores.
List<TimerBellCue> buildTimerBellCues({
  required TimerBellSettings settings,
  required TimerMode mode,
  required Duration plannedDuration,
  required bool extraTime,
  required int seed,
  int prepMs = 0,
  List<TimerStage> stages = const [],
  String Function(int minutesLeft)? spokenText,
}) {
  final prep = max(0, prepMs);
  final stopwatch = mode == TimerMode.stopwatch;
  final multi = !stopwatch && stages.length >= kMinTimerStages;
  final planned = stopwatch
      ? kStopwatchMaxDuration.inMilliseconds
      : multi
      ? stages.fold<int>(0, (sum, stage) => sum + stage.minutes) *
            Duration.millisecondsPerMinute
      : plannedDuration.inMilliseconds;
  final end = prep + planned;
  final cues = <TimerBellCue>[];
  final groups = <_BellRange>[];
  void add(int offset, TimerBellKind kind, BellSound sound, int repeats) {
    final gap = timerBellRepeatGapMs(sound);
    final audibleEnd = offset + (repeats - 1) * gap + sound.durationMs;
    if (!_isFree(groups, offset, audibleEnd)) return;
    groups.add((start: offset, end: audibleEnd));
    for (var i = 0; i < repeats; i++) {
      cues.add(TimerBellCue(offset + i * gap, kind, sound.assetKey));
    }
  }

  // Inicio: en una sesión por partes, la campana de la primera parte
  // reemplaza a la campana general de inicio.
  if (multi) {
    final first = stages.first;
    add(
      prep,
      TimerBellKind.stage,
      BellSound.resolve(first.sound),
      first.repeats,
    );
  } else if (settings.start) {
    add(
      prep,
      TimerBellKind.start,
      BellSound.resolve(settings.startSound),
      settings.startRepeats,
    );
  }

  // Cierre: exactamente al terminar el tiempo previsto (cronómetro: 5 h).
  if (settings.end) {
    add(
      end,
      TimerBellKind.end,
      BellSound.resolve(settings.endSound),
      settings.endRepeats,
    );
  }

  // Cambios de parte: cada parte abre con su propia campana.
  if (multi) {
    var offset = prep;
    for (var i = 1; i < stages.length; i++) {
      offset += stages[i - 1].minutes * Duration.millisecondsPerMinute;
      final stage = stages[i];
      add(
        offset,
        TimerBellKind.stage,
        BellSound.resolve(stage.sound),
        stage.repeats,
      );
    }
  }

  final interval = settings.intervalMinutes * Duration.millisecondsPerMinute;
  if (interval > 0) {
    final intervalSound = BellSound.resolve(settings.intervalSound);
    for (var offset = prep + interval; offset < end; offset += interval) {
      add(
        offset,
        TimerBellKind.interval,
        intervalSound,
        settings.intervalRepeats,
      );
    }
  }

  // Al azar: solo después de las campanas fijas, así nunca retrasa una.
  if (!stopwatch && settings.randomCount > 0) {
    final randomSound = BellSound.resolve(settings.randomSound);
    final repeatSpan =
        (settings.randomRepeats - 1) * timerBellRepeatGapMs(randomSound);
    final audibleSpan = repeatSpan + randomSound.durationMs;
    final spacing = timerBellSpacingMs + audibleSpan;
    var slots = [
      for (
        var offset = prep + 30000;
        offset <= end - 30000 - repeatSpan;
        offset += 1000
      )
        if (_isFree(groups, offset, offset + audibleSpan)) offset,
    ];
    final random = Random(seed);
    final count = min(settings.randomCount, _greedyCount(slots, spacing));
    for (var remaining = count; remaining > 0; remaining--) {
      final candidates = feasibleRandomBellSlots(
        slots,
        remaining,
        spanMs: audibleSpan,
      );
      final pick = candidates[random.nextInt(candidates.length)];
      add(pick, TimerBellKind.random, randomSound, settings.randomRepeats);
      slots = slots.where((slot) => (slot - pick).abs() >= spacing).toList();
    }
  }

  // Avisos hablados: si chocan con una campana se omiten, nunca se mueven.
  // No ocupan lugar en `groups`, así que nunca bloquean una campana.
  if (spokenText != null && settings.spokenCues && !stopwatch) {
    for (final mark in kTimerSpokenMarks) {
      if (planned < (mark + 1) * Duration.millisecondsPerMinute) continue;
      final target = end - mark * Duration.millisecondsPerMinute;
      if (!_isFree(groups, target, target)) continue;
      cues.add(
        TimerBellCue(
          target,
          TimerBellKind.spoken,
          '$kTimerSpokenCuePrefix${spokenText(mark)}',
        ),
      );
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
