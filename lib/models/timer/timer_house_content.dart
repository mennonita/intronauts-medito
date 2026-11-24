import 'timer_bell_settings.dart';
import 'timer_preset.dart';
import 'timer_session.dart';
import 'timer_settings.dart';

enum HouseWord { timer, stopwatch, counter, session }

class TimerHouseContent {
  const TimerHouseContent._({
    required this.closingText,
    required this.openingText,
    required this.words,
    required this.practiceDays,
    required this.practices,
    required this.beadsPerRound,
  });

  const TimerHouseContent.empty()
    : this._(
        closingText: null,
        openingText: null,
        words: const {},
        practiceDays: const [],
        practices: const [],
        beadsPerRound: 108,
      );

  final String? closingText;
  final String? openingText;
  final Map<HouseWord, String> words;
  final List<TimerHouseDay> practiceDays;
  final List<TimerHousePractice> practices;
  final int beadsPerRound;

  factory TimerHouseContent.fromJson(Object? json) {
    if (json is! Map) return const TimerHouseContent.empty();

    final words = <HouseWord, String>{};
    final rawWords = json['words'];
    if (rawWords is Map) {
      for (final word in HouseWord.values) {
        final text = _readText(rawWords[word.name], maxLength: 24);
        if (text != null) words[word] = text;
      }
    }

    final days = <TimerHouseDay>[];
    final rawDays = json['practiceDays'];
    if (rawDays is List) {
      for (final raw in rawDays) {
        if (raw is! Map) continue;
        final date = _readText(raw['date'], maxLength: 10);
        final text = _readText(raw['text'], maxLength: 140);
        if (date != null && text != null && _isCalendarDate(date)) {
          days.add(TimerHouseDay(date: date, text: text));
        }
      }
    }

    final practices = <TimerHousePractice>[];
    final rawPractices = json['practices'];
    if (rawPractices is List) {
      for (final raw in rawPractices) {
        if (raw is! Map) continue;
        final id = _readText(raw['id'], maxLength: 40);
        final name = _readText(
          raw['name'],
          maxLength: kMaxTimerPresetNameLength,
        );
        if (id == null || name == null || !_practiceIdPattern.hasMatch(id)) {
          continue;
        }
        final practice = TimerHousePractice(
          id: id,
          name: name,
          description: _readText(raw['description'], maxLength: 300),
          raw: Map.unmodifiable({
            for (final entry in raw.entries)
              if (entry.key is String) entry.key as String: entry.value,
          }),
        );
        if (practice.toSettings() != null) practices.add(practice);
      }
    }

    final beads = json['beadsPerRound'];
    return TimerHouseContent._(
      closingText: _readText(json['closingText']),
      openingText: _readText(json['openingText'], maxLength: 500),
      words: Map.unmodifiable(words),
      practiceDays: List.unmodifiable(days),
      practices: List.unmodifiable(practices),
      beadsPerRound: beads is int && beads >= 1 && beads <= 1000 ? beads : 108,
    );
  }

  Map<String, Object?> toJson() => {
    'closingText': closingText,
    'openingText': openingText,
    'words': {for (final entry in words.entries) entry.key.name: entry.value},
    'practiceDays': [
      for (final day in practiceDays) {'date': day.date, 'text': day.text},
    ],
    'practices': [for (final practice in practices) practice.toJson()],
    'beadsPerRound': beadsPerRound,
  };
}

class TimerHouseDay {
  const TimerHouseDay({required this.date, required this.text});

  final String date;
  final String text;
}

class TimerHousePractice {
  const TimerHousePractice({
    required this.id,
    required this.name,
    this.description,
    required this.raw,
  });

  final String id;
  final String name;
  final String? description;
  final Map<String, Object?> raw;

  String? get soundId => _readText(raw['soundId'], maxLength: 100);

  TimerSettings? toSettings() {
    final mode = switch (raw['mode']) {
      'countdown' => TimerMode.countdown,
      'stopwatch' => TimerMode.stopwatch,
      _ => null,
    };
    if (mode == null) return null;

    final rawMinutes = raw['minutes'];
    final minutes = rawMinutes is int ? rawMinutes : 0;
    final extraTime = raw['extraTime'] == true;
    final rawStages = raw['stages'];
    final stages = <TimerStage>[];
    if (rawStages is List) {
      if (mode == TimerMode.stopwatch || extraTime || minutes != 0) return null;
      for (final item in rawStages) {
        final stage = _readStage(item);
        if (stage == null) continue;
        stages.add(stage);
        if (stages.length > kMaxTimerStages) return null;
      }
      if (stages.length < kMinTimerStages) return null;
    } else if (mode == TimerMode.stopwatch) {
      if (extraTime || minutes != 0) return null;
    } else if (minutes < 1 || minutes > kMaxTimerMinutes) {
      return null;
    }

    final settings = TimerSettings(
      mode: mode,
      minutes: minutes,
      extraTime: extraTime,
      prepSeconds: timerPrepSecondsFromJson(raw['prepSeconds']),
      bells: _readBells(raw['bells']),
      stages: List.unmodifiable(stages),
    );
    return settings.canStart ? settings : null;
  }

  Map<String, Object?> toJson() => {
    ...raw,
    'id': id,
    'name': name,
    'description': description,
    'soundId': soundId,
  };
}

String houseWord(TimerHouseContent content, HouseWord key, String fallback) =>
    content.words[key] ?? fallback;

TimerHouseDay? practiceDayFor(TimerHouseContent content, DateTime localNow) {
  final year = localNow.year.toString().padLeft(4, '0');
  final month = localNow.month.toString().padLeft(2, '0');
  final day = localNow.day.toString().padLeft(2, '0');
  final date = '$year-$month-$day';
  for (final practiceDay in content.practiceDays) {
    if (practiceDay.date == date) return practiceDay;
  }
  return null;
}

final _practiceIdPattern = RegExp(r'^[a-z0-9-]+$');
final _datePattern = RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$');

bool _isCalendarDate(String date) =>
    _datePattern.hasMatch(date) &&
    (DateTime.tryParse(
          '${date}T00:00:00Z',
        )?.toIso8601String().startsWith('${date}T') ??
        false);

String? _readText(Object? value, {int? maxLength}) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || (maxLength != null && text.length > maxLength)) {
    return null;
  }
  return text;
}

TimerStage? _readStage(Object? json) {
  if (json is! Map) return null;
  final kind = json['kind'];
  final minutes = json['minutes'];
  if (!TimerStageKind.values.any((value) => value.name == kind) ||
      minutes is! int ||
      minutes < 1 ||
      minutes > kMaxTimerMinutes) {
    return null;
  }
  return TimerStage.fromJson(json);
}

TimerBellSettings _readBells(Object? json) {
  if (json is Map) {
    try {
      return TimerBellSettings.fromJson(Map<String, Object?>.from(json));
    } catch (_) {
      return const TimerBellSettings();
    }
  }
  return const TimerBellSettings();
}
