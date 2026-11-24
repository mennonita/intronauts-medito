import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../constants/constants.dart';
import '../../constants/strings/analytics_event_constants.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/notification/reminder_provider.dart';
import '../../utils/logger.dart';

/// Identifies a daily reminder to the notification tap handler. Deliberately
/// carries no `type`/`path`, so a tap does not deep-link — the point is
/// attribution, not routing. Must stay valid JSON: the handler decodes it, and
/// a bare string (what the series used to build, and then never attached)
/// decodes to nothing.
String reminderPayload(int day) => json.encode({
  AnalyticsEventConstants.paramSource:
      AnalyticsEventConstants.sourceLocalReminder,
  AnalyticsEventConstants.paramNotificationDay: day,
});

/// La serie de recordatorios se actualiza después de cada sesión.
/// Moving the TIME OF DAY was not: it overwrote an hour the user had chosen at
/// onboarding with whenever they last happened to meditate, and then showed
/// that new time back to them in Settings as if they had picked it.
///
/// Keep the date arithmetic, keep their hour. Falls back to the session-derived
/// anchor only when the user has never chosen a time.
DateTime anchorPreferringSavedTime(
  DateTime sessionAnchor,
  int? savedHour,
  int? savedMinute,
) {
  if (savedHour == null || savedMinute == null) return sessionAnchor;

  return DateTime(
    sessionAnchor.year,
    sessionAnchor.month,
    sessionAnchor.day,
    savedHour,
    savedMinute,
  );
}

/// Pref que marca que los avisos pendientes ya traen los textos y botones
/// nuevos (migración al actualizar la app).
const reminderSeriesCopyV2Key = 'reminder_series_copy_v2';

/// Ancla de la migración, guardada antes de tocar los avisos para que un
/// reintento use la misma fecha (hora local, sin zona).
const reminderSeriesMigrationAnchorKey = 'reminder_series_copy_v2_anchor';

/// Primer índice de la serie que reprograma la migración guardada.
const reminderSeriesMigrationFromKey = 'reminder_series_copy_v2_from';

const _migrationPendingIdsKey = 'reminder_series_copy_v2_pending_ids';

/// Regla única de «avisos encendidos» para Ajustes, la migración y la
/// reprogramación tras una sesión. Si nunca se guardó el interruptor, cuenta
/// como encendido cuando hay una hora guardada (instalaciones antiguas).
bool remindersActive(SharedPreferences prefs) {
  final enabled = prefs.getBool(SharedPreferenceConstants.dailyReminderEnabled);
  if (enabled != null) return enabled;
  return prefs.getInt(SharedPreferenceConstants.savedHours) != null &&
      prefs.getInt(SharedPreferenceConstants.savedMinutes) != null;
}

Future<void> _reminderChangesTail = Future<void>.value();

/// Corre los cambios de avisos de uno en uno: migración, Ajustes y
/// reprogramación tras una sesión. Cada cambio vuelve a leer las preferencias
/// ya dentro de su turno.
Future<T> serializeReminderChange<T>(Future<T> Function() change) {
  final result = _reminderChangesTail.then((_) => change());
  _reminderChangesTail = result.then<void>((_) {}, onError: (_) {});
  return result;
}

/// Fecha de un aviso: el día del calendario [dayOffset] días después del
/// ancla, a la hora del ancla. Se arma con día y hora locales, no sumando
/// bloques de 24 h, para que el cambio de horario no mueva el aviso una hora.
tz.TZDateTime reminderDateFor(DateTime anchorLocal, int dayOffset) {
  final location = tz.local;
  if (location.name != 'UTC') {
    return tz.TZDateTime(
      location,
      anchorLocal.year,
      anchorLocal.month,
      anchorLocal.day + dayOffset,
      anchorLocal.hour,
      anchorLocal.minute,
    );
  }
  // Sin zona del teléfono (iOS no la da), la hora local del sistema conoce
  // el cambio de horario; se convierte al mismo instante.
  return tz.TZDateTime.from(
    DateTime(
      anchorLocal.year,
      anchorLocal.month,
      anchorLocal.day + dayOffset,
      anchorLocal.hour,
      anchorLocal.minute,
    ),
    location,
  );
}

/// Próxima vez que el reloj marca [hour]:[minute] después de [now].
DateTime nextOccurrenceOf(int hour, int minute, DateTime now) {
  final today = DateTime(now.year, now.month, now.day, hour, minute);
  return today.isAfter(now)
      ? today
      : DateTime(now.year, now.month, now.day + 1, hour, minute);
}

class DailyRemindersService {
  final SharedPreferences prefs;
  final ReminderProvider reminders;

  DailyRemindersService({required this.prefs, required this.reminders});

  TimeOfDay? getSavedTime() {
    final savedHour = prefs.getInt(SharedPreferenceConstants.savedHours);
    final savedMinute = prefs.getInt(SharedPreferenceConstants.savedMinutes);
    if (savedHour == null || savedMinute == null) return null;

    return TimeOfDay(hour: savedHour, minute: savedMinute);
  }

  /// Turn reminders on without asking for a time (end-of-session card,
  /// permission repair on Home). Keeps the hour the user chose earlier
  /// (onboarding chips or Settings); only when none was ever saved does it
  /// fall back to "same time tomorrow". Returns the hour used.
  Future<TimeOfDay> enable({AppLocalizations? l10n}) =>
      serializeReminderChange(() async {
        final time = getSavedTime() ?? _computeDefaultTimeFromNow();
        await _enableAt(time, l10n: l10n);
        return time;
      });

  /// Turn reminders on at a time the user chose (Settings bottom sheet /
  /// onboarding chips), instead of the silent "same time tomorrow" default of
  /// [enable]. The series is anchored to the next occurrence of [time].
  Future<DateTime> enableAt(TimeOfDay time, {AppLocalizations? l10n}) =>
      serializeReminderChange(() => _enableAt(time, l10n: l10n));

  Future<DateTime> _enableAt(TimeOfDay time, {AppLocalizations? l10n}) async {
    await prefs.setBool(SharedPreferenceConstants.dailyReminderEnabled, true);
    await _saveTime(time);

    final now = DateTime.now();
    final candidate = DateTime(
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    // Mañana por día del calendario, no +24 h, para conservar la hora.
    final anchor = candidate.isBefore(now)
        ? DateTime(now.year, now.month, now.day + 1, time.hour, time.minute)
        : candidate;

    final scheduler = DailyRemindersScheduler(
      prefs: prefs,
      reminders: reminders,
    );
    await scheduler._scheduleFullSeries(anchor, l10n: l10n);

    return anchor;
  }

  Future<void> disable() => serializeReminderChange(() async {
    await prefs.setBool(SharedPreferenceConstants.dailyReminderEnabled, false);
    // Sin avisos no hay nada que migrar; un ancla vieja ya no sirve.
    await _clearMigrationAnchor(prefs);
    await prefs.remove(_migrationPendingIdsKey);
    await reminders.cancelDailyNotification();
    await reminders.cancelReminderSeries();
  });

  TimeOfDay _computeDefaultTimeFromNow() {
    final nowPlus24 = DateTime.now().add(const Duration(days: 1));
    return TimeOfDay(hour: nowPlus24.hour, minute: nowPlus24.minute);
  }

  Future<void> _saveTime(TimeOfDay time) async {
    await prefs.setInt(SharedPreferenceConstants.savedHours, time.hour);
    await prefs.setInt(SharedPreferenceConstants.savedMinutes, time.minute);
  }
}

class DailyRemindersScheduler {
  final SharedPreferences prefs;
  final ReminderProvider reminders;

  DailyRemindersScheduler({required this.prefs, required this.reminders});

  /// Programa la serie desde [anchorLocal]. Con [fromIndex] solo programa
  /// los avisos de ese índice en adelante (0–14 diarios, 15 el del día 30),
  /// cada uno en su mismo día de siempre respecto al ancla. Cada aviso
  /// reemplaza al de su mismo identificador; si uno falla, el anterior sigue.
  Future<void> scheduleSeriesFromAnchor(
    DateTime anchorLocal, {
    AppLocalizations? l10n,
    int fromIndex = 0,
  }) => serializeReminderChange(() async {
    if (fromIndex <= 0) {
      await _scheduleFullSeries(anchorLocal, l10n: l10n);
    } else {
      await _scheduleSeries(anchorLocal, l10n: l10n, fromIndex: fromIndex);
    }
  });

  /// La serie completa (índices 0–15). Si la migración sigue pendiente, guarda
  /// antes el ancla para que un arranque posterior reintente los que fallen;
  /// si todos quedaron, ya no queda ningún aviso viejo y la migración termina.
  Future<void> _scheduleFullSeries(
    DateTime anchorLocal, {
    AppLocalizations? l10n,
  }) async {
    final migrating = prefs.getBool(reminderSeriesCopyV2Key) != true;
    final replacedIds = {
      if (migrating)
        for (var i = 0; i <= reminderSeriesCount; i++) reminderSeriesBaseId + i,
    };
    if (migrating) {
      await _saveMigrationPendingIds(replacedIds);
      await _saveMigrationAnchor(prefs, anchorLocal, 0);
    }
    final result = await _scheduleSeries(anchorLocal, l10n: l10n);
    if (migrating) {
      await _checkMigration(replacedIds, result);
    }
  }

  /// Programa cada aviso sobre su mismo identificador, sin cancelar antes la
  /// serie: un aviso que falla conserva el que ya estaba. Con [notBefore]
  /// omite los que ya pasaron. Devuelve los identificadores intentados y los
  /// que fallaron.
  Future<({List<int> ids, Set<int> failed})> _scheduleSeries(
    DateTime anchorLocal, {
    AppLocalizations? l10n,
    int fromIndex = 0,
    DateTime? notBefore,
  }) async {
    final localizations = l10n ?? _getFallbackLocalizations();
    final items = <_SeriesItem>[];

    for (var i = fromIndex < 0 ? 0 : fromIndex; i < 15; i++) {
      final tzWhen = reminderDateFor(anchorLocal, i);
      final copy = _copyForDay(i + 1, l10n: localizations);
      items.add(
        _SeriesItem(
          id: reminderSeriesBaseId + i,
          when: tzWhen,
          title: copy.$1,
          body: copy.$2,
          payload: reminderPayload(i + 1),
        ),
      );
    }

    if (fromIndex <= 15) {
      final day30TzWhen = reminderDateFor(anchorLocal, 29);
      final day30Copy = _copyForDay(30, l10n: localizations);
      items.add(
        _SeriesItem(
          id: reminderSeriesBaseId + 15,
          when: day30TzWhen,
          title: day30Copy.$1,
          body: day30Copy.$2,
          payload: reminderPayload(30),
        ),
      );
    }

    if (notBefore != null) {
      items.removeWhere((e) => !e.when.isAfter(notBefore));
    }

    AppLogger.d(
      'REMINDER',
      'Scheduling daily reminder series from anchor: $anchorLocal',
    );

    try {
      await reminders.cancelDailyNotification();
    } catch (e, s) {
      AppLogger.e(
        'REMINDER',
        'Error cancelling daily notification before rescheduling: $e',
        s,
      );
    }

    final scheduledReminders = items
        .map(
          (e) => ScheduledReminder(
            id: e.id,
            scheduledDate: e.when,
            title: e.title,
            body: e.body,
            payload: e.payload,
            sitLabel: localizations.reminderActionSit3,
            notTodayLabel: localizations.reminderActionNotToday,
          ),
        )
        .toList();
    final ids = [for (final e in items) e.id];

    Set<int> failed;
    try {
      failed = await reminders.scheduleReminderSeries(scheduledReminders);
      AppLogger.d(
        'REMINDER',
        'Scheduled ${items.length - failed.length} of ${items.length} '
            'daily reminders',
      );
    } catch (e, s) {
      AppLogger.e('REMINDER', 'Error scheduling daily reminder series: $e', s);
      failed = ids.toSet();
    }

    final first = TimeOfDay(hour: anchorLocal.hour, minute: anchorLocal.minute);
    await prefs.setInt(SharedPreferenceConstants.savedHours, first.hour);
    await prefs.setInt(SharedPreferenceConstants.savedMinutes, first.minute);
    return (ids: ids, failed: failed);
  }

  /// Mueve la serie tras una sesión. Revisa dentro de su turno que los avisos
  /// sigan encendidos: Ajustes pudo apagarlos mientras esperaba.
  Future<void> rescheduleAfterSession({
    required int endMs,
    required int durationMs,
    AppLocalizations? l10n,
  }) => serializeReminderChange(() async {
    if (!remindersActive(prefs)) {
      AppLogger.d('REMINDER', 'Reminders off; not rescheduling after session');
      return;
    }
    final end = DateTime.fromMillisecondsSinceEpoch(endMs);
    final start = end.subtract(Duration(milliseconds: durationMs));
    final sessionAnchor = start
        .add(const Duration(days: 1))
        .subtract(const Duration(minutes: 10));
    final anchor = anchorPreferringSavedTime(
      sessionAnchor,
      prefs.getInt(SharedPreferenceConstants.savedHours),
      prefs.getInt(SharedPreferenceConstants.savedMinutes),
    );
    await _scheduleFullSeries(anchor, l10n: l10n);
  });

  /// Migración al actualizar (una vez): los avisos ya programados conservan
  /// los textos y botones con que se programaron. Reprograma desde el aviso
  /// pendiente más cercano para que el siguiente suene a la próxima hora
  /// guardada y los demás conserven su día.
  ///
  /// Guarda el ancla antes de tocar avisos y reemplaza cada uno por su
  /// identificador, así que un fallo deja el aviso viejo y el siguiente
  /// arranque reintenta con la misma ancla. Antes de terminar, confirma que
  /// los avisos nuevos estén pendientes y que no quede ningún aviso viejo.
  Future<void> migratePendingSeries({
    DateTime Function() now = DateTime.now,
    AppLocalizations? l10n,
  }) => serializeReminderChange(() => _migrate(now(), l10n));

  Future<void> _migrate(DateTime now, AppLocalizations? l10n) async {
    if (prefs.getBool(reminderSeriesCopyV2Key) == true) return;
    if (!remindersActive(prefs)) return;
    final hour = prefs.getInt(SharedPreferenceConstants.savedHours);
    final minute = prefs.getInt(SharedPreferenceConstants.savedMinutes);
    if (hour == null || minute == null) return;

    final pending = await _pendingSeriesIds();
    final savedIds = prefs
        .getStringList(_migrationPendingIdsKey)
        ?.map(int.tryParse)
        .nonNulls
        .toSet();
    final pendingReplacement = savedIds == null
        ? pending
        : pending.intersection(savedIds);
    final saved = _savedMigrationAnchor(prefs);
    DateTime anchor;
    int k;
    if (saved != null) {
      (anchor, k) = saved;
    } else {
      final indexes = [
        for (final id in pendingReplacement) id - reminderSeriesBaseId,
      ]..sort();
      if (indexes.isEmpty) {
        // Nada viejo que cambiar. No se marca: la próxima serie completa
        // (Ajustes o una sesión) la termina.
        AppLogger.d('REMINDER', 'No pending reminders to migrate');
        return;
      }

      k = indexes.first;
      final next = nextOccurrenceOf(hour, minute, now);
      // El ancla queda k días antes, por día del calendario, para que el
      // aviso k suene en la próxima hora guardada.
      // Solo queda el del día 30: Android no deja leer su fecha, así que se
      // pone una semana después de la próxima hora guardada (aproximación).
      anchor = k <= 14
          ? DateTime(next.year, next.month, next.day - k, hour, minute)
          : DateTime(next.year, next.month, next.day + 7 - 29, hour, minute);
    }
    await _saveMigrationPendingIds(pendingReplacement);
    if (saved == null) await _saveMigrationAnchor(prefs, anchor, k);

    final result = await _scheduleSeries(
      anchor,
      l10n: l10n,
      fromIndex: k,
      notBefore: now,
    );
    await _checkMigration(pendingReplacement, result);
    if (result.ids.isEmpty) {
      // Todas las fechas del ancla guardada ya pasaron: se vuelve a leer lo
      // pendiente en el siguiente arranque. Conserva los ids sin reemplazar.
      await _clearMigrationAnchor(prefs);
    }
  }

  Future<Set<int>> _pendingSeriesIds() async {
    final pending = await reminders.getPendingNotifications(
      rethrowErrors: true,
    );
    return {
      for (final item in pending)
        if (item.id >= reminderSeriesBaseId &&
            item.id <= reminderSeriesBaseId + reminderSeriesCount)
          item.id,
    };
  }

  Future<void> _saveMigrationPendingIds(Set<int> ids) async {
    final saved = await prefs.setStringList(_migrationPendingIdsKey, [
      for (final id in ids) id.toString(),
    ]);
    if (!saved) throw StateError('Could not save pending reminder IDs');
  }

  Future<void> _checkMigration(
    Set<int> pendingReplacement,
    ({List<int> ids, Set<int> failed}) result,
  ) async {
    final pending = await _pendingSeriesIds();
    final verified = result.ids
        .toSet()
        .difference(result.failed)
        .intersection(pending);
    final remaining = pendingReplacement
        .intersection(pending)
        .difference(verified);
    await _saveMigrationPendingIds(remaining);
    if (result.ids.isEmpty ||
        verified.length != result.ids.length ||
        remaining.isNotEmpty) {
      AppLogger.w('REMINDER', 'Reminder migration incomplete; will retry');
      return;
    }
    final saved = await prefs.setBool(reminderSeriesCopyV2Key, true);
    if (!saved) throw StateError('Could not finish reminder migration');
    await _clearMigrationAnchor(prefs);
    await prefs.remove(_migrationPendingIdsKey);
  }

  (String, String) _copyForDay(int day, {required AppLocalizations l10n}) {
    switch (day) {
      case 1:
        final variants = <(String, String)>[
          (l10n.reminderDay1TitleVar1, l10n.reminderDay1BodyVar1),
          (l10n.reminderDay1TitleVar2, l10n.reminderDay1BodyVar2),
          (l10n.reminderDay1TitleVar3, l10n.reminderDay1BodyVar3),
          (l10n.reminderDay1TitleVar4, l10n.reminderDay1BodyVar4),
          (l10n.reminderDay1TitleVar5, l10n.reminderDay1BodyVar5),
        ];
        final idx = DateTime.now().day % variants.length;
        return variants[idx];
      case 2:
        final variants = [
          (l10n.reminderDay2TitleVar1, l10n.reminderDay2BodyVar1),
          (l10n.reminderDay2TitleVar2, l10n.reminderDay2BodyVar2),
          (l10n.reminderDay2TitleVar3, l10n.reminderDay2BodyVar3),
          (l10n.reminderDay2TitleVar4, l10n.reminderDay2BodyVar4),
          (l10n.reminderDay2TitleVar5, l10n.reminderDay2BodyVar5),
        ];
        final idx = (DateTime.now().day + 1) % variants.length;
        return variants[idx];
      case 3:
        final variants = [
          (l10n.reminderDay3TitleVar1, l10n.reminderDay3BodyVar1),
          (l10n.reminderDay3TitleVar2, l10n.reminderDay3BodyVar2),
          (l10n.reminderDay3TitleVar3, l10n.reminderDay3BodyVar3),
          (l10n.reminderDay3TitleVar4, l10n.reminderDay3BodyVar4),
          (l10n.reminderDay3TitleVar5, l10n.reminderDay3BodyVar5),
        ];
        final idx = (DateTime.now().day + 2) % variants.length;
        return variants[idx];
      case 4:
        return (l10n.reminderDay4Title, l10n.reminderDay4Body);
      case 5:
        return (l10n.reminderDay5Title, l10n.reminderDay5Body);
      case 6:
        return (l10n.reminderDay6Title, l10n.reminderDay6Body);
      case 7:
        return (l10n.reminderDay7Title, l10n.reminderDay7Body);
      case 8:
        return (l10n.reminderDay8Title, l10n.reminderDay8Body);
      case 9:
        return (l10n.reminderDay9Title, l10n.reminderDay9Body);
      case 10:
        return (l10n.reminderDay10Title, l10n.reminderDay10Body);
      case 11:
        return (l10n.reminderDay11Title, l10n.reminderDay11Body);
      case 12:
        return (l10n.reminderDay12Title, l10n.reminderDay12Body);
      case 13:
        return (l10n.reminderDay13Title, l10n.reminderDay13Body);
      case 14:
        return (l10n.reminderDay14Title, l10n.reminderDay14Body);
      case 15:
        return (l10n.reminderDay15Title, l10n.reminderDay15Body);
      case 30:
        return (l10n.reminderDay30Title, l10n.reminderDay30Body);
      default:
        return (l10n.reminderDay11Title, l10n.reminderDay11Body);
    }
  }

  AppLocalizations _getFallbackLocalizations() {
    final locale = basicLocaleListResolution(
      WidgetsBinding.instance.platformDispatcher.locales,
      AppLocalizations.supportedLocales,
    );
    return lookupAppLocalizations(locale);
  }
}

class _SeriesItem {
  final int id;
  final tz.TZDateTime when;
  final String title;
  final String body;
  final String payload;

  _SeriesItem({
    required this.id,
    required this.when,
    required this.title,
    required this.body,
    required this.payload,
  });
}

Future<void> _saveMigrationAnchor(
  SharedPreferences prefs,
  DateTime anchorLocal,
  int fromIndex,
) async {
  // Componentes locales sin zona: al leerla vuelve a la misma hora local.
  final local = DateTime(
    anchorLocal.year,
    anchorLocal.month,
    anchorLocal.day,
    anchorLocal.hour,
    anchorLocal.minute,
  );
  await prefs.setString(
    reminderSeriesMigrationAnchorKey,
    local.toIso8601String(),
  );
  await prefs.setInt(reminderSeriesMigrationFromKey, fromIndex);
}

(DateTime, int)? _savedMigrationAnchor(SharedPreferences prefs) {
  final raw = prefs.getString(reminderSeriesMigrationAnchorKey);
  final from = prefs.getInt(reminderSeriesMigrationFromKey);
  if (raw == null || from == null) return null;
  final anchor = DateTime.tryParse(raw);
  if (anchor == null || anchor.isUtc || from < 0 || from > 15) return null;
  return (anchor, from);
}

Future<void> _clearMigrationAnchor(SharedPreferences prefs) async {
  await prefs.remove(reminderSeriesMigrationAnchorKey);
  await prefs.remove(reminderSeriesMigrationFromKey);
}
