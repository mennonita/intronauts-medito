import 'bell_sound.dart';
import 'timer_bell_settings.dart';
import 'timer_settings.dart';

/// Tipo de cada parte de una sesión por partes.
enum TimerStageKind { sit, walk, rest }

const kMaxTimerStages = 6;
const kMinTimerStages = 2;

/// Una parte de la sesión con su duración y la campana que la abre.
class TimerStage {
  const TimerStage({
    required this.kind,
    required this.minutes,
    this.sound = defaultBellSoundId,
    this.repeats = 1,
  });

  final TimerStageKind kind;
  final int minutes;
  final BellSoundId sound;
  final int repeats;

  Duration get duration => Duration(minutes: minutes);

  /// Minutos entre 1 y [kMaxTimerMinutes] y de 1 a 3 repeticiones.
  bool get isValid =>
      minutes >= 1 &&
      minutes <= kMaxTimerMinutes &&
      timerBellRepeatOptions.contains(repeats);

  /// La misma parte dentro de los rangos admitidos.
  TimerStage clamped() => copyWith(
    minutes: minutes.clamp(1, kMaxTimerMinutes),
    sound: BellSound.resolve(sound).id,
    repeats: repeats.clamp(
      timerBellRepeatOptions.first,
      timerBellRepeatOptions.last,
    ),
  );

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'minutes': minutes,
    'sound': sound,
    'repeats': repeats,
  };

  /// Lee una parte guardada; tolera valores viejos o fuera de rango y
  /// devuelve null solo cuando no hay datos utilizables.
  static TimerStage? fromJson(Object? json) {
    if (json is! Map) return null;
    final minutes = json['minutes'];
    if (minutes is! num || minutes.isNaN || minutes.isInfinite) return null;
    final kindName = json['kind'];
    final kind = TimerStageKind.values.firstWhere(
      (kind) => kind.name == kindName,
      orElse: () => TimerStageKind.sit,
    );
    final repeats = json['repeats'];
    return TimerStage(
      kind: kind,
      minutes: minutes.toInt().clamp(1, kMaxTimerMinutes),
      sound: BellSound.resolve(json['sound']).id,
      repeats: repeats is num && !repeats.isNaN && !repeats.isInfinite
          ? repeats.toInt().clamp(
              timerBellRepeatOptions.first,
              timerBellRepeatOptions.last,
            )
          : 1,
    );
  }

  TimerStage copyWith({
    TimerStageKind? kind,
    int? minutes,
    BellSoundId? sound,
    int? repeats,
  }) => TimerStage(
    kind: kind ?? this.kind,
    minutes: minutes ?? this.minutes,
    sound: sound ?? this.sound,
    repeats: repeats ?? this.repeats,
  );

  @override
  bool operator ==(Object other) =>
      other is TimerStage &&
      other.kind == kind &&
      other.minutes == minutes &&
      other.sound == sound &&
      other.repeats == repeats;

  @override
  int get hashCode => Object.hash(kind, minutes, sound, repeats);

  @override
  String toString() =>
      'TimerStage(${kind.name}, $minutes min, $sound×$repeats)';
}

/// Lee una lista de partes guardada; descarta las inválidas y corta en el máximo.
List<TimerStage> timerStagesFromJson(Object? json) {
  if (json is! List) return const [];
  final stages = <TimerStage>[];
  for (final item in json) {
    final stage = TimerStage.fromJson(item);
    if (stage == null) continue;
    stages.add(stage);
    if (stages.length == kMaxTimerStages) break;
  }
  return List.unmodifiable(stages);
}
