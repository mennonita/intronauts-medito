import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/providers/notification/reminder_provider.dart'
    show androidNotificationIcon;
import 'package:medito/utils/current_localizations.dart';
import 'package:medito/utils/local_time_zone.dart';
import 'package:timezone/timezone.dart' as tz;

@immutable
class MindfulnessBellsConfig {
  const MindfulnessBellsConfig({
    this.enabled = false,
    this.startHour = 9,
    this.endHour = 18,
    this.everyHours = 2,
  });

  final bool enabled;
  final int startHour;
  final int endHour;
  final int everyHours;

  MindfulnessBellsConfig copyWith({
    bool? enabled,
    int? startHour,
    int? endHour,
    int? everyHours,
  }) => MindfulnessBellsConfig(
    enabled: enabled ?? this.enabled,
    startHour: startHour ?? this.startHour,
    endHour: endHour ?? this.endHour,
    everyHours: everyHours ?? this.everyHours,
  );
}

abstract interface class MindfulnessBellsNotifications {
  Future<void> cancel({required int id});

  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required DateTimeComponents matchDateTimeComponents,
    required AndroidScheduleMode androidScheduleMode,
  });
}

class MindfulnessBellsService {
  MindfulnessBellsService({
    MindfulnessBellsNotifications? notifications,
    Future<void> Function() initializeTimeZone = ensureLocalTimeZone,
    DateTime Function() now = DateTime.now,
    AppLocalizations Function() localizations = currentLocalizations,
  }) : _notifications = notifications ?? _LocalNotifications(),
       _initializeTimeZone = initializeTimeZone,
       _now = now,
       _localizations = localizations;

  static const _firstId = 7100;
  static const _hoursPerDay = 24;

  final MindfulnessBellsNotifications _notifications;
  final Future<void> Function() _initializeTimeZone;
  final DateTime Function() _now;
  final AppLocalizations Function() _localizations;

  static List<int> slots({
    required int startHour,
    required int endHour,
    required int everyHours,
  }) {
    if (startHour < 0 ||
        endHour > _hoursPerDay ||
        endHour <= startHour ||
        everyHours < 1) {
      return [];
    }

    final count = 1 + (endHour - startHour - 1) ~/ everyHours;
    return List.generate(count, (index) => startHour + index * everyHours);
  }

  Future<void> apply(MindfulnessBellsConfig config) async {
    await _initializeTimeZone();
    for (var offset = 0; offset < _hoursPerDay; offset++) {
      await _notifications.cancel(id: _firstId + offset);
    }
    if (!config.enabled) return;

    final hours = slots(
      startHour: config.startHour,
      endHour: config.endHour,
      everyHours: config.everyHours,
    );
    if (hours.isEmpty) return;

    final now = tz.TZDateTime.from(_now(), tz.local);
    final l10n = _localizations();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'mindfulness_bells',
        l10n.mindfulnessBellsTitle,
        icon: androidNotificationIcon,
        importance: Importance.defaultImportance,
        sound: const RawResourceAndroidNotificationSound('intronauts_bell'),
        playSound: true,
      ),
      iOS: const DarwinNotificationDetails(presentSound: true),
    );

    for (var index = 0; index < hours.length; index++) {
      await _notifications.zonedSchedule(
        id: _firstId + index,
        title: l10n.mindfulnessBellNotificationTitle,
        body: l10n.mindfulnessBellNotificationBody,
        scheduledDate: _nextOccurrence(now, hours[index]),
        notificationDetails: details,
        matchDateTimeComponents: DateTimeComponents.time,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  static tz.TZDateTime _nextOccurrence(tz.TZDateTime now, int hour) {
    final location = now.location;
    final today = tz.TZDateTime(location, now.year, now.month, now.day, hour);
    if (today.isAfter(now)) return today;

    // Avanza la fecha local aunque cambie el horario de verano esa noche.
    return tz.TZDateTime(location, now.year, now.month, now.day + 1, hour);
  }
}

class _LocalNotifications implements MindfulnessBellsNotifications {
  final _plugin = FlutterLocalNotificationsPlugin();

  @override
  Future<void> cancel({required int id}) => _plugin.cancel(id: id);

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required DateTimeComponents matchDateTimeComponents,
    required AndroidScheduleMode androidScheduleMode,
  }) => _plugin.zonedSchedule(
    id: id,
    title: title,
    body: body,
    scheduledDate: scheduledDate,
    notificationDetails: notificationDetails,
    matchDateTimeComponents: matchDateTimeComponents,
    androidScheduleMode: androidScheduleMode,
  );
}
