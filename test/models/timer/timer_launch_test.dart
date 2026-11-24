import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_launch.dart';
import 'package:medito/models/timer/timer_session.dart';

void main() {
  const root = 'org.meditofoundation://medito/timer/start';

  test('acepta el enlace principal, el enlace web y el enlace anterior', () {
    for (final link in [
      root,
      'https://medito.app/timer/start',
      'org.meditofoundation://timer/start',
    ]) {
      expect(TimerLaunch.fromUri(Uri.parse('$link?minutes=25'))?.minutes, 25);
    }
  });

  test('acepta minutos del 1 al 299', () {
    for (final minutes in ['0', '-5', '300', 'uno', '1.5', '', '0x10']) {
      expect(
        TimerLaunch.fromUri(Uri.parse('$root?minutes=$minutes'))?.minutes,
        isNull,
      );
    }
    expect(TimerLaunch.fromUri(Uri.parse('$root?minutes=1'))?.minutes, 1);
    expect(TimerLaunch.fromUri(Uri.parse('$root?minutes=299'))?.minutes, 299);
  });

  test('limita el nombre a 30 caracteres y descarta un nombre vacío', () {
    final preset = 'a' * 29 + '🌙' + 'z';
    final uri = Uri.parse(root).replace(queryParameters: {'preset': preset});
    expect(TimerLaunch.fromUri(uri)?.presetName, 'a' * 29 + '🌙');
    expect(TimerLaunch.fromUri(Uri.parse('$root?preset='))?.presetName, isNull);
  });

  test('last solo se activa con 1 y se ignoran las demás claves', () {
    final launch = TimerLaunch.fromUri(
      Uri.parse('$root?last=1&startAt=123&source=home&widget=1'),
    )!;
    expect(launch.last, isTrue);
    expect(launch.toUri().queryParameters, {'last': '1'});
    expect(TimerLaunch.fromUri(Uri.parse('$root?last=true'))?.last, isFalse);
    expect(
      TimerLaunch.fromUri(Uri.parse('$root?startAt=123'))?.isEmpty,
      isTrue,
    );
  });

  test('rechaza enlaces de otras rutas, dominios y esquemas', () {
    for (final link in [
      'org.meditofoundation://medito/timer',
      'org.meditofoundation://other/timer/start',
      'https://medito.app/start',
      'http://medito.app/timer/start',
      'https://example.org/timer/start',
    ]) {
      expect(TimerLaunch.fromUri(Uri.parse(link)), isNull);
    }
  });

  test('genera el enlace principal y conserva sus valores al leerlo', () {
    const launch = TimerLaunch(
      minutes: 18,
      presetName: 'Mañana & té',
      last: true,
      minPrepSeconds: 10,
    );
    final uri = launch.toUri();
    expect(uri.scheme, 'org.meditofoundation');
    expect(uri.host, 'medito');
    expect(uri.path, '/timer/start');
    final restored = TimerLaunch.fromUri(uri)!;
    expect(restored.minutes, launch.minutes);
    expect(restored.presetName, launch.presetName);
    expect(restored.last, launch.last);
    expect(uri.queryParameters['prep'], '10');
    expect(restored.minPrepSeconds, launch.minPrepSeconds);
    expect(const TimerLaunch().toUri().toString(), root);
  });

  test('recorta la preparación y descarta valores que no son enteros', () {
    expect(const TimerLaunch(minPrepSeconds: 121).minPrepSeconds, 120);
    expect(const TimerLaunch(minPrepSeconds: -1).minPrepSeconds, 0);
    expect(const TimerLaunch(minPrepSeconds: 0).toUri().query, 'prep=0');
    expect(
      TimerLaunch.fromUri(Uri.parse('$root?prep=200'))?.minPrepSeconds,
      120,
    );
    expect(TimerLaunch.fromUri(Uri.parse('$root?prep=-1'))?.minPrepSeconds, 0);
    expect(TimerLaunch.fromUri(Uri.parse(root))?.minPrepSeconds, isNull);
    for (final invalid in ['', 'texto', '1.5', '0x10']) {
      expect(
        TimerLaunch.fromUri(Uri.parse('$root?prep=$invalid'))?.minPrepSeconds,
        isNull,
      );
    }
  });

  test('lee la ruta completa desde la pantalla de inicio', () {
    expect(TimerLaunch.fromRoutePath('timer/start?last=1')?.last, isTrue);
    expect(TimerLaunch.fromRoutePath('start?last=1'), isNull);
  });

  group('Identificador de sesión', () {
    const reservedId = 'abcdef0123456789abcdef0123456789';

    test('conserva el identificador reservado y el dueño', () {
      final request = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 3),
        filePath: '/tmp/timer.wav',
        title: '',
        runId: reservedId,
        ownerId: 'cuenta-verificada',
      );
      expect(request.timerRunId, reservedId);
      expect(request.timerOwnerId, 'cuenta-verificada');
    });

    test('genera un identificador nuevo para cada solicitud sin reserva', () {
      final first = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 3),
        filePath: '/tmp/timer.wav',
        title: '',
      );
      final second = timerPlaybackRequest(
        mode: TimerMode.countdown,
        duration: const Duration(minutes: 3),
        filePath: '/tmp/timer.wav',
        title: '',
      );
      expect(first.timerRunId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(second.timerRunId, isNot(first.timerRunId));
      expect(first.timerOwnerId, isEmpty);
    });

    test('genera 32 dígitos hexadecimales en minúsculas', () {
      final first = newTimerRunId();
      final second = newTimerRunId();
      final format = RegExp(r'^[0-9a-f]{32}$');
      expect(first, matches(format));
      expect(second, matches(format));
      expect(second, isNot(first));
    });
  });
}
