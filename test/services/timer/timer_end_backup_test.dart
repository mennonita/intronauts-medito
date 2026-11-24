import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/services/timer/timer_end_backup.dart';
import 'package:timezone/timezone.dart' as tz;

class _Scheduler implements TimerEndBackupScheduler {
  final scheduled = <({int id, tz.TZDateTime at, bool sound})>[];
  final cancelled = <int>[];

  @override
  Future<void> schedule({
    required int id,
    required tz.TZDateTime at,
    required String title,
    required String body,
    required bool sound,
  }) async => scheduled.add((id: id, at: at, sound: sound));

  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TimerEndBackup.ensureTimeZones();

  final start = tz.TZDateTime.utc(2026, 11, 24, 10);
  late _Scheduler scheduler;
  late TimerEndBackup backup;

  setUp(() {
    scheduler = _Scheduler();
    backup = TimerEndBackup(scheduler: scheduler, now: () => start);
  });

  final countdown = timerPlaybackRequest(
    mode: TimerMode.countdown,
    duration: const Duration(seconds: 60),
    filePath: '/tmp/timer.wav',
    title: 'Temporizador',
  ).copyWith(timerPrepMs: 120000);

  test('el aviso incluye la preparación: 120 s + 60 s → 190 s', () async {
    final remaining = PlayerProvider.iosBackupRemaining(
      countdown,
      0,
      endPassed: false,
    );
    expect(remaining, const Duration(seconds: 180));
    await backup.schedule(remaining: remaining!, minutes: 1, output: 'sound');
    final notice = scheduler.scheduled.single;
    expect(notice.id, TimerEndBackup.notificationId);
    expect(notice.at.difference(start), const Duration(seconds: 190));
    expect(notice.sound, isTrue);
  });

  test('al reanudar se calcula desde la posición actual', () {
    expect(
      PlayerProvider.iosBackupRemaining(countdown, 150000, endPassed: false),
      const Duration(seconds: 30),
    );
  });

  test('solo vibración programa un aviso sin sonido', () async {
    await backup.schedule(
      remaining: const Duration(seconds: 5),
      minutes: 1,
      output: 'vibration',
    );
    expect(scheduler.scheduled.single.sound, isFalse);
  });

  for (final endBell in [true, false]) {
    test('en tiempo extra no se programa nada (campana final: $endBell)', () {
      final extra = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(seconds: 60),
        filePath: '/tmp/timer.wav',
        title: 'Temporizador',
        extraTime: true,
      ).copyWith(timerPrepMs: 120000, timerEndBellEnabled: endBell);
      // Pausa y reanuda pasado el final.
      expect(
        PlayerProvider.iosBackupRemaining(extra, 200000, endPassed: false),
        isNull,
      );
      expect(
        PlayerProvider.iosBackupRemaining(extra, 200000, endPassed: true),
        isNull,
      );
    });
  }

  test('ya pasado el final no se vuelve a programar', () {
    expect(
      PlayerProvider.iosBackupRemaining(countdown, 1000, endPassed: true),
      isNull,
    );
  });

  test('el cronómetro no tiene aviso', () {
    final stopwatch = timerPlaybackRequest(
      mode: TimerMode.stopwatch,
      duration: const Duration(minutes: 10),
      filePath: '/tmp/timer.wav',
      title: 'Temporizador',
    );
    expect(
      PlayerProvider.iosBackupRemaining(stopwatch, 0, endPassed: false),
      isNull,
    );
  });

  test('cancelar usa el mismo id', () async {
    await backup.cancel();
    expect(scheduler.cancelled, [TimerEndBackup.notificationId]);
  });
}
