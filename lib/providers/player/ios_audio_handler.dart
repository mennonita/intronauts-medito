import 'dart:async';
import '../../services/audio/ios_session_bells.dart';
import 'package:medito/models/models.dart' show PlaybackRequest;
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/types/type_constants.dart';
import '../../src/audio_pigeon.g.dart';
import '../../utils/stats_updater.dart';
import '../../utils/logger.dart';

class IosAudioHandler extends BaseAudioHandler {
  final AudioPlayer _player;
  late final sessionBells = IosSessionBells(_player);
  // Distinguish a repeat boundary from terminal completion; never wait for bells.
  final _sessionCompleted = BehaviorSubject<bool>.seeded(false);
  bool _isInitialized = false;
  bool _hasExtraTime = false;
  bool _isTimer = false;
  int _startGeneration = 0;
  bool _discarded = false;
  bool _timerPlayBlocked = false;
  Completer<bool>? _timerReady;
  int _playGeneration = 0;
  Future<void> Function()? onTimerStop;
  RepeatMode _currentRepeatMode = RepeatMode.none;
  bool _hasReplayedOnce = false;

  /// Full play-throughs of the current track, counting repeats. The first is
  /// recorded as the session; each later one only adds its listening time.
  int _completedPlaythroughs = 0;

  /// While the player is paused the audio session is kept active so a quick
  /// resume stays seamless and the lock-screen controls remain. If the pause
  /// lasts longer than this the user has likely walked away, so the session is
  /// released to stop iOS keeping the app alive in the background.
  static const _pauseGracePeriod = Duration(minutes: 3);
  Timer? _pauseDeactivationTimer;

  IosAudioHandler({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  Future<void> ensureInitialized() async {
    if (_isInitialized) return;

    try {
      final session = await AudioSession.instance;

      // Configure interruption handling
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              _player.setVolume(_player.volume * 0.5);
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              _player.pause();
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              _player.setVolume(_player.volume * 2.0);
              break;
            case AudioInterruptionType.pause:
              if (_player.playing &&
                  !_timerPlayBlocked &&
                  _timerReady == null) {
                _player.play();
              }
              break;
            case AudioInterruptionType.unknown:
              break;
          }
        }
      });

      session.becomingNoisyEventStream.listen((_) {
        _player.pause();
      });

      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
          avAudioSessionMode: AVAudioSessionMode.defaultMode,
          avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        ),
      );

      _setupPlaybackState();
      _setupEventListeners();

      _isInitialized = true;
    } catch (e) {
      AppLogger.e('IOS', 'Failed to initialize audio session: $e');
      rethrow;
    }
  }

  void _setupPlaybackState() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.rewind,
          MediaControl.play,
          MediaControl.fastForward,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setSpeed,
          MediaAction.pause,
          MediaAction.play,
        },
        playing: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
      ),
    );
  }

  void _setupEventListeners() {
    iosStateStream.listen((event) {
      mediaItem.add(
        MediaItem(
          id: event.track.toString(),
          title: event.track.title,
          artist: event.track.artist,
          duration: _hasExtraTime ? null : event.duration,
          // A timer session has no cover; an empty URI is not "no art".
          artUri: event.track.imageUrl.isEmpty
              ? null
              : Uri.parse(event.track.imageUrl),
          playable: true,
          displayTitle: event.track.title,
          displaySubtitle: event.track.artist,
        ),
      );

      playbackState.add(
        playbackState.value.copyWith(
          updatePosition: event.position,
          bufferedPosition: event.bufferedPosition,
          speed: event.speed,
          playing: event.playerState.playing,
        ),
      );
    });

    _player.processingStateStream.listen((state) async {
      if (state != ProcessingState.completed) _sessionCompleted.add(false);
      if (state == ProcessingState.completed && !_discarded) {
        final accountGeneration = PlaybackAccount.generation;
        // Handle repeat once mode
        if (_currentRepeatMode == RepeatMode.once && !_hasReplayedOnce) {
          _hasReplayedOnce = true;
          unawaited(_recordPlaythrough());
          await _player.seek(Duration.zero);
          if (!_discarded && PlaybackAccount.isCurrent(accountGeneration)) {
            await _player.play();
          }
          return;
        }

        _sessionCompleted.add(true);

        // Playback has finished and is not repeating. Release the audio
        // session first so iOS does not keep the app alive in the background,
        // which otherwise drains battery for as long as the session stays
        // active after the meditation ends. Reporting the completion runs
        // afterwards because it does network/I/O that can be slow and must
        // not delay session release.
        _cancelPauseDeactivationTimer();
        // The ambient background player loops and keeps rendering audio after
        // the narration ends; pause it first so the shared session is idle and
        // iOS will actually let us deactivate it (a busy session is rejected).
        final generation = _startGeneration;
        await Future.wait([
          sessionBells.disable(),
          iosBackgroundPlayer.pause(),
        ]);
        if (generation != _startGeneration) return;
        await _deactivateSession();

        if (!_discarded && PlaybackAccount.isCurrent(accountGeneration)) {
          await _recordPlaythrough();
        }
      }
    });

    // Repeat forever (LoopMode.one) never reaches `completed`; each loop back
    // to the start surfaces as an auto-advance discontinuity instead.
    // just_audio also reports autoAdvance when a new source is loaded, so only
    // count it when the same, already-playing item wrapped around.
    _player.positionDiscontinuityStream.listen((discontinuity) {
      final prev = discontinuity.previousEvent;
      final curr = discontinuity.event;
      const active = {ProcessingState.ready, ProcessingState.buffering};
      final isLoop =
          discontinuity.reason == PositionDiscontinuityReason.autoAdvance &&
          _currentRepeatMode == RepeatMode.infinite &&
          active.contains(prev.processingState) &&
          active.contains(curr.processingState) &&
          prev.duration != null &&
          prev.duration == curr.duration;
      if (isLoop) unawaited(_recordPlaythrough());
    });

    _player.playbackEventStream.listen((event) {
      final playing = _player.playing;

      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            if (!_hasExtraTime) MediaControl.rewind,
            if (playing) MediaControl.pause else MediaControl.play,
            if (!_hasExtraTime) MediaControl.fastForward,
            if (_isTimer) MediaControl.stop,
          ],
          systemActions: {
            if (!_hasExtraTime) ...const {
              MediaAction.seek,
              MediaAction.seekForward,
              MediaAction.seekBackward,
            },
            if (!_isTimer) MediaAction.setSpeed,
            MediaAction.pause,
            MediaAction.play,
            if (_isTimer) MediaAction.stop,
          },
          playing: playing,
          processingState: const {
            ProcessingState.idle: AudioProcessingState.idle,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[_player.processingState]!,
          updatePosition: _player.position,
          bufferedPosition: _player.bufferedPosition,
          speed: _player.speed,
        ),
      );
    });
  }

  Duration get position => _player.position;

  bool get playing => _player.playerState.playing;

  bool get isComplete =>
      _player.playerState.processingState == ProcessingState.completed;

  final _trackStateSubject = BehaviorSubject<Track>();

  Track get trackState => _trackStateSubject.value;

  Stream<Track> get _trackStateStream => _trackStateSubject.stream;

  Stream<Duration> get positionStream => _player.positionStream;

  Duration? get duration => _player.duration;

  Stream<IosStateData> get iosStateStream =>
      Rx.combineLatest7<
        double,
        PlayerState,
        Track,
        Duration,
        Duration,
        Duration?,
        bool,
        IosStateData
      >(
        _player.speedStream,
        _player.playerStateStream,
        _trackStateStream,
        _player.positionStream,
        _player.bufferedPositionStream,
        _player.durationStream,
        _sessionCompleted.stream,
        (speed, state, track, position, bufferedPosition, duration, completed) {
          return IosStateData(
            speed,
            state.processingState == ProcessingState.completed && !completed
                ? PlayerState(false, ProcessingState.ready)
                : state,
            track,
            position,
            bufferedPosition,
            duration ?? Duration.zero,
          );
        },
      );

  Future<void> _recordPlaythrough() {
    if (_discarded) return Future.value();
    _completedPlaythroughs++;
    if (_completedPlaythroughs == 1) return _storeTrackCompletion();
    return _storeRepeatPlaythrough();
  }

  Future<void> _storeRepeatPlaythrough() async {
    try {
      if (duration == null) return;
      await handleRepeatPlaythrough({
        TypeConstants.trackIdKey: trackState.id,
        TypeConstants.durationIdKey: duration!.inMilliseconds,
        TypeConstants.fileIdKey: trackState.fileId,
        TypeConstants.guideIdKey: trackState.artist ?? '',
        TypeConstants.timestampIdKey: DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      AppLogger.e('IOS', 'Error recording repeat play-through: $e');
    }
  }

  Future<void> _storeTrackCompletion() async {
    try {
      if (duration == null) return;

      final accountGeneration = PlaybackAccount.generation;
      final payload = _createTrackCompletionPayload();
      if (!PlaybackAccount.isCurrent(accountGeneration)) return;

      // Try to update stats immediately
      if (await _tryUpdateStats(payload)) {
        return;
      }

      // Failed to update stats directly, store for later processing
      if (PlaybackAccount.isCurrent(accountGeneration)) {
        await _storeForLaterProcessing(payload, accountGeneration);
      }
    } catch (e) {
      AppLogger.e(
        'IOS',
        'Error processing track completion in AudioHandler: $e',
      );
    }
  }

  /// Creates a payload map with all track completion data
  Map<String, dynamic> _createTrackCompletionPayload() {
    return {
      TypeConstants.trackIdKey: trackState.id,
      TypeConstants.durationIdKey: duration?.inMilliseconds ?? 0,
      TypeConstants.fileIdKey: trackState.fileId,
      TypeConstants.guideIdKey: trackState.artist ?? '',
      TypeConstants.timestampIdKey: DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// Try to update stats directly and return success status
  Future<bool> _tryUpdateStats(Map<String, dynamic> payload) async {
    try {
      AppLogger.d('IOS', 'Track completed: ${trackState.id}');
      final success = await handleStats(payload);

      if (success) {
        AppLogger.d('IOS', 'Successfully updated stats from audio handler');
        return true;
      }
    } catch (e) {
      AppLogger.e(
        'IOS',
        'Error updating stats directly from audio handler: $e',
      );
    }
    return false;
  }

  /// Store track completion data for later processing
  Future<void> _storeForLaterProcessing(
    Map<String, dynamic> payload,
    int accountGeneration,
  ) async {
    AppLogger.d(
      'IOS',
      'Storing track completion for later processing: ${trackState.id}',
    );
    final prefs = await SharedPreferences.getInstance();
    if (PlaybackAccount.isCurrent(accountGeneration)) {
      await storeTrackCompletion(prefs, payload);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (_hasExtraTime) return;
    if (_isTimer) sessionBells.seekTimer(position);
    return _player.seek(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (_isTimer) return;
    return _player.setSpeed(speed);
  }

  Future<void> setCustomRepeatMode(RepeatMode mode) async {
    _currentRepeatMode = mode;
    _hasReplayedOnce = false;

    switch (mode) {
      case RepeatMode.none:
        await _player.setLoopMode(LoopMode.off);
        break;
      case RepeatMode.once:
        await _player.setLoopMode(LoopMode.off);
        break;
      case RepeatMode.infinite:
        await _player.setLoopMode(LoopMode.one);
        break;
    }
  }

  @override
  Future<void> play() async {
    final generation = _startGeneration;
    final playGeneration = ++_playGeneration;
    final account = PlaybackAccount.generation;
    bool isCurrent() =>
        (!_discarded || _timerReady != null) &&
        !_timerPlayBlocked &&
        generation == _startGeneration &&
        playGeneration == _playGeneration &&
        PlaybackAccount.isCurrent(account);

    if (!isCurrent()) return;
    final ready = _timerReady;
    if (ready != null && !await ready.future) return;
    if (!isCurrent()) return;
    _cancelPauseDeactivationTimer();

    final session = await AudioSession.instance;
    if (!isCurrent()) return;
    await session.setActive(true);
    if (!isCurrent() || (_isTimer && _player.playing)) return;

    unawaited(_player.play());
    // Bells follow _player on their own; resume the ambient sound if any.
    if (iosAmbientActive) unawaited(iosBackgroundPlayer.play());
  }

  @override
  Future<void> pause() async {
    _playGeneration++;
    unawaited(_player.pause());
    unawaited(iosBackgroundPlayer.pause());

    // Keep the session active for a quick resume, but release it if the pause
    // is prolonged so iOS stops keeping the app alive in the background.
    _schedulePauseDeactivation();
  }

  @override
  Future<void> stop() async {
    final close = onTimerStop;
    if (_isTimer && close != null && (_timerReady != null || !isComplete)) {
      await close();
      return;
    }
    await stopPlayback();
  }

  Future<void> discardPlayback() {
    _discarded = true;
    onTimerStop = null;
    iosAmbientActive = false;
    return stopPlayback();
  }

  Future<void> stopPlayback() async {
    if (_isTimer) _timerPlayBlocked = true;
    _cancelTimerStart();
    final generation = ++_startGeneration;
    _cancelPauseDeactivationTimer();
    if (_isTimer) {
      await Future.wait([
        sessionBells.disable(),
        _player.stop(),
        iosBackgroundPlayer.pause(),
      ]);
    } else {
      await sessionBells.disable();
      // iOS solo desactiva la sesión cuando los reproductores se detienen.
      await _player.stop();
      await iosBackgroundPlayer.pause();
    }
    if (generation == _startGeneration) {
      unawaited(super.stop());
      await _deactivateSession();
    }
  }

  /// Schedules release of the audio session after [_pauseGracePeriod] if the
  /// player is still paused, so an abandoned pause does not keep the app in
  /// background-audio state indefinitely.
  void _schedulePauseDeactivation() {
    _pauseDeactivationTimer?.cancel();
    _pauseDeactivationTimer = Timer(_pauseGracePeriod, () {
      if (!_player.playing) {
        unawaited(_deactivateSession());
      }
    });
  }

  void _cancelPauseDeactivationTimer() {
    _pauseDeactivationTimer?.cancel();
    _pauseDeactivationTimer = null;
  }

  /// Deactivates the iOS audio session so the OS stops treating the app as an
  /// active background-audio app. Without this, the session activated in
  /// [play] stays active after playback stops/completes and keeps the app
  /// running in the background, draining the battery. The
  /// `notifyOthersOnDeactivation` option lets other apps (e.g. music) resume
  /// once we release the session.
  Future<void> _deactivateSession() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(
        false,
        avAudioSessionSetActiveOptions:
            AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
      );
    } catch (e) {
      AppLogger.e('IOS', 'Failed to deactivate audio session: $e');
    }
  }

  void cancelPendingTimerStart() {
    if (!_isTimer) return;
    _playGeneration++;
    _timerPlayBlocked = true;
    if (_timerReady == null) return;
    _startGeneration++;
    _cancelTimerStart();
    unawaited(sessionBells.disable());
  }

  void _cancelTimerStart() {
    _timerReady?.complete(false);
    _timerReady = null;
  }

  Future<void> setUrl(
    String? downloadPath,
    PlaybackRequest request,
    Track trackData, {
    ({bool enabled, double volume})? timerBells,
  }) async {
    final generation = ++_startGeneration;
    final wasTimer = _isTimer;
    _isTimer = request.isTimer;
    _hasExtraTime = request.hasExtraTime;
    _cancelTimerStart();
    final ready = request.isTimer ? Completer<bool>() : null;
    _timerReady = ready;
    _timerPlayBlocked = wasTimer && !request.isTimer;
    final discardingBells = wasTimer ? sessionBells.disable() : null;
    try {
      await discardingBells;
      await ensureInitialized();
      if (generation != _startGeneration) return;
      if (wasTimer || request.isTimer) {
        await _player.pause();
        if (generation != _startGeneration) return;
        await _player.setSpeed(1.0);
        if (generation != _startGeneration) return;
      }

      _hasReplayedOnce = false;
      _completedPlaythroughs = 0;
      _sessionCompleted.add(false);
      sessionBells.reset();

      await sessionBells.setBellCues(
        cues: request.isTimer ? request.timerBellCues ?? const [] : null,
        enabled: timerBells?.enabled ?? false,
        volume: timerBells?.volume ?? 0,
      );
      if (generation != _startGeneration) return;

      if (downloadPath == null) {
        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(request.remoteUrl)),
        );
      } else {
        await _player.setAsset(downloadPath);
      }
      if (generation != _startGeneration) return;
      await setCustomRepeatMode(_currentRepeatMode);
      if (generation != _startGeneration) return;

      _discarded = false;
      _timerPlayBlocked = false;
      _trackStateSubject.add(trackData);
      ready?.complete(true);
    } finally {
      if (generation == _startGeneration) {
        if (ready != null && !ready.isCompleted) {
          _timerPlayBlocked = true;
          ready.complete(false);
        }
        _timerReady = null;
      }
    }
  }
}

class IosStateData {
  final double speed;
  final PlayerState playerState;
  final Track track;
  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;

  IosStateData(
    this.speed,
    this.playerState,
    this.track,
    this.position,
    this.bufferedPosition,
    this.duration,
  );
}
