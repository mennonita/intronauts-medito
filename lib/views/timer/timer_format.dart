import 'package:medito/l10n/app_localizations.dart';

/// Muestra el tiempo como `4:05`, `12:00` o `1:02:03`.
String formatTimerClock(Duration duration, {bool roundUp = false}) {
  var d = duration.isNegative ? Duration.zero : duration;
  if (roundUp &&
      d.inMicroseconds.remainder(Duration.microsecondsPerSecond) != 0) {
    d = Duration(seconds: d.inSeconds + 1);
  }
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

/// Comparte el cálculo de la cuenta regresiva, el cronómetro y el tiempo extra.
({String time, bool isExtraTime}) timerClockReading({
  required int positionMs,
  int? plannedDurationMs,
  bool hasExtraTime = false,
}) {
  final position = positionMs < 0 ? 0 : positionMs;
  final countingDown = plannedDurationMs != null;
  final isExtraTime =
      hasExtraTime &&
      plannedDurationMs != null &&
      position >= plannedDurationMs;
  final remaining = countingDown && !isExtraTime;
  final milliseconds = switch (plannedDurationMs) {
    null => position,
    final planned => isExtraTime ? position - planned : planned - position,
  };
  return (
    time: formatTimerClock(
      Duration(milliseconds: milliseconds),
      roundUp: remaining,
    ),
    isExtraTime: isExtraTime,
  );
}

/// Muestra la duración en minutos completos, como `20 min` o `1 h 30 min`.
String formatTimerLength(Duration duration, AppLocalizations l10n) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours == 0) return '$minutes ${l10n.min}';
  if (minutes == 0) return '$hours ${l10n.hours}';
  return '$hours ${l10n.hours} $minutes ${l10n.min}';
}

/// Dice la duración en palabras para el lector de pantalla, como
/// «12 minutos» o «1 hora 5 minutos». Los segundos solo se dicen cuando falta
/// o se lleva menos de un minuto; si no, los minutos se redondean hacia abajo.
String timerSpokenDuration(AppLocalizations l10n, Duration duration) {
  final d = duration.isNegative ? Duration.zero : duration;
  if (d < const Duration(minutes: 1)) {
    return l10n.timerSpokenSeconds(d.inSeconds);
  }
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  return [
    if (hours > 0) l10n.timerSpokenHours(hours),
    if (minutes > 0) l10n.timerSpokenMinutes(minutes),
  ].join(' ');
}
