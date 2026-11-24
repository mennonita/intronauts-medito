import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_stage.dart';

extension on Iterable<TimerBellCue> {
  List<int> get offsetsMs => map((cue) => cue.offsetMs).toList();
  int? get endOffsetMs =>
      where((cue) => cue.kind == TimerBellKind.end).firstOrNull?.offsetMs;
}

List<TimerBellCue> cues(
  int seconds, {
  TimerBellSettings settings = const TimerBellSettings(),
  TimerMode mode = TimerMode.countdown,
  bool extraTime = false,
  int seed = 7,
  int prepMs = 0,
  List<TimerStage> stages = const [],
  String Function(int minutesLeft)? spokenText,
}) => buildTimerBellCues(
  settings: settings,
  mode: mode,
  plannedDuration: Duration(seconds: seconds),
  extraTime: extraTime,
  seed: seed,
  prepMs: prepMs,
  stages: stages,
  spokenText: spokenText,
);

String spoken(int minutesLeft) => 'quedan $minutesLeft';

final _durationByAsset = {
  for (final sound in bellSounds) sound.assetKey: sound.durationMs,
};

/// Comprueba que entre grupos distintos queden 8 s de silencio audible.
void expectSilenceBetweenGroups(List<TimerBellCue> schedule, {String? reason}) {
  final bells = schedule.where((cue) => cue.kind != TimerBellKind.spoken);
  final sorted = bells.toList()
    ..sort((a, b) => a.offsetMs.compareTo(b.offsetMs));
  for (var i = 1; i < sorted.length; i++) {
    final previous = sorted[i - 1];
    final current = sorted[i];
    final duration = _durationByAsset[previous.assetKey]!;
    final sameGroup =
        previous.kind == current.kind &&
        previous.assetKey == current.assetKey &&
        current.offsetMs - previous.offsetMs == duration + 500;
    if (sameGroup) continue;
    expect(
      current.offsetMs - (previous.offsetMs + duration),
      greaterThanOrEqualTo(timerBellSpacingMs),
      reason: '${reason ?? ''} $previous -> $current',
    );
  }
}

void main() {
  const selections = TimerBellSettings(
    intervalMinutes: 1,
    randomCount: 1,
    startSound: 'cuenco_tibetano',
    endSound: 'campana_templo',
    intervalSound: 'bloque_madera',
    randomSound: 'diapason',
  );

  test(
    'guarda cuatro sonidos y usa la campana actual para valores antiguos',
    () {
      final json = selections.toJson();
      expect(TimerBellSettings.fromJson(json).toJson(), json);
      final legacy = Map<String, Object>.of(json)
        ..removeWhere((key, _) => key.endsWith('Sound'));
      expect(TimerBellSettings.fromJson(legacy).toJson(), {
        ...legacy,
        for (final key in json.keys.where((key) => key.endsWith('Sound')))
          key: defaultBellSoundId,
      });
      expect(
        TimerBellSettings.fromJson({...json, 'endSound': 'eliminado'}).endSound,
        defaultBellSoundId,
      );
    },
  );

  const repeatKeys = [
    'startRepeats',
    'endRepeats',
    'intervalRepeats',
    'randomRepeats',
  ];

  test('guarda y recupera las repeticiones de cada campana', () {
    final settings = selections.copyWith(
      startRepeats: 3,
      endRepeats: 2,
      intervalRepeats: 3,
      randomRepeats: 2,
    );
    final json = settings.toJson();
    expect(repeatKeys.map((key) => json[key]), [3, 2, 3, 2]);
    expect(TimerBellSettings.fromJson(json).toJson(), json);
  });

  test('usa una repetición por cada campo ausente en ajustes anteriores', () {
    final legacy = selections.toJson()
      ..removeWhere((key, _) => repeatKeys.contains(key));
    final restored = TimerBellSettings.fromJson(legacy).toJson();
    expect(restored, {...legacy, for (final key in repeatKeys) key: 1});
    expect(TimerBellSettings.fromJson({...legacy, 'endRepeats': 2}).toJson(), {
      ...restored,
      'endRepeats': 2,
    });
  });

  test('rechaza las repeticiones inválidas en cada campo', () {
    final json = selections.toJson();
    for (final key in repeatKeys) {
      for (final value in [0, 4, 1.0, '2', null]) {
        expect(
          () => TimerBellSettings.fromJson({...json, key: value}),
          throwsFormatException,
        );
      }
    }
  });

  test(
    'guarda la salida y los avisos hablados; los ajustes viejos usan sonido',
    () {
      final settings = selections.copyWith(
        output: TimerBellOutput.soundAndVibration,
        spokenCues: true,
      );
      final json = settings.toJson();
      expect(json['output'], 'soundAndVibration');
      expect(json['spokenCues'], isTrue);
      final restored = TimerBellSettings.fromJson(json);
      expect(restored.output, TimerBellOutput.soundAndVibration);
      expect(restored.spokenCues, isTrue);
      expect(restored.toJson(), json);

      final legacy = Map<String, Object?>.of(json)
        ..remove('output')
        ..remove('spokenCues');
      final old = TimerBellSettings.fromJson(legacy);
      expect(old.output, TimerBellOutput.sound);
      expect(old.spokenCues, isFalse);
      final odd = TimerBellSettings.fromJson({
        ...json,
        'output': 'telepatia',
        'spokenCues': 'sí',
      });
      expect(odd.output, TimerBellOutput.sound);
      expect(odd.spokenCues, isFalse);
      for (final output in TimerBellOutput.values) {
        expect(
          TimerBellSettings.fromJson({...json, 'output': output.name}).output,
          output,
        );
      }
    },
  );

  // decisión del dueño 2026-11-24: todas las campanas del temporizador son gratis.
  test('ninguna campana del temporizador es de pago', () {
    // El campo «premium» ya no existe en el catálogo.
    expect(bellSounds, hasLength(17));
  });

  test('cada repetición empieza cuando terminó la anterior', () {
    for (final sound in bellSounds) {
      expect(timerBellRepeatGapMs(sound), sound.durationMs + 500);
    }
    final assetKey = BellSound.resolve('bloque_madera').assetKey;
    expect(
      cues(
        60,
        settings: const TimerBellSettings(
          startSound: 'bloque_madera',
          startRepeats: 3,
          end: false,
        ),
      ),
      [
        for (final offset in [0, 1702, 3404])
          TimerBellCue(offset, TimerBellKind.start, assetKey),
      ],
    );
  });

  test('la campana del templo repetida tres veces va cada 15.5 s', () {
    final schedule = cues(
      600,
      settings: const TimerBellSettings(
        start: false,
        endSound: 'campana_templo',
        endRepeats: 3,
      ),
    );
    expect(schedule.offsetsMs, [600000, 615547, 631094]);
    expect(schedule.map((cue) => cue.kind), everyElement(TimerBellKind.end));
  });

  test('el cierre suena exacto al terminar, con o sin preparación', () {
    for (final prepMs in [0, 30000]) {
      expect(cues(60, prepMs: prepMs).offsetsMs, [prepMs, prepMs + 60000]);
      expect(
        cues(
          60,
          prepMs: prepMs,
          settings: const TimerBellSettings(start: false),
        ).endOffsetMs,
        prepMs + 60000,
      );
      expect(
        cues(
          180,
          prepMs: prepMs,
          extraTime: true,
          settings: const TimerBellSettings(endRepeats: 2),
        ).offsetsMs,
        [prepMs, prepMs + 180000, prepMs + 186500],
      );
    }
  });

  test('respeta las campanas de inicio y cierre por separado', () {
    expect(cues(60).offsetsMs, [0, 60000]);
    expect(
      cues(60, settings: const TimerBellSettings(start: false)).offsetsMs,
      [60000],
    );
    expect(cues(60, settings: const TimerBellSettings(end: false)).offsetsMs, [
      0,
    ]);
    expect(
      cues(
        60,
        settings: const TimerBellSettings(start: false, end: false),
      ).offsetsMs,
      isEmpty,
    );
  });

  test('en una sesión muy corta el inicio gana la colisión', () {
    expect(cues(10).offsetsMs, [0]);
    expect(cues(14).offsetsMs, [0, 14000]);
    expect(
      cues(10, settings: const TimerBellSettings(start: false)).offsetsMs,
      [10000],
    );
  });

  test('el cronómetro no tiene campana a la mitad y cierra a las 5 h', () {
    const mode = TimerMode.stopwatch;
    expect(
      cues(
        0,
        mode: mode,
        settings: const TimerBellSettings(start: false, end: false),
      ),
      isEmpty,
    );
    expect(cues(0, mode: mode).offsetsMs, [0, 18000000]);
    expect(cues(0, mode: mode, prepMs: 10000).offsetsMs, [10000, 18010000]);
    final all = cues(
      0,
      mode: mode,
      settings: const TimerBellSettings(randomCount: 10, spokenCues: true),
      spokenText: spoken,
    );
    expect(all.offsetsMs, [0, 18000000]);
    expect(all.map((cue) => cue.kind), isNot(contains(TimerBellKind.midpoint)));
    final intervals = cues(
      0,
      mode: mode,
      settings: const TimerBellSettings(intervalMinutes: 20),
    );
    expect(intervals.offsetsMs, [
      0,
      for (var k = 1; k <= 14; k++) 1200000 * k,
      18000000,
    ]);
  });

  test('repite las campanas de intervalo', () {
    const settings = TimerBellSettings(
      start: false,
      end: false,
      intervalSound: 'bloque_madera',
      intervalMinutes: 1,
      intervalRepeats: 2,
    );
    final assetKey = BellSound.resolve(settings.intervalSound).assetKey;
    expect(cues(180, settings: settings), [
      for (final offset in [60000, 61702, 120000, 121702])
        TimerBellCue(offset, TimerBellKind.interval, assetKey),
    ]);
  });

  test('el cierre tiene prioridad y los intervalos paran en lo previsto', () {
    const settings = TimerBellSettings(intervalMinutes: 1);
    expect(cues(180, settings: settings).offsetsMs, [0, 60000, 120000, 180000]);
    expect(cues(180, settings: settings, extraTime: true).offsetsMs, [
      0,
      60000,
      120000,
      180000,
    ]);
    // 120 s + 6 s de sonido + 8 s de silencio no caben antes de 133 s.
    expect(cues(133, settings: settings).offsetsMs, [0, 60000, 133000]);
    expect(cues(134, settings: settings).offsetsMs, [0, 60000, 120000, 134000]);
    expect(
      cues(
        188,
        settings: const TimerBellSettings(end: false, intervalMinutes: 1),
      ).offsetsMs,
      [0, 60000, 120000, 180000],
    );
    expect(cues(180, settings: settings, prepMs: 10000).offsetsMs, [
      10000,
      70000,
      130000,
      190000,
    ]);
  });

  test('un intervalo largo no se acerca al cierre (campana del templo)', () {
    const settings = TimerBellSettings(
      start: false,
      intervalMinutes: 1,
      intervalSound: 'campana_templo',
    );
    // 60 s + 15.047 s + 8 s = 83.047 s.
    expect(cues(83, settings: settings).offsetsMs, [83000]);
    expect(cues(84, settings: settings).offsetsMs, [60000, 84000]);
    expectSilenceBetweenGroups(cues(84, settings: settings));
  });

  test('todos los intervalos usan múltiplos de los minutos elegidos', () {
    for (final minutes in timerIntervalMinutes.skip(1)) {
      final offset = minutes * 60000;
      expect(
        cues(
          minutes * 180,
          settings: TimerBellSettings(
            start: false,
            end: false,
            intervalMinutes: minutes,
          ),
        ).offsetsMs,
        [offset, 2 * offset],
        reason: '$minutes',
      );
    }
  });

  group('sesión por partes', () {
    const stages = [
      TimerStage(
        kind: TimerStageKind.sit,
        minutes: 20,
        sound: 'cuenco_tibetano',
      ),
      TimerStage(
        kind: TimerStageKind.walk,
        minutes: 10,
        sound: 'bloque_madera',
        repeats: 2,
      ),
      TimerStage(kind: TimerStageKind.sit, minutes: 20, sound: 'diapason'),
    ];

    test(
      'cada parte suena con su campana y la primera reemplaza al inicio',
      () {
        for (final prepMs in [0, 30000]) {
          final schedule = cues(
            5,
            prepMs: prepMs,
            stages: stages,
            settings: const TimerBellSettings(startSound: 'kalimba'),
          );
          String asset(String id) => BellSound.resolve(id).assetKey;
          expect(schedule, [
            TimerBellCue(prepMs, TimerBellKind.stage, asset('cuenco_tibetano')),
            TimerBellCue(
              prepMs + 1200000,
              TimerBellKind.stage,
              asset('bloque_madera'),
            ),
            TimerBellCue(
              prepMs + 1201702,
              TimerBellKind.stage,
              asset('bloque_madera'),
            ),
            TimerBellCue(
              prepMs + 1800000,
              TimerBellKind.stage,
              asset('diapason'),
            ),
            TimerBellCue(prepMs + 3000000, TimerBellKind.end, asset('actual')),
          ]);
          expect(
            schedule.map((cue) => cue.kind),
            isNot(contains(TimerBellKind.start)),
          );
        }
      },
    );

    test(
      'la campana de la primera parte suena aunque el inicio esté apagado',
      () {
        final schedule = cues(
          5,
          stages: stages,
          settings: const TimerBellSettings(start: false, end: false),
        );
        expect(schedule.first.offsetMs, 0);
        expect(schedule.first.kind, TimerBellKind.stage);
      },
    );

    test('una sola parte o el cronómetro ignoran las partes', () {
      expect(cues(60, stages: stages.take(1).toList()).offsetsMs, [0, 60000]);
      expect(cues(0, mode: TimerMode.stopwatch, stages: stages).offsetsMs, [
        0,
        18000000,
      ]);
    });

    test('ni el azar ni los intervalos largos tapan un cambio de parte', () {
      const twoParts = [
        TimerStage(kind: TimerStageKind.sit, minutes: 1),
        TimerStage(kind: TimerStageKind.walk, minutes: 1),
      ];
      for (var seed = 0; seed < 100; seed++) {
        final schedule = cues(
          0,
          seed: seed,
          stages: twoParts,
          settings: const TimerBellSettings(
            randomCount: 10,
            randomSound: 'campana_templo',
          ),
        );
        expect(
          schedule.where((cue) => cue.kind == TimerBellKind.stage).offsetsMs,
          [0, 60000],
        );
        expect(schedule.endOffsetMs, 120000);
        final random = schedule.where(
          (cue) => cue.kind == TimerBellKind.random,
        );
        expect(random, isNotEmpty, reason: '$seed');
        for (final cue in random) {
          final audibleEnd = cue.offsetMs + 15047;
          final beforeStage = audibleEnd + timerBellSpacingMs <= 60000;
          final afterStage =
              cue.offsetMs >= 66000 + timerBellSpacingMs &&
              audibleEnd + timerBellSpacingMs <= 120000;
          expect(beforeStage || afterStage, isTrue, reason: '$seed $cue');
        }
        expectSilenceBetweenGroups(schedule, reason: '$seed');
      }

      final interval = cues(
        0,
        stages: twoParts,
        settings: const TimerBellSettings(
          intervalMinutes: 1,
          intervalSound: 'campana_templo',
        ),
      );
      expect(interval.map((cue) => cue.kind), [
        TimerBellKind.stage,
        TimerBellKind.stage,
        TimerBellKind.end,
      ]);
      expect(interval.offsetsMs, [0, 60000, 120000]);
    });
  });

  group('avisos hablados', () {
    const on = TimerBellSettings(spokenCues: true);
    List<TimerBellCue> spokenCues(List<TimerBellCue> schedule) =>
        schedule.where((cue) => cue.kind == TimerBellKind.spoken).toList();

    test('11 min sin intervalos: avisos a 1:00, 6:00 y 10:00', () {
      expect(spokenCues(cues(660, settings: on, spokenText: spoken)), [
        const TimerBellCue(60000, TimerBellKind.spoken, 'spoken:quedan 10'),
        const TimerBellCue(360000, TimerBellKind.spoken, 'spoken:quedan 5'),
        const TimerBellCue(600000, TimerBellKind.spoken, 'spoken:quedan 1'),
      ]);
    });

    test('apagados, sin texto o en cronómetro no hay avisos', () {
      expect(spokenCues(cues(660, spokenText: spoken)), isEmpty);
      expect(spokenCues(cues(660, settings: on)), isEmpty);
      expect(
        spokenCues(
          cues(0, mode: TimerMode.stopwatch, settings: on, spokenText: spoken),
        ),
        isEmpty,
      );
    });

    test('los límites 11, 6 y 2 min dan su aviso a 1:00 (más preparación)', () {
      for (final prepMs in [0, 30000]) {
        for (final (minutes, mark) in [(11, 10), (6, 5), (2, 1)]) {
          final schedule = spokenCues(
            cues(
              minutes * 60,
              settings: on,
              spokenText: spoken,
              prepMs: prepMs,
            ),
          );
          expect(schedule.where((cue) => cue.offsetMs == prepMs + 60000), [
            TimerBellCue(
              prepMs + 60000,
              TimerBellKind.spoken,
              'spoken:quedan $mark',
            ),
          ], reason: '$minutes min, prep $prepMs');
        }
      }
    });

    test('10, 5 y 1 min no tienen el aviso de su misma marca', () {
      for (final (minutes, mark) in [(10, 10), (5, 5), (1, 1)]) {
        final assets = spokenCues(
          cues(minutes * 60, settings: on, spokenText: spoken),
        ).map((cue) => cue.assetKey);
        expect(assets, isNot(contains('spoken:quedan $mark')));
      }
      expect(spokenCues(cues(60, settings: on, spokenText: spoken)), isEmpty);
      expect(
        spokenCues(cues(600, settings: on, spokenText: spoken)).offsetsMs,
        [300000, 540000],
      );
    });

    test(
      '2 min con campana cada minuto: suena la campana y se omite el aviso',
      () {
        final schedule = cues(
          120,
          prepMs: 10000,
          settings: on.copyWith(intervalMinutes: 1),
          spokenText: spoken,
        );
        expect(schedule.offsetsMs, [10000, 70000, 130000]);
        expect(schedule[1].kind, TimerBellKind.interval);
        expect(spokenCues(schedule), isEmpty);
      },
    );

    test('si chocan con un intervalo de 5 min se omiten, nunca se mueven', () {
      final schedule = cues(
        1200,
        settings: on.copyWith(intervalMinutes: 5),
        spokenText: spoken,
      );
      expect(
        schedule.where((cue) => cue.kind == TimerBellKind.interval).offsetsMs,
        [300000, 600000, 900000],
      );
      expect(spokenCues(schedule), [
        const TimerBellCue(1140000, TimerBellKind.spoken, 'spoken:quedan 1'),
      ]);
    });

    test('nunca quitan lugar a una campana al azar', () {
      for (var seed = 0; seed < 30; seed++) {
        const settings = TimerBellSettings(randomCount: 10);
        final without = cues(660, settings: settings, seed: seed);
        final with_ = cues(
          660,
          settings: settings.copyWith(spokenCues: true),
          seed: seed,
          spokenText: spoken,
        );
        expect(
          with_.where((cue) => cue.kind != TimerBellKind.spoken).toList(),
          without,
        );
      }
    });
  });

  test('el azar respeta la preparación y los márgenes', () {
    const settings = TimerBellSettings(
      start: false,
      end: false,
      randomCount: 10,
    );
    for (var seed = 0; seed < 50; seed++) {
      final offsets = cues(
        180,
        prepMs: 30000,
        seed: seed,
        settings: settings,
      ).offsetsMs;
      expect(offsets, isNotEmpty);
      for (final offset in offsets) {
        expect(offset, inInclusiveRange(60000, 180000), reason: '$seed');
      }
      for (var i = 1; i < offsets.length; i++) {
        expect(offsets[i] - offsets[i - 1], greaterThanOrEqualTo(14000));
      }
    }
  });

  test('el azar admite una sola opción o ninguna', () {
    const settings = TimerBellSettings(
      randomCount: 10,
      start: false,
      end: false,
    );
    expect(cues(60, settings: settings).offsetsMs, [30000]);
    expect(cues(59, settings: settings).offsetsMs, isEmpty);
  });

  test('el azar respeta el margen de las campanas fijas y la cuadrícula', () {
    const settings = TimerBellSettings(intervalMinutes: 1, randomCount: 10);
    final all = cues(180, settings: settings);
    final random = all
        .where((cue) => cue.kind == TimerBellKind.random)
        .offsetsMs;
    expect(random, isNotEmpty);
    expect(
      random.every(
        (offset) => offset >= 30000 && offset <= 150000 && offset % 1000 == 0,
      ),
      isTrue,
    );
    expectSilenceBetweenGroups(all);
  });

  test('la misma semilla reproduce las campanas', () {
    const settings = TimerBellSettings(randomCount: 10);
    expect(
      cues(600, settings: settings, seed: 100).offsetsMs,
      cues(600, settings: settings, seed: 100).offsetsMs,
    );
    expect(
      cues(600, settings: settings, seed: 100).offsetsMs,
      isNot(cues(600, settings: settings, seed: 101).offsetsMs),
    );
  });

  test('37 s impide completar ocho campanas y 38 s sí lo permite', () {
    final grid = [for (var second = 30; second <= 90; second++) second * 1000];
    final feasible = feasibleRandomBellSlots(grid, 8);
    expect(feasible, isNot(contains(37000)));
    expect(feasible, contains(38000));
    expect(feasible, [
      for (var window = 0; window < 8; window++)
        for (var delta = 0; delta <= 4; delta++)
          30000 + 8000 * window + delta * 1000,
    ]);
    final remaining = grid
        .where((slot) => (slot - 38000).abs() >= 8000)
        .toList();
    expect(feasibleRandomBellSlots(remaining, 7), isNotEmpty);
  });

  test('siempre alcanza el máximo y conserva ventanas y separaciones', () {
    for (var seed = 0; seed < 150; seed++) {
      final offsets = cues(
        120,
        seed: seed,
        settings: const TimerBellSettings(
          start: false,
          end: false,
          randomCount: 10,
        ),
      ).offsetsMs;
      // Cada campana dura 6 s y deja 8 s de silencio: caben cinco.
      expect(offsets, hasLength(5), reason: '$seed');
      for (var k = 0; k < offsets.length; k++) {
        expect(
          offsets[k],
          inInclusiveRange(30000 + 14000 * k, 34000 + 14000 * k),
        );
      }
    }
  });

  test('los grupos repetidos nunca se pisan', () {
    const settings = TimerBellSettings(
      intervalMinutes: 1,
      randomCount: 10,
      randomSound: 'bloque_madera',
      startRepeats: 3,
      endRepeats: 3,
      intervalRepeats: 3,
      randomRepeats: 3,
    );
    for (var seed = 0; seed < 150; seed++) {
      final schedule = cues(180, settings: settings, seed: seed);
      final random = schedule.where((cue) => cue.kind == TimerBellKind.random);
      expect(random, isNotEmpty, reason: '$seed');
      expect(random.length % 3, 0);
      expect(
        random.map((cue) => cue.assetKey),
        everyElement(BellSound.resolve(settings.randomSound).assetKey),
      );
      expectSilenceBetweenGroups(schedule, reason: '$seed');
    }
  });

  test('el azar exige espacio para el grupo completo en el margen final', () {
    const settings = TimerBellSettings(
      start: false,
      end: false,
      randomCount: 10,
      randomSound: 'bloque_madera',
      randomRepeats: 3,
    );
    expect(cues(63, settings: settings), isEmpty);
    expect(cues(64, settings: settings).offsetsMs, [30000, 31702, 33404]);
  });

  test('cada tipo usa su archivo', () {
    final schedule = cues(600, settings: selections);
    expect(schedule.map((cue) => cue.kind).toSet(), {
      TimerBellKind.start,
      TimerBellKind.interval,
      TimerBellKind.random,
      TimerBellKind.end,
    });
    for (final cue in schedule) {
      final id = switch (cue.kind) {
        TimerBellKind.start => selections.startSound,
        TimerBellKind.end => selections.endSound,
        TimerBellKind.interval => selections.intervalSound,
        TimerBellKind.random => selections.randomSound,
        _ => throw StateError('Campana inesperada'),
      };
      expect(cue.assetKey, BellSound.resolve(id).assetKey);
    }
    expect(schedule.endOffsetMs, 600000);
    expectSilenceBetweenGroups(schedule);
  });

  test('las campanas nuevas se guardan y se leen en JSON', () {
    for (final kind in TimerBellKind.values) {
      final cue = TimerBellCue(1000, kind, 'x');
      expect(TimerBellCue.fromJson(cue.toJson()), cue);
    }
    expect(isMandatoryTimerBell(TimerBellKind.stage), isTrue);
    expect(isMandatoryTimerBell(TimerBellKind.spoken), isFalse);
  });
}
