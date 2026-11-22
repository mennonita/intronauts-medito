/// Consume las campanas cruzadas, incluso cuando están apagadas o llegan tarde.
class TimerBellSchedule {
  TimerBellSchedule(List<int> offsetsMs)
    : _offsetsMs = List.unmodifiable(offsetsMs);

  final List<int> _offsetsMs;
  int _next = 0;

  void reset() => _next = 0;

  void seek(int positionMs) {
    reset();
    if (positionMs == 0) return;
    while (_next < _offsetsMs.length && _offsetsMs[_next] <= positionMs) {
      _next++;
    }
  }

  int? update(int positionMs, {required bool enabled}) {
    int? ring;
    while (_next < _offsetsMs.length && _offsetsMs[_next] <= positionMs) {
      final cue = _offsetsMs[_next++];
      if (enabled && positionMs - cue < 2000) ring = cue;
    }
    return ring;
  }
}
