/// Días de calendario entre la fecha de [a] y la de [b] (positivo si [b] es
/// después). Solo usa año, mes y día, así que un cambio de horario (un día de
/// 23 o 25 horas) no le quita ni le suma un día.
int calendarDaysBetween(DateTime a, DateTime b) {
  return DateTime.utc(
    b.year,
    b.month,
    b.day,
  ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}

/// La fecha local [days] días de calendario después de [day], a medianoche.
/// A diferencia de `add(Duration(days: n))`, no se corre una hora al cruzar
/// un cambio de horario.
DateTime addCalendarDays(DateTime day, int days) {
  return DateTime(day.year, day.month, day.day + days);
}
