import 'dart:async';

import 'package:medito/models/timer/timer_session.dart';

class TimerCloseResult {
  const TimerCloseResult(
    this.elapsed, {
    this.stopped = true,
    this.endCueRang = false,
    this.completionPersisted = false,
  });

  final Duration elapsed;
  final bool stopped;
  final bool endCueRang;
  final bool completionPersisted;

  bool get recorded => stopped && elapsed >= kMinRecordedTimerSession;
}

class TimerSessionCloser {
  Future<TimerCloseResult>? _closing;

  bool get isClosing => _closing != null;

  Future<TimerCloseResult> close({
    required Future<TimerCloseResult> Function() stopPlayback,
    required void Function(TimerCloseResult result) onStopped,
    bool Function()? isCurrent,
  }) {
    final closing = _closing;
    if (closing != null) return closing;
    final result = Completer<TimerCloseResult>();
    _closing = result.future;
    unawaited(_finish(result, stopPlayback, onStopped, isCurrent));
    return result.future;
  }

  Future<void> _finish(
    Completer<TimerCloseResult> result,
    Future<TimerCloseResult> Function() stopPlayback,
    void Function(TimerCloseResult result) onStopped,
    bool Function()? isCurrent,
  ) async {
    final TimerCloseResult stopped;
    try {
      stopped = await stopPlayback();
    } catch (error, stack) {
      _closing = null;
      if (isCurrent?.call() == false) {
        result.complete(const TimerCloseResult(Duration.zero, stopped: false));
      } else {
        result.completeError(error, stack);
      }
      return;
    }
    if (isCurrent?.call() == false) {
      _closing = null;
      result.complete(TimerCloseResult(stopped.elapsed, stopped: false));
      return;
    }
    if (!stopped.stopped) {
      _closing = null;
      result.complete(stopped);
      return;
    }
    try {
      onStopped(stopped);
      result.complete(stopped);
    } catch (error, stack) {
      result.completeError(error, stack);
    }
  }
}
