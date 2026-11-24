/// Returns the user-perceived calendar day that contains [t], honouring
/// an optional [offset].
///
/// `offset` shifts when a new day begins relative to local midnight:
///   - `Duration.zero` (default) — day starts at 00:00 (legacy behaviour).
///   - `Duration(hours: 4)` — day starts at 04:00; a session at 02:00 still
///     counts toward the previous calendar day.
///   - `Duration(hours: -2)` — day starts at 22:00 the prior evening; a
///     session at 23:00 counts toward the next calendar day.
///
/// The returned value is always at local midnight (`hour=minute=second=ms=0`).
///
/// El desfase se aplica a la hora de reloj (los campos locales de [t]), no a
/// horas transcurridas: en el día del cambio de horario las 04:30 con inicio
/// a las 04:00 siguen siendo de ese día. Los campos se copian a una fecha UTC
/// solo para restar sin cambios de horario.
DateTime dayOf(DateTime t, [Duration offset = Duration.zero]) {
  final wallClock = DateTime.utc(
    t.year,
    t.month,
    t.day,
    t.hour,
    t.minute,
    t.second,
    t.millisecond,
    t.microsecond,
  ).subtract(offset);
  return DateTime(wallClock.year, wallClock.month, wallClock.day);
}
