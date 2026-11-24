
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/player/download/audio_downloader_provider.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Preview extends Mock implements SessionBellPreview {}

class _Downloads extends AudioDownloaderProvider {
  @override
  Future<String?> getTrackPath(String fileName) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final timer = timerPlaybackRequest(
    mode: TimerMode.countdown,
    duration: const Duration(minutes: 3),
    filePath: '/tmp/timer.wav',
    title: 'Temporizador',
    seed: 42,
  );
  const guided = PlaybackRequest(
    trackId: 'guided',
    fileId: 'guided-audio',
    title: 'Meditación',
    description: '',
    coverUrl: '',
    remoteUrl: 'https://example.com/guided.mp3',
    duration: 180000,
    hasBackgroundSound: false,
  );

  late ProviderContainer container;
  late PlayerProvider player;
  late Duration now;

  void mockHost(
    String api,
    MessageCodec<Object?> codec,
    Map<String, Object?> replies,
  ) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final entry in replies.entries) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.medito.$api.${entry.key}',
        codec,
      );
      messenger.setMockDecodedMessageHandler(
        channel,
        (_) async => [entry.value],
      );
      addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
    }
  }

  void mockAudio(Map<String, Object?> replies) => mockHost(
    'MeditoAudioServiceApi',
    MeditoAudioServiceApi.pigeonChannelCodec,
    replies,
  );

  void tick(
    PlaybackRequest request, {
    int seconds = 0,
    bool playing = false,
    bool completed = false,
    bool? endCueRang,
    String? runId,
    int position = 1,
  }) {
    now += Duration(seconds: seconds);
    container
        .read(audioStateProvider.notifier)
        .updatePlaybackState(
          PlaybackState(
            isPlaying: playing,
            isBuffering: false,
            isSeeking: false,
            isCompleted: completed,
            position: position,
            duration: request.duration,
            speed: Speed(speed: 1),
            volume: 100,
            track: Track(
              id: request.trackId,
              fileId: request.fileId,
              title: '',
              description: '',
              imageUrl: '',
            ),
            runId: runId ?? (request.isTimer ? request.timerRunId : null),
            endCueRang: endCueRang,
          ),
        );
  }

  Future<void> start(PlaybackRequest request) async {
    player.prepare(request);
    if (request.isTimer) {
      expect(player.reserveStart(request.timerRunId), isTrue);
    }
    await player.play(request);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    now = Duration.zero;
    final tracker = AudioSessionTracker.instance;
    final log = AudioSessionTracker.logSink;
    tracker.resetForTesting();
    AudioSessionTracker.logSink = (_, _) async {};
    addTearDown(() {
      tracker.resetForTesting();
      AudioSessionTracker.logSink = log;
      MeditoTimerStopCallbackApi.setUp(null);
    });
    final preview = _Preview();
    when(preview.stop).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        playerProvider.overrideWith(
          () => PlayerProvider(useAndroidAudio: true, sitClock: () => now),
        ),
        audioStateProvider.overrideWith(AudioStateNotifier.new),
        sessionBellPreviewProvider.overrideWithValue(preview),
        audioDownloaderProvider.overrideWith(_Downloads.new),
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(container.dispose);
    player = container.read(playerProvider.notifier);

    mockHost(
      'MeditoAndroidAudioServiceManager',
      MeditoAndroidAudioServiceManager.pigeonChannelCodec,
      {'startService': null, 'isServiceReady': true},
    );
    mockAudio({
      'setBellCues': null,
      'setBackgroundSoundVolume': null,
      'setSessionBells': null,
      'setRepeatMode': null,
      'playAudio': true,
      'stopAudio': null,
    });
  });

  test('sums two pauses and consumes the completed outcome once', () async {
    await start(timer);
    tick(timer, position: 0);
    tick(timer, seconds: 130, playing: true, position: 0);
    tick(timer, seconds: 130);
    tick(timer, seconds: 130, playing: true);
    tick(timer, seconds: 10);
    tick(timer, seconds: 15);
    tick(timer, seconds: 15, playing: true);
    tick(timer, seconds: 10);
    tick(timer, seconds: 40, playing: true, endCueRang: true);
    tick(timer, seconds: 5, completed: true);
    player.stop();

    final outcome = player.takeSitOutcome()!;
    expect(outcome.pausedMs, 70000);
    expect(outcome.naturalEnd, isTrue);
    expect(outcome.isClean, isTrue);
    tick(timer, completed: true, endCueRang: true);
    expect(player.takeSitOutcome(), isNull);
  });

  test(
    'ignores another run’s bell and the current run’s final position',
    () async {
      await start(timer);
      tick(timer, playing: true);
      tick(timer, runId: 'other-run', endCueRang: true, completed: true);
      expect(player.takeSitOutcome(), isNull);
      tick(timer, completed: true, position: timer.duration, endCueRang: false);

      final outcome = player.takeSitOutcome()!;
      expect(outcome.endCueRang, isFalse);
      expect(outcome.isClean, isFalse);
    },
  );

  test('accepts the confirmed end cue at the stopwatch cap', () async {
    final stopwatch = timerPlaybackRequest(
      mode: TimerMode.stopwatch,
      duration: const Duration(hours: 5),
      filePath: '/tmp/stopwatch.wav',
      title: 'Cronómetro',
      seed: 43,
    );
    await start(stopwatch);
    tick(stopwatch, playing: true);
    tick(
      stopwatch,
      playing: true,
      position: stopwatch.plannedDurationMs,
      endCueRang: true,
    );
    tick(stopwatch, position: stopwatch.duration);
    tick(stopwatch, seconds: 4, completed: true, position: stopwatch.duration);

    final outcome = player.takeSitOutcome()!;
    expect(outcome.pausedMs, 0);
    expect(outcome.isClean, isTrue);
  });

  test(
    'includes the open pause and a confirmed bell on manual close',
    () async {
      await start(timer);
      tick(timer, playing: true);
      tick(timer);
      now += const Duration(seconds: 121);
      mockAudio({
        'stopTimerPlayback': TimerStopReport(
          positionMs: timer.duration,
          endCueRang: true,
          stopped: true,
          runId: timer.timerRunId,
        ),
      });
      await player.closeTimer(runId: timer.timerRunId);

      final outcome = player.takeSitOutcome()!;
      expect(outcome.pausedMs, 121000);
      expect(outcome.naturalEnd, isFalse);
      expect(outcome.endCueRang, isTrue);
      expect(outcome.isClean, isFalse);
    },
  );

  test('a guided completion is clean and cannot carry into a stop', () async {
    await start(guided);
    tick(guided, playing: true);
    tick(guided, completed: true, position: guided.duration);
    expect(player.takeSitOutcome()?.isClean, isTrue);

    await start(guided);
    tick(guided, playing: true);
    player.stop();
    tick(guided, completed: true, position: guided.duration);
    final outcome = player.takeSitOutcome()!;
    expect(outcome.naturalEnd, isFalse);
    expect(outcome.isClean, isFalse);
  });
}
