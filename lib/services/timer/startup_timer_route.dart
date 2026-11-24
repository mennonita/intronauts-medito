import 'dart:async';

import 'package:flutter/material.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/models/timer/timer_launch.dart';
import 'package:medito/providers/timer/timer_preferences_provider.dart';
import 'package:medito/services/deep_link_service.dart';
import 'package:medito/services/reminders/reminder_launch_action.dart';
import 'package:medito/services/timer/timer_route_tracker.dart';
import 'package:medito/views/timer/timer_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StartupTimerRoute {
  static bool _started = false;

  @visibleForTesting
  static void resetForTesting() => _started = false;

  static Future<void> runOnce(
    NavigatorState navigator, {
    Future<void>? initialLinkProcessed,
    bool Function()? hadInitialLink,
    Future<void> Function() migrateReminders = ReminderSeriesMigration.runOnce,
    Future<TimerLaunch?> Function() takeReminderLaunch =
        ReminderLaunchAction.take,
  }) async {
    if (_started) return;
    _started = true;

    await (initialLinkProcessed ?? DeepLinkService.initialLinkProcessed);
    unawaited(migrateReminders());
    if (!navigator.mounted ||
        (hadInitialLink?.call() ?? DeepLinkService.hadInitialLink)) {
      return;
    }

    final launch = await takeReminderLaunch();
    if (launch == null) {
      final prefs = await SharedPreferences.getInstance();
      if (!TimerPreferences.read(prefs).openOnTimer ||
          TimerRouteTracker.openTimerViews != 0) {
        return;
      }
    }
    if (!navigator.mounted) return;

    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => TimerView(
            source: launch == null
                ? AnalyticsEventConstants.sourceTimerOnly
                : AnalyticsEventConstants.sourceReminderAction,
            launch: launch,
          ),
        ),
      ),
    );
  }
}
