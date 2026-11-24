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
      final ids = <String>{};
      for (final raw in rawPractices) {
        final practice = TimerHousePractice._fromJson(raw);
        if (practice == null ||
            ids.contains(practice.id) ||
            practice.toSettings() == null) {
          continue;
        }
        practices.add(practice);
        ids.add(practice.id);
        if (practices.length == 6) break;
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

  static TimerHousePractice? _fromJson(Object? json) {
    if (json is! Map || !json.keys.every(_practiceFields.contains)) {
      return null;
    }
    final id = json['id'];
    final name = _readPracticeText(json['name'], kMaxTimerPresetNameLength);
    if (id is! String ||
        !_practiceIdPattern.hasMatch(id) ||
        name == null ||
        name.isEmpty) {
      return null;
    }

    final description = _readPracticeText(json['description'], 300);
    if (json.containsKey('description') && description == null ||
        json.containsKey('soundId') &&
            _readPracticeText(json['soundId'], 100) == null) {
      return null;
    }

    return TimerHousePractice(
      id: id,
      name: name,
      description: description == '' ? null : description,
      raw: Map.unmodifiable(Map<String, Object?>.from(json)),
    );
  }

  String? get soundId {
    final id = _readPracticeText(raw['soundId'], 100);
    return id == '' ? null : id;
  }

  TimerSettings? toSettings() {
    final mode = switch (raw['mode']) {
      'countdown' => TimerMode.countdown,
      'stopwatch' => TimerMode.stopwatch,
      _ => null,
    };
    if (mode == null) return null;

    final rawMinutes = raw['minutes'];
    final rawExtraTime = raw['extraTime'];
    final rawPrep = raw['prepSeconds'];
    if (raw.containsKey('minutes') &&
            !_isIntegerInRange(rawMinutes, 0, kMaxTimerMinutes) ||
        raw.containsKey('extraTime') && rawExtraTime is! bool ||
        raw.containsKey('prepSeconds') &&
            !_isIntegerInRange(rawPrep, 0, kMaxTimerPrepSeconds)) {
      return null;
    }
    final minutes = (rawMinutes as num?)?.toInt() ?? 0;
    final extraTime = rawExtraTime == true;
    final bells = raw.containsKey('bells')
        ? _readBells(raw['bells'])
        : const TimerBellSettings();
    if (bells == null) return null;

    final rawStages = raw['stages'];
    final stages = <TimerStage>[];
    if (raw.containsKey('stages')) {
      if (rawStages is! List ||
          rawStages.length < kMinTimerStages ||
          rawStages.length > kMaxTimerStages ||
          mode == TimerMode.stopwatch ||
          extraTime ||
          minutes != 0) {
        return null;
      }
      for (final item in rawStages) {
        final stage = _readStage(item);
        if (stage == null) return null;
        stages.add(stage);
      }
    } else if (mode == TimerMode.stopwatch) {
      if (extraTime || minutes != 0) return null;
    }

    final settings = TimerSettings(
      mode: mode,
      minutes: minutes,
      extraTime: extraTime,
      prepSeconds: (rawPrep as num?)?.toInt() ?? 0,
      bells: bells,
      stages: List.unmodifiable(stages),
    );
    return settings.canStart ? settings : null;
  }

  Map<String, Object?> toJson() => {
    ...raw,
    'id': id,
    'name': name,
    if (description != null || raw.containsKey('description'))
      'description': description ?? '',
    if (raw.containsKey('soundId')) 'soundId': soundId ?? '',
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

const _practiceFields = {
  'id',
  'name',
  'description',
  'mode',
  'minutes',
  'extraTime',
  'prepSeconds',
  'bells',
  'stages',
  'soundId',
};
const _stageFields = {'kind', 'minutes', 'sound', 'repeats'};
final _practiceIdPattern = RegExp(r'^[a-z0-9-]{1,40}$');
final _invalidPracticeText = RegExp(r'[\x00\uD800-\uDFFF]', unicode: true);
// Los mismos espacios que recorta String.trim() en el servidor (JavaScript).
final _practiceWhitespace = RegExp(
  r'^[\x09-\x0D\x20\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+'
  r'|[\x09-\x0D\x20\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+$',
);
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
  if (json is! Map || !json.keys.every(_stageFields.contains)) return null;
  final kind = json['kind'];
  if (!TimerStageKind.values.any((value) => value.name == kind) ||
      !_isIntegerInRange(json['minutes'], 1, kMaxTimerMinutes) ||
      json.containsKey('sound') &&
          _readPracticeText(json['sound'], 40, trim: false) == null ||
      json.containsKey('repeats') &&
          !_isIntegerInRange(json['repeats'], 1, 3)) {
    return null;
  }
  return TimerStage.fromJson(json);
}

String? _readPracticeText(Object? value, int maxLength, {bool trim = true}) {
  if (value is! String || _invalidPracticeText.hasMatch(value)) return null;
  final text = trim ? value.replaceAll(_practiceWhitespace, '') : value;
  return text.length <= maxLength ? text : null;
}

bool _isIntegerInRange(Object? value, int min, int max) =>
    value is num && value >= min && value <= max && value == value.toInt();

TimerBellSettings? _readBells(Object? json) {
  if (json is! Map) return null;
  final settings = const TimerBellSettings().toJson();
  for (final MapEntry(:key, :value) in json.entries) {
    final valid = switch (key) {
      'start' || 'end' || 'spokenCues' => value is bool,
      'intervalMinutes' => timerIntervalMinutes.any(
        (minutes) => minutes == value,
      ),
      'randomCount' => _isIntegerInRange(value, 0, timerMaxRandomBells),
      'startSound' ||
      'endSound' ||
      'intervalSound' ||
      'randomSound' => _readPracticeText(value, 40, trim: false) != null,
      'startRepeats' || 'endRepeats' || 'intervalRepeats' || 'randomRepeats' =>
        timerBellRepeatOptions.any((repeats) => repeats == value),
      'output' => TimerBellOutput.values.any((output) => output.name == value),
      _ => false,
    };
    if (!valid) return null;
    settings[key as String] = value is num ? value.toInt() : value as Object;
  }
  return TimerBellSettings.fromJson(settings);
}
