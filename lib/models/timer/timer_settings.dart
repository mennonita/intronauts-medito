import 'timer_bell_settings.dart';
import 'timer_session.dart';

const kMaxTimerMinutes = kMaxTimerHours * 60 + 59;

class TimerSettings {
  const TimerSettings({
    required this.mode,
    required this.minutes,
    this.bells = const TimerBellSettings(),
    this.extraTime = false,
  });

  final TimerMode mode;
  final int minutes;
  final TimerBellSettings bells;
  final bool extraTime;

  Duration get countdown => Duration(minutes: minutes);

  Duration get sessionDuration =>
      mode == TimerMode.stopwatch ? kStopwatchMaxDuration : countdown;

  bool get hasExtraTime => mode == TimerMode.countdown && extraTime;

  Duration get fileDuration =>
      hasExtraTime ? kStopwatchMaxDuration : sessionDuration;

  bool get canStart => mode == TimerMode.stopwatch || minutes > 0;

  TimerSettings copyWith({
    TimerMode? mode,
    int? minutes,
    TimerBellSettings? bells,
    bool? extraTime,
  }) => TimerSettings(
    mode: mode ?? this.mode,
    minutes: minutes ?? this.minutes,
    bells: bells ?? this.bells,
    extraTime: extraTime ?? this.extraTime,
  );
}
