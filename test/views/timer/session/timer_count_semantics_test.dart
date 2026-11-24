import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_stage.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/src/audio_pigeon.g.dart' show Track;
import 'package:medito/views/timer/session/timer_count_text.dart';
import 'package:medito/views/timer/timer_format.dart';

PlaybackRequest _request({
  TimerMode mode = TimerMode.countdown,
  Duration duration = const Duration(minutes: 20),
  bool extraTime = false,
  int prepMs = 0,
  List<TimerStage> stages = const [],
}) => timerPlaybackRequest(
  mode: mode,
  duration: duration,
  extraTime: extraTime,
  prepMs: prepMs,
  stages: stages,
  filePath: '/tmp/timer.wav',
  title: 'Temporizador',
);

const _min = 60000;

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('es'));
  });

  group('timerSpokenDuration', () {
    test('dice segundos solo con menos de un minuto', () {
      expect(
        timerSpokenDuration(l10n, const Duration(seconds: 45)),
        '45 segundos',
      );
      expect(
        timerSpokenDuration(l10n, const Duration(seconds: 1)),
        '1 segundo',
      );
      expect(timerSpokenDuration(l10n, Duration.zero), '0 segundos');
      expect(
        timerSpokenDuration(l10n, const Duration(seconds: -3)),
        '0 segundos',
      );
    });

    test('desde un minuto dice también los segundos que no son cero', () {
      expect(
        timerSpokenDuration(l10n, const Duration(minutes: 12, seconds: 30)),
        '12 minutos 30 segundos',
      );
      expect(
        timerSpokenDuration(l10n, const Duration(minutes: 12, seconds: 59)),
        '12 minutos 59 segundos',
      );
      expect(
        timerSpokenDuration(l10n, const Duration(minutes: 1, seconds: 1)),
        '1 minuto 1 segundo',
      );
      expect(
        timerSpokenDuration(l10n, const Duration(hours: 1, seconds: 30)),
        '1 hora 30 segundos',
      );
      expect(
        timerSpokenDuration(
          l10n,
          const Duration(hours: 2, minutes: 5, seconds: 7),
        ),
        '2 horas 5 minutos 7 segundos',
      );
      // Las fracciones de segundo no se dicen.
      expect(
        timerSpokenDuration(
          l10n,
          const Duration(minutes: 3, milliseconds: 400),
        ),
        '3 minutos',
      );
    });

    test('junta horas y minutos', () {
      expect(timerSpokenDuration(l10n, const Duration(minutes: 1)), '1 minuto');
      expect(timerSpokenDuration(l10n, const Duration(hours: 1)), '1 hora');
      expect(
        timerSpokenDuration(l10n, const Duration(hours: 2, minutes: 5)),
        '2 horas 5 minutos',
      );
    });
  });

  group('timerCountReading', () {
    test('cuenta regresiva: «Quedan 12 minutos» y «Quedan 45 segundos»', () {
      final request = _request();
      final twelve = timerCountReading(
        l10n,
        request: request,
        positionMs: 8 * _min,
      );
      expect(twelve.label, 'Temporizador');
      expect(twelve.time, '12:00');
      expect(twelve.semantics, 'Quedan 12 minutos');

      final seconds = timerCountReading(
        l10n,
        request: request,
        positionMs: 20 * _min - 44500,
      );
      expect(seconds.time, '0:45');
      expect(seconds.semantics, 'Quedan 45 segundos');
    });

    test('cuenta regresiva: «Quedan 12 minutos 30 segundos», igual que el '
        'reloj', () {
      final reading = timerCountReading(
        l10n,
        request: _request(),
        positionMs: 7 * _min + 30000 + 400,
      );
      expect(reading.time, '12:30');
      expect(reading.semantics, 'Quedan 12 minutos 30 segundos');
    });

    test('en pausa la etiqueta cambia y la frase la lleva al inicio', () {
      final reading = timerCountReading(
        l10n,
        request: _request(),
        positionMs: 8 * _min,
        paused: true,
      );
      expect(reading.label, 'En pausa');
      expect(reading.time, '12:00');
      expect(reading.semantics, 'En pausa. Quedan 12 minutos');
    });

    test('la preparación cuenta hacia el inicio con «Prepárate»', () {
      final request = _request(prepMs: 30000);
      final reading = timerCountReading(
        l10n,
        request: request,
        positionMs: 20500,
      );
      expect(reading.label, 'Prepárate');
      expect(reading.time, '0:10');
      expect(reading.semantics, 'Prepárate. Quedan 10 segundos');

      // Al terminar la preparación empieza la cuenta de la sesión completa.
      final started = timerCountReading(
        l10n,
        request: request,
        positionMs: 30000,
      );
      expect(started.label, 'Temporizador');
      expect(started.time, '20:00');

      // En pausa durante la preparación manda «En pausa».
      final paused = timerCountReading(
        l10n,
        request: request,
        positionMs: 20500,
        paused: true,
      );
      expect(paused.label, 'En pausa');
      expect(paused.semantics, 'En pausa. Quedan 10 segundos');
    });

    test('por partes muestra la parte y el total que falta', () {
      final request = _request(
        stages: const [
          TimerStage(kind: TimerStageKind.sit, minutes: 10),
          TimerStage(kind: TimerStageKind.walk, minutes: 5),
          TimerStage(kind: TimerStageKind.rest, minutes: 5),
        ],
      );
      final walking = timerCountReading(
        l10n,
        request: request,
        positionMs: 12 * _min,
      );
      expect(walking.label, 'Caminando · parte 2 de 3');
      expect(walking.time, '8:00');
      expect(walking.semantics, 'Caminando · parte 2 de 3. Quedan 8 minutos');

      final first = timerCountReading(l10n, request: request, positionMs: 0);
      expect(first.label, 'Sentado · parte 1 de 3');
      expect(first.time, '20:00');
    });

    test('el tiempo extra cuenta hacia arriba con su etiqueta', () {
      final request = _request(
        duration: const Duration(minutes: 2),
        extraTime: true,
      );
      final reading = timerCountReading(
        l10n,
        request: request,
        positionMs: 2 * _min + 65000,
      );
      expect(reading.label, 'Tiempo extra');
      expect(reading.time, '+1:05');
      expect(reading.semantics, 'Tiempo extra. Llevas 1 minuto 5 segundos');
    });

    test('el cronómetro dice lo que llevas', () {
      final request = _request(mode: TimerMode.stopwatch);
      final reading = timerCountReading(
        l10n,
        request: request,
        positionMs: 30500,
      );
      expect(reading.label, 'Cronómetro');
      expect(reading.time, '0:30');
      expect(reading.semantics, 'Llevas 30 segundos');
    });
  });

  testWidgets('el reloj se lee como una sola frase', (tester) async {
    final request = _request();
    final container = ProviderContainer(
      overrides: [audioStateProvider.overrideWith(AudioStateNotifier.new)],
    );
    addTearDown(container.dispose);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('es'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: TimerCountText(
              request: request,
              foreground: Colors.white,
              paused: true,
            ),
          ),
        ),
      ),
    );
    container
        .read(audioStateProvider.notifier)
        .updatePlaybackState(
          container
              .read(audioStateProvider)
              .copyWith(
                position: 8 * _min,
                duration: request.duration,
                isPlaying: true,
                track: Track(
                  id: request.trackId,
                  fileId: request.fileId,
                  title: '',
                  description: '',
                  imageUrl: '',
                ),
              ),
        );
    await tester.pump();
    expect(
      find.bySemanticsLabel('En pausa. Quedan 12 minutos'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('12:00'), findsNothing);
    handle.dispose();
  });
}
