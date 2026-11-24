import '../../models/timer/timer_bell_settings.dart';

/// Retraso máximo con el que todavía suena una campana opcional.
const kTimerOptionalCueMaxLateMs = 2000;

/// Consume las campanas cruzadas, incluso cuando están apagadas o llegan tarde.
class TimerBellSchedule {
  TimerBellSchedule(List<TimerBellCue> cues) : _cues = List.unmodifiable(cues);

  final List<TimerBellCue> _cues;
  int _next = 0;

  void reset() => _next = 0;

  void seek(int positionMs) {
    reset();
    while (_next < _cues.length && _cues[_next].offsetMs <= positionMs) {
      _next++;
    }
  }

  /// Devuelve, de la más antigua a la más nueva, las campanas que deben sonar.
  /// Inicio, cambio de parte y cierre suenan aunque lleguen tarde; de los
  /// intervalos, campanas al azar y avisos hablados solo suena el más reciente
  /// y únicamente si lleva menos de [kTimerOptionalCueMaxLateMs] de retraso.
  /// Todas las campanas cruzadas quedan consumidas. Quien las toca debe
  /// tocarlas una tras otra, sin cortar una campana que ya suena.
  List<TimerBellCue> update(int positionMs, {required bool enabled}) {
    final mandatory = <TimerBellCue>[];
    TimerBellCue? optional;
    while (_next < _cues.length && _cues[_next].offsetMs <= positionMs) {
      final cue = _cues[_next++];
      if (!enabled) continue;
      if (isMandatoryTimerBell(cue.kind)) {
        mandatory.add(cue);
      } else {
        optional = cue;
      }
    }
    final latest = optional;
    if (latest != null &&
        positionMs - latest.offsetMs < kTimerOptionalCueMaxLateMs) {
      // La lista ya está ordenada; se inserta en su lugar por tiempo.
      final index = mandatory.indexWhere(
        (cue) => cue.offsetMs > latest.offsetMs,
      );
      mandatory.insert(index < 0 ? mandatory.length : index, latest);
    }
    return mandatory;
  }
}
