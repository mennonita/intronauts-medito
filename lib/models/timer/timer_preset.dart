import 'package:flutter/widgets.dart' show StringCharacters;

import '../background_sounds/background_sounds_model.dart';
import 'timer_bell_settings.dart';
import 'timer_session.dart';
import 'timer_settings.dart';

const kMaxTimerPresets = 20;
const kMaxTimerPresetNameLength = 30;

class TimerPreset {
  const TimerPreset({
    this.id = '',
    required this.name,
    required this.settings,
    required this.sound,
  });

  /// Identificador estable: las operaciones lo usan en vez de la posición.
  final String id;
  final String name;
  final TimerSettings settings;
  final BackgroundSoundsModel? sound;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    ...settings.toSnapshotJson(),
    'sound': sound?.toJson(),
  };

  factory TimerPreset.fromJson(Map<String, Object?> json) {
    final name = (json['name'] as String).trim();
    final settings = TimerSettings(
      mode: TimerMode.values.byName(json['mode'] as String),
      minutes: json['minutes'] as int,
      bells: TimerBellSettings.fromJson(json['bells'] as Map<String, Object?>),
      extraTime: json['extraTime'] as bool,
      // Temporizadores anteriores no traen preparación ni partes.
      prepSeconds: timerPrepSecondsFromJson(json['prepSeconds']),
      stages: timerStagesFromJson(json['stages']),
    );
    if (!isValidName(name) ||
        !settings.canStart ||
        settings.minutes < 0 ||
        settings.minutes > kMaxTimerMinutes ||
        !json.containsKey('sound')) {
      throw const FormatException('Temporizador guardado inválido');
    }
    final sound = json['sound'] as Map<String, Object?>?;
    final id = json['id'];
    return TimerPreset(
      // Temporizadores anteriores no traen id; el proveedor les asigna uno.
      id: id is String ? id : '',
      name: name,
      settings: settings,
      sound: sound == null ? null : BackgroundSoundsModel.fromJson(sound),
    );
  }

  TimerPreset copyWith({
    String? id,
    String? name,
    TimerSettings? settings,
    BackgroundSoundsModel? sound,
    bool clearSound = false,
  }) => TimerPreset(
    id: id ?? this.id,
    name: name ?? this.name,
    settings: settings ?? this.settings,
    sound: clearSound ? null : sound ?? this.sound,
  );

  static bool isValidName(String name) =>
      name.isNotEmpty && name.characters.length <= kMaxTimerPresetNameLength;
}
