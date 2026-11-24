"""Prueba el inicio del día del widget con Foundation."""

from pathlib import Path
import shutil
import subprocess
import unittest


WIDGET = Path(__file__).resolve().parents[1] / "MeditoWidget"
SWIFT = shutil.which("swift")


@unittest.skipUnless(SWIFT, "Se necesita Swift para ejecutar la prueba del widget.")
class WidgetDayBoundaryTest(unittest.TestCase):
    def test_day_boundary_uses_local_hours_during_dst(self):
        # Compila la parte de Foundation del widget sin cargar vistas de iOS.
        shared = (WIDGET / "WidgetShared.swift").read_text(encoding="utf-8")
        shared = shared.split("\nstruct WidgetColors {", 1)[0]
        shared = shared.replace("import CoreText\n", "").replace("import SwiftUI\n", "")
        stats = (WIDGET / "StatCalculators.swift").read_text(encoding="utf-8")
        cases = """
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/New_York")!

func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

func day(_ date: Date, _ offset: Int) -> Date {
    logicalDayStart(date, offsetHours: offset, calendar: calendar)
}

func timeline(_ now: Date, _ offset: Int) -> [Date] {
    let data = WidgetData(
        meditationDates: [], freezeDates: [], practiceDates: [], minimumReturns: 0,
        returnsOffsetHours: offset, dayLabel: "", daysLabel: "",
        themePreference: "system", dayBoundaryOffsetHours: offset
    )
    return data.timelineDates(from: now, calendar: calendar)
}

// Los mismos días de cambio de horario que las pruebas de Kotlin.
precondition(day(date(3, 8, 3, 59), 4) == date(3, 7))
precondition(day(date(3, 8, 4), 4) == date(3, 8))
precondition(day(date(3, 8, 4, 30), 4) == date(3, 8))
precondition(day(date(11, 1, 3, 30), 4) == date(10, 31))
precondition(day(date(11, 1, 4), 4) == date(11, 1))
precondition(day(date(3, 7, 22), -2) == date(3, 8))

precondition(timeline(date(3, 8, 3, 59), 4) == [date(3, 8, 3, 59), date(3, 8, 4)])
precondition(timeline(date(11, 1, 3, 30), 4) == [date(11, 1, 3, 30), date(11, 1, 4)])
precondition(timeline(date(3, 7, 21, 59), -2) == [date(3, 7, 21, 59), date(3, 7, 22)])

// Si no existe la hora elegida, actualiza en la primera hora disponible.
precondition(timeline(date(3, 8, 1, 59), 2) == [date(3, 8, 1, 59), date(3, 8, 3)])

// Si se repite la hora elegida, actualiza cuando ocurre por primera vez.
let firstOne = ISO8601DateFormatter().date(from: "2026-11-01T01:00:00-04:00")!
precondition(timeline(date(11, 1), 1) == [date(11, 1), firstOne])
precondition(timeline(firstOne, 1) == [firstOne, date(11, 2, 1)])
"""
        result = subprocess.run(
            [SWIFT, "-"], input="\n".join([stats, shared, cases]),
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
