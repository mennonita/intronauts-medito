import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/views/player/widgets/duration_indicator_widget.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/timer/session/timer_session_layout.dart';

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
      overrides: [
        audioStateProvider.overrideWith(AudioStateNotifier.new),
        sharedPreferencesProvider.overrideWithValue(
          MemoryPrefs({
            SharedPreferenceConstants.timerBackground: 'black:negro',
          }),
        ),
      ],
    );
    addTearDown(container.dispose);
    final audio = container.read(audioStateProvider.notifier);
    final state = container
        .read(audioStateProvider)
        .copyWith(
          duration: request.duration,
          isPlaying: true,
          track: Track(
            id: request.trackId,
            fileId: request.fileId,
            title: '',
            description: '',
            imageUrl: '',
          ),
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('es'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: TimerSessionLayout(
            request: request,
            isPlaying: true,
            isAudioLoading: false,
            isBackgroundSoundSelected: false,
            onPlayPausePressed: () {},
            onClosePressed: () {},
            onEndSession: () {},
          ),
        ),
      ),
    );
    expect(find.text('2:00'), findsOneWidget);
    audio.updatePlaybackState(state.copyWith(position: 110000));
    await tester.pump();
    expect(find.text('0:10'), findsOneWidget);
    expect(find.text('Temporizador'), findsOneWidget);
    expect(find.byType(DurationIndicatorWidget), findsNothing);
    expect(find.byType(Slider), findsNothing);
    final l10n = await AppLocalizations.delegate.load(const Locale('es'));
    expect(find.byTooltip(l10n.skipBackward10Seconds), findsNothing);
    expect(find.byTooltip(l10n.skipForward10Seconds), findsNothing);
    expect(find.byTooltip(l10n.playbackSpeed), findsNothing);

    audio.updatePlaybackState(state.copyWith(position: 120000));
    await tester.pump();
    expect(find.text('Tiempo extra'), findsOneWidget);
    expect(find.text('+0:00'), findsOneWidget);

    audio.updatePlaybackState(state.copyWith(position: 185000));
    await tester.pump();
    expect(find.text('+1:05'), findsOneWidget);

    audio.updatePlaybackState(state.copyWith(position: 3720000));
    await tester.pump();
    expect(find.text('+1:00:00'), findsOneWidget);
    expect(find.text('5:00:00'), findsNothing);
  });
}
