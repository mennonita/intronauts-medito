import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_house_content.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_settings.dart';

TimerHousePractice _practice(Map<String, Object?> raw) =>
    TimerHousePractice(id: 'quietud', name: 'Quietud', raw: raw);

Map<String, Object?> _stage(int minutes) => {'kind': 'sit', 'minutes': minutes};

void main() {
  test('lee el contenido completo y lo puede volver a leer', () {
    final content = TimerHouseContent.fromJson({
      'closingText': ' Gracias. ',
      'openingText': ' Haz una pausa.\n',
      'words': {
        'timer': ' Reloj ',
        'stopwatch': 'Cronómetro',
        'counter': 'Contador',
        'session': 'práctica',
      },
      'practiceDays': [
        {'date': '2028-02-29', 'text': '  Día de práctica.\n'},
      ],
      'practices': [
        {
          'id': ' quietud ',
          'name': ' Quietud ',
          'description': ' Siéntate con calma. ',
          'mode': 'countdown',
          'minutes': 10,
          'prepSeconds': 120,
          'extraTime': true,
          'bells': const TimerBellSettings(
            start: false,
            endSound: 'handpan',
          ).toJson(),
          'soundId': ' lluvia ',
        },
      ],
      'beadsPerRound': 54,
    });
    expect(content.closingText, 'Gracias.');
    expect(content.openingText, 'Haz una pausa.');
    expect(content.words, {
      HouseWord.timer: 'Reloj',
      HouseWord.stopwatch: 'Cronómetro',
      HouseWord.counter: 'Contador',
      HouseWord.session: 'práctica',
    });
    expect(content.practiceDays.single.date, '2028-02-29');
    expect(content.practiceDays.single.text, 'Día de práctica.');
    final practice = content.practices.single;
    expect(practice.id, 'quietud');
    expect(practice.name, 'Quietud');
    expect(practice.description, 'Siéntate con calma.');
    expect(practice.soundId, 'lluvia');
    final settings = practice.toSettings()!;
    expect(settings.mode, TimerMode.countdown);
    expect(settings.minutes, 10);
    expect(settings.prepSeconds, 120);
    expect(settings.extraTime, isTrue);
    expect(settings.bells.start, isFalse);
    expect(settings.bells.endSound, 'handpan');
    expect(content.beadsPerRound, 54);

    final restored = TimerHouseContent.fromJson(
      jsonDecode(jsonEncode(content.toJson())),
    );
    expect(restored.toJson(), content.toJson());
  });

  test('un servidor anterior solo trae texto de cierre', () {
    final content = TimerHouseContent.fromJson({'closingText': 'Gracias.'});
    expect(content.closingText, 'Gracias.');
    expect(content.openingText, isNull);
    expect(content.words, isEmpty);
    expect(content.practiceDays, isEmpty);
    expect(content.practices, isEmpty);
    expect(content.beadsPerRound, 108);
  });

  test('los tipos incorrectos usan los valores por defecto', () {
    const empty = TimerHouseContent.empty();
    for (final json in [
      null,
      1,
      'texto',
      [],
      {
        'closingText': 2,
        'openingText': false,
        'words': [],
        'practiceDays': 'hoy',
        'practices': {},
        'beadsPerRound': '108',
      },
    ]) {
      expect(TimerHouseContent.fromJson(json).toJson(), empty.toJson());
    }
    for (final beads in [0, 1001, 108.0]) {
      expect(
        TimerHouseContent.fromJson({'beadsPerRound': beads}).beadsPerRound,
        108,
      );
    }
    for (final beads in [1, 1000]) {
      expect(
        TimerHouseContent.fromJson({'beadsPerRound': beads}).beadsPerRound,
        beads,
      );
    }
  });

  test('descarta campos inválidos sin quitar los elementos válidos', () {
    final content = TimerHouseContent.fromJson({
      'closingText': '  ',
      'openingText': 'a' * 501,
      'words': {
        'timer': 'a' * 24,
        'stopwatch': 'a' * 25,
        'counter': '',
        'session': 3,
        'other': 'otro',
      },
      'practiceDays': [
        2,
        {'date': '2026-2-01', 'text': 'Día'},
        {'date': '2026-02-29', 'text': 'Día'},
        {'date': '2026-04-31', 'text': 'Día'},
        {'date': '2026-01-01T00:00:00Z', 'text': 'Día'},
        {'date': '2026-01-01', 'text': '   '},
        {'date': '2026-01-01', 'text': 'a' * 141},
        {'date': '2026-01-01', 'text': 'Día válido'},
      ],
      'practices': [
        null,
        {'name': 'Sin id', 'mode': 'stopwatch'},
        {'id': 'sin-nombre', 'name': 5, 'mode': 'stopwatch'},
        {'id': 'a' * 41, 'name': 'Id largo', 'mode': 'stopwatch'},
        {'id': 'a', 'name': 'a' * 31, 'mode': 'stopwatch'},
        {'id': 'sin-modo', 'name': 'Sin modo'},
        {'id': 'larga', 'name': 'Larga', 'mode': 'countdown', 'minutes': 300},
        {
          'id': 'valida',
          'name': 'Válida',
          'description': 'a' * 301,
          'mode': 'stopwatch',
          'prepSeconds': '30',
          'extraTime': 'sí',
          'bells': {'start': 5},
          'soundId': 'a' * 101,
        },
      ],
    });
    expect(content.closingText, isNull);
    expect(content.openingText, isNull);
    expect(content.words, {HouseWord.timer: 'a' * 24});
    expect(content.practiceDays.single.text, 'Día válido');
    final practice = content.practices.single;
    expect(practice.description, isNull);
    expect(practice.soundId, isNull);
    final settings = practice.toSettings()!;
    expect(settings.mode, TimerMode.stopwatch);
    expect(settings.minutes, 0);
    expect(settings.prepSeconds, 0);
    expect(settings.extraTime, isFalse);
    expect(settings.bells.toJson(), const TimerBellSettings().toJson());
  });

  test('acepta 299 minutos por bloque o repartidos en etapas', () {
    expect(
      _practice({'mode': 'countdown', 'minutes': 299}).toSettings()?.minutes,
      299,
    );

    final settings = _practice({
      'mode': 'countdown',
      'minutes': 0,
      'prepSeconds': 7201,
      'stages': [
        _stage(150),
        false,
        _stage(0),
        {'kind': 'otro', 'minutes': 10},
        {'kind': 'walk', 'minutes': 149, 'sound': 'desconocido'},
      ],
    }).toSettings()!;
    expect(settings.isMultiStage, isTrue);
    expect(settings.stagesTotalMinutes, 299);
    expect(settings.prepSeconds, 7200);
    expect(settings.stages.last.kind, TimerStageKind.walk);
    expect(settings.stages.last.sound, defaultBellSoundId);
  });

  test('rechaza combinaciones que el servidor tampoco acepta', () {
    final twoStages = [_stage(150), _stage(149)];
    for (final raw in <Map<String, Object?>>[
      {},
      {'mode': 'countdown'},
      {'mode': 'countdown', 'minutes': 0},
      {'mode': 'countdown', 'minutes': -1},
      {'mode': 'countdown', 'minutes': 300},
      {'mode': 'countdown', 'minutes': 1, 'stages': twoStages},
      {
        'mode': 'countdown',
        'stages': [_stage(150), _stage(150)],
      },
      {
        'mode': 'countdown',
        'stages': [_stage(1)],
      },
      {'mode': 'countdown', 'stages': List.filled(7, _stage(1))},
      {'mode': 'countdown', 'stages': twoStages, 'extraTime': true},
      {'mode': 'stopwatch', 'stages': twoStages},
      {'mode': 'stopwatch', 'stages': []},
      {'mode': 'stopwatch', 'extraTime': true},
      {'mode': 'stopwatch', 'minutes': 1},
    ]) {
      expect(_practice(raw).toSettings(), isNull, reason: '$raw');
    }
  });

  test('usa la palabra predeterminada y el primer día que coincide', () {
    final content = TimerHouseContent.fromJson({
      'words': {'session': 'práctica'},
      'practiceDays': [
        {'date': '2026-11-24', 'text': 'Primero'},
        {'date': '2026-11-24', 'text': 'Segundo'},
      ],
    });
    expect(houseWord(content, HouseWord.session, 'sesión'), 'práctica');
    expect(houseWord(content, HouseWord.timer, 'temporizador'), 'temporizador');
    expect(
      practiceDayFor(content, DateTime(2026, 11, 24, 23))?.text,
      'Primero',
    );
    expect(practiceDayFor(content, DateTime(2026, 11, 25)), isNull);
  });
}
