import '../../models/timer/timer_bell_settings.dart';

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

  TimerBellCue? update(int positionMs, {required bool enabled}) {
    TimerBellCue? ring;
    while (_next < _cues.length && _cues[_next].offsetMs <= positionMs) {
      final cue = _cues[_next++];
      if (enabled && positionMs - cue.offsetMs < 2000) ring = cue;
    }
    return ring;
  }
}
