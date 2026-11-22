import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/views/player/player_view.dart';
import 'package:medito/views/player/widgets/duration_indicator_widget.dart';

void main() {
  testWidgets('la pantalla cuenta hacia cero y luego hacia arriba sin barra', (
    tester,
  ) async {
    final request = timerPlaybackRequest(
      mode: TimerMode.countdown,
      duration: const Duration(minutes: 2),
      extraTime: true,
      filePath: '/tmp/timer.wav',
      title: 'Temporizador',
    );
    final container = ProviderContainer(
      overrides: [audioStateProvider.overrideWith(AudioStateNotifier.new)],
    );
    addTearDown(container.dispose);
    final audio = container.read(audioStateProvider.notifier);
    final state = container
        .read(audioStateProvider)
        .copyWith(duration: request.duration, isPlaying: true);
    audio.updatePlaybackState(state.copyWith(position: 110000));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('es'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: PlayerScreenLayout(
            currentlyPlayingTrack: request,
            isPlaying: true,
            isAudioLoading: false,
            isBackgroundSoundSelected: false,
            onPlayPausePressed: () {},
            onSpeedChanged: (_) {},
            onClosePressed: () {},
            onEndSession: () {},
          ),
        ),
      ),
    );
    expect(find.text('0:10'), findsOneWidget);
    expect(find.byType(DurationIndicatorWidget), findsNothing);
    final l10n = await AppLocalizations.delegate.load(const Locale('es'));
    expect(find.byTooltip(l10n.skipBackward10Seconds), findsNothing);
    expect(find.byTooltip(l10n.skipForward10Seconds), findsNothing);
    expect(find.byTooltip(l10n.playbackSpeed), findsNothing);

    audio.updatePlaybackState(state.copyWith(position: 120000));
    await tester.pump();
    expect(find.text('Tiempo extra +0:00'), findsOneWidget);

    audio.updatePlaybackState(state.copyWith(position: 185000));
    await tester.pump();
    expect(find.text('Tiempo extra +1:05'), findsOneWidget);
    expect(find.text('5:00:00'), findsNothing);
  });
}
