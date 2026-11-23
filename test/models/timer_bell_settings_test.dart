import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_session.dart';

extension on List<TimerBellCue> {
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
}) => buildTimerBellCues(
  settings: settings,
  mode: mode,
  plannedDuration: Duration(seconds: seconds),
  extraTime: extraTime,
  seed: seed,
);

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

  test('cada tipo usa su archivo y el cierre respeta su duración y margen', () {
    final schedule = cues(180, settings: selections);
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
        TimerBellKind.midpoint => throw StateError('Campana inesperada'),
      };
      expect(cue.assetKey, BellSound.resolve(id).assetKey);
    }
    expect(schedule.endOffsetMs, 164453);
    expect(cues(30, settings: selections).endOffsetMs, 15000);
    final midpoint = cues(
      0,
      settings: selections.copyWith(intervalMinutes: 0),
      mode: TimerMode.stopwatch,
    )[1];
    expect(midpoint.kind, TimerBellKind.midpoint);
    expect(
      midpoint.assetKey,
      BellSound.resolve(selections.intervalSound).assetKey,
    );
  });

  test('respeta las campanas de inicio y cierre por separado', () {
    expect(cues(60).offsetsMs, [0, 53500]);
    expect(
      cues(60, settings: const TimerBellSettings(start: false)).offsetsMs,
      [53500],
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

  test('un cierre corto usa la mitad y el inicio gana la colisión', () {
    expect(
      cues(10, settings: const TimerBellSettings(start: false)).endOffsetMs,
      5000,
    );
    expect(cues(10).offsetsMs, [0]);
    expect(cues(10).endOffsetMs, isNull);
    expect(cues(16, extraTime: true).offsetsMs, [0, 16000]);
  });

  test(
    'el cierre tiene prioridad y los intervalos paran en el tiempo previsto',
    () {
      const settings = TimerBellSettings(intervalMinutes: 1);
      expect(cues(180, settings: settings).offsetsMs, [
        0,
        60000,
        120000,
        173500,
      ]);
      expect(cues(180, settings: settings, extraTime: true).offsetsMs, [
        0,
        60000,
        120000,
        180000,
      ]);
      expect(cues(190, settings: settings).offsetsMs, [
        0,
        60000,
        120000,
        183500,
      ]);
      expect(cues(194, settings: settings).offsetsMs, [
        0,
        60000,
        120000,
        187500,
      ]);
      expect(
        cues(
          188,
          settings: const TimerBellSettings(end: false, intervalMinutes: 1),
        ).offsetsMs,
        [0, 60000, 120000, 180000],
      );
    },
  );

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

  test(
    'el cronómetro conserva las tres campanas o sustituye la de la mitad',
    () {
      const mode = TimerMode.stopwatch;
      expect(cues(0, mode: mode).offsetsMs, [0, 9000000, 17993500]);
      expect(
        cues(
          0,
          mode: mode,
          settings: const TimerBellSettings(
            start: false,
            end: false,
            randomCount: 10,
          ),
        ).offsetsMs,
        [9000000],
      );
      final intervals = cues(
        0,
        mode: mode,
        settings: const TimerBellSettings(intervalMinutes: 20),
      );
      expect(intervals.offsetsMs, [
        0,
        for (var k = 1; k <= 14; k++) 1200000 * k,
        17993500,
      ]);
    },
  );

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
    final all = cues(180, settings: settings).offsetsMs;
    final fixed = cues(
      180,
      settings: settings.copyWith(randomCount: 0),
    ).offsetsMs;
    final random = all.where((offset) => !fixed.contains(offset));
    expect(random, hasLength(10));
    expect(
      random.every(
        (offset) => offset >= 30000 && offset <= 150000 && offset % 1000 == 0,
      ),
      isTrue,
    );
    for (var i = 1; i < all.length; i++) {
      expect(all[i] - all[i - 1], greaterThanOrEqualTo(timerBellSpacingMs));
    }
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
      expect(offsets, hasLength(8), reason: '$seed');
      for (var k = 0; k < offsets.length; k++) {
        expect(
          offsets[k],
          inInclusiveRange(30000 + 8000 * k, 34000 + 8000 * k),
        );
        if (k > 0) {
          expect(offsets[k] - offsets[k - 1], greaterThanOrEqualTo(8000));
        }
      }
    }
  });
}
