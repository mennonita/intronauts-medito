import 'package:flutter/foundation.dart';
import 'package:medito/models/timer/last_timer_store.dart';
import 'package:medito/models/timer/timer_launch.dart';
import 'package:medito/utils/current_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'timer_device_channel.dart';

class TimerShortcutsService {
  static Future<void> refresh() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final l10n = currentLocalizations();
      final shortcuts = <TimerShortcut>[];
      for (final minutes in const [5, 10, 20]) {
        final label = l10n.timerShortcutMinutes(minutes);
        shortcuts.add(
          TimerShortcut(
            id: 'timer_$minutes',
            shortLabel: label,
            longLabel: label,
            uri: TimerLaunch(minutes: minutes).toUri(),
          ),
        );
      }
      if (LastTimerStore.read(prefs) != null) {
        final label = l10n.timerShortcutLast;
        shortcuts.add(
          TimerShortcut(
            id: 'timer_last',
            shortLabel: label,
            longLabel: label,
            uri: const TimerLaunch(last: true).toUri(),
          ),
        );
      }
      await TimerDeviceChannel.setShortcuts(shortcuts);
    } catch (_) {
      // Los atajos son opcionales durante el arranque y la reproducción.
    }
  }
}
