import 'timer_bell_settings.dart';
import 'timer_session.dart';
import 'timer_stage.dart';

export 'timer_stage.dart';

const kMaxTimerMinutes = kMaxTimerHours * 60 + 59;

/// Segundos de preparación que se ofrecen antes de la campana de inicio.
const kTimerPrepOptions = [0, 10, 30, 60, 120];

/// Preparación más larga que se acepta de datos guardados.
const kMaxTimerPrepSeconds = 7200;

class TimerSettings {
  const TimerSettings({
    required this.mode,
    required this.minutes,
    this.bells = const TimerBellSettings(),
    this.extraTime = false,
    this.prepSeconds = 0,
    this.stages = const [],
  });

  final TimerMode mode;
  final int minutes;
  final TimerBellSettings bells;
  final bool extraTime;
  final int prepSeconds;

  /// Partes de la sesión; vacío (o una sola) = un solo bloque.
  final List<TimerStage> stages;

  Duration get countdown => Duration(minutes: minutes);

  /// Sesión por partes: solo en cuenta regresiva y con al menos dos partes.
  bool get isMultiStage =>
      mode == TimerMode.countdown && stages.length >= kMinTimerStages;

  int get stagesTotalMinutes =>
      stages.fold(0, (sum, stage) => sum + stage.minutes);

  /// Tiempo previsto de práctica, sin preparación ni tiempo extra.
  Duration get plannedDuration => mode == TimerMode.stopwatch
      ? kStopwatchMaxDuration
      : isMultiStage
      ? Duration(minutes: stagesTotalMinutes)
      : countdown;

  Duration get sessionDuration => plannedDuration;

  bool get hasExtraTime =>
      mode == TimerMode.countdown && extraTime && !isMultiStage;

  Duration get prepDuration => Duration(seconds: prepSeconds);

  Duration get fileDuration => timerFileDuration(
    mode: mode,
    planned: plannedDuration,
    extraTime: hasExtraTime,
    bells: bells,
    prep: prepDuration,
  );

  bool get canStart {
    if (mode == TimerMode.stopwatch) return true;
    if (isMultiStage) {
      return stages.length <= kMaxTimerStages &&
          stages.every((stage) => stage.isValid) &&
          stagesTotalMinutes <= kMaxTimerMinutes;
    }
    return minutes > 0;
  }

  TimerSettings copyWith({
    TimerMode? mode,
    int? minutes,
    TimerBellSettings? bells,
    bool? extraTime,
    int? prepSeconds,
    List<TimerStage>? stages,
  }) => TimerSettings(
    mode: mode ?? this.mode,
    minutes: minutes ?? this.minutes,
    bells: bells ?? this.bells,
    extraTime: extraTime ?? this.extraTime,
    prepSeconds: prepSeconds ?? this.prepSeconds,
    stages: stages ?? this.stages,
  );

  /// Todos los ajustes en un mapa listo para JSON (último temporizador y
  /// temporizadores guardados usan las mismas claves).
  Map<String, dynamic> toSnapshotJson() => {
    'mode': mode.name,
    'minutes': minutes,
    'bells': bells.toJson(),
    'extraTime': extraTime,
    'prepSeconds': prepSeconds,
    'stages': [for (final stage in stages) stage.toJson()],
  };

  /// Lee los ajustes de [toSnapshotJson]; devuelve null si están dañados.
  /// Con [requireStart] en false acepta ajustes que aún no pueden empezar
  /// (por ejemplo 0 minutos en pantalla).
  static TimerSettings? fromSnapshotJson(
    Map<String, dynamic> json, {
    bool requireStart = true,
  }) {
    try {
      final modeName = json['mode'];
      final minutes = json['minutes'];
      final bells = json['bells'];
      final extraTime = json['extraTime'];
      if (modeName is! String ||
          minutes is! int ||
          minutes < 0 ||
          minutes > kMaxTimerMinutes ||
          bells is! Map ||
          (extraTime != null && extraTime is! bool)) {
        return null;
      }
      final settings = TimerSettings(
        mode: TimerMode.values.byName(modeName),
        minutes: minutes,
        bells: TimerBellSettings.fromJson(Map<String, Object?>.from(bells)),
        extraTime: extraTime as bool? ?? false,
        prepSeconds: timerPrepSecondsFromJson(json['prepSeconds']),
        stages: timerStagesFromJson(json['stages']),
      );
      return !requireStart || settings.canStart ? settings : null;
    } catch (_) {
      return null;
    }
  }
}

/// Preparación guardada: entero entre 0 y [kMaxTimerPrepSeconds]; otro valor = 0.
int timerPrepSecondsFromJson(Object? value) =>
    value is int ? value.clamp(0, kMaxTimerPrepSeconds) : 0;
