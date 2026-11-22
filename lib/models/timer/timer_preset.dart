import 'package:flutter/widgets.dart' show StringCharacters;

import '../background_sounds/background_sounds_model.dart';
import 'timer_bell_settings.dart';
import 'timer_session.dart';
import 'timer_settings.dart';

const kMaxTimerPresets = 20;
const kMaxTimerPresetNameLength = 30;

class TimerPreset {
  const TimerPreset({
    required this.name,
    required this.settings,
    required this.sound,
  });

  final String name;
  final TimerSettings settings;
  final BackgroundSoundsModel? sound;

  Map<String, Object?> toJson() => {
    'name': name,
    'mode': settings.mode.name,
    'minutes': settings.minutes,
    'bells': settings.bells.toJson(),
    'extraTime': settings.extraTime,
    'sound': sound?.toJson(),
  };

  factory TimerPreset.fromJson(Map<String, Object?> json) {
    final name = (json['name'] as String).trim();
    final settings = TimerSettings(
      mode: TimerMode.values.byName(json['mode'] as String),
      minutes: json['minutes'] as int,
      bells: TimerBellSettings.fromJson(json['bells'] as Map<String, Object?>),
      extraTime: json['extraTime'] as bool,
    );
    if (!isValidName(name) ||
        !settings.canStart ||
        settings.minutes < 0 ||
        settings.minutes > kMaxTimerMinutes ||
        !json.containsKey('sound')) {
      throw const FormatException('Temporizador guardado inválido');
    }
    final sound = json['sound'] as Map<String, Object?>?;
    return TimerPreset(
      name: name,
      settings: settings,
      sound: sound == null ? null : BackgroundSoundsModel.fromJson(sound),
    );
  }

  static bool isValidName(String name) =>
      name.isNotEmpty && name.characters.length <= kMaxTimerPresetNameLength;
}
