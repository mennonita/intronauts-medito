import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class TimerShortcut {
  const TimerShortcut({
    required this.id,
    required this.shortLabel,
    required this.longLabel,
    required this.uri,
  });

  final String id;
  final String shortLabel;
  final String longLabel;
  final Uri uri;

  Map<String, String> toMap() => {
    'id': id,
    'shortLabel': shortLabel,
    'longLabel': longLabel,
    'uri': uri.toString(),
  };
}

class TimerDeviceChannel {
  static const _channel = MethodChannel('intronauts/timer_device');

  @visibleForTesting
  static bool? debugIsAndroid;

  static Future<void> keepScreenOn(bool on) =>
      _invokeMethod<void>('keepScreenOn', {'on': on});

  static Future<double?> mediaVolumeFraction() async {
    final volume = await _invokeMethod<Map<Object?, Object?>>('mediaVolume');
    final current = volume?['current'];
    final max = volume?['max'];
    return current is int && max is int && max > 0 ? current / max : null;
  }

  static Future<void> setShortcuts(List<TimerShortcut> shortcuts) =>
      _invokeMethod<void>('setShortcuts', {
        'shortcuts': shortcuts.map((shortcut) => shortcut.toMap()).toList(),
      });

  static Future<void> vibrateBell(int repeats) =>
      _invokeMethod<void>('vibrateBell', {'repeats': repeats});

  static Future<String?> timeZoneId() => _invokeMethod<String>('timeZoneId');

  static Future<T?> _invokeMethod<T>(String method, [Object? arguments]) async {
    if (!(debugIsAndroid ?? Platform.isAndroid)) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
