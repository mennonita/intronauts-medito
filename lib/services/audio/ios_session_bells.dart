import 'dart:async';

import 'package:just_audio/just_audio.dart';
import '../../models/background_sounds/background_sounds_model.dart';
import '../../models/timer/timer_bell_settings.dart';
import '../../utils/logger.dart';
import 'session_bell_schedule.dart';
import 'timer_bell_schedule.dart';

class IosSessionBells {
  IosSessionBells(this.primary, {AudioPlayer Function()? createPlayer})
    : _createPlayer = createPlayer ?? AudioPlayer.new {
    primary.positionStream.listen((_) => _update());
    primary.playerStateStream.listen((_) => _update());
    primary.positionDiscontinuityStream.listen((event) {
      if (event.reason == PositionDiscontinuityReason.autoAdvance) {
        _schedule.reset();
      } else if (event.reason == PositionDiscontinuityReason.seek) {
        final timer = _timerSchedule;
        if (timer == null) {
          unawaited(_trackBell?.pause());
          _schedule.seek(
            primary.position,
            primary.duration ?? Duration.zero,
            speed: primary.speed,
          );
        } else {
          seekTimer(event.event.updatePosition);
        }
      }
      _update();
    });
  }

  final AudioPlayer primary;
  final AudioPlayer Function() _createPlayer;
  final _schedule = SessionBellSchedule();
  final _timerPlayers = <String, AudioPlayer>{};
  AudioPlayer? _trackBell;
  AudioPlayer? _activeBell;
  StreamSubscription<Duration>? _endPosition;
  Future<void>? _clearingBell;
  TimerBellSchedule? _timerSchedule;
  bool _endStarted = false;
  bool _pendingEnd = false;
  bool _timerStopped = false;
  bool _timerInstalling = false;
  bool _enabled = false;
  bool _trackReady = false;
  double _volume = 1;
  int _generation = 0;
  int _ringGeneration = 0;
  Future<void>? _trackLoading;

  bool get enabled => _enabled;

  Future<void> setBellCues({
    required List<TimerBellCue>? cues,
    required bool enabled,
    required double volume,
  }) async {
    if (cues == null && _timerSchedule == null) return;
    final stopping = disable();
    final generation = _generation;
    _timerSchedule = cues == null ? null : TimerBellSchedule(cues);
    _timerInstalling = cues != null;
    _enabled = cues != null && enabled;
    setVolume(volume);
    await stopping;
    if (generation != _generation || cues == null) return;

    final assets = cues.map((cue) => cue.assetKey).toSet();
    final loaded = await Future.wait([
      for (final asset in assets) _loadTimerAsset(asset, generation),
    ]);
    if (generation != _generation) return;
    if (loaded.contains(false) && !assets.contains(kSessionBellAsset)) {
      await _loadTimerAsset(kSessionBellAsset, generation);
    }
    if (generation != _generation) return;
    _timerInstalling = false;
    _timerStopped = false;
    _update();
  }

  Future<bool> _loadTimerAsset(String asset, int generation) async {
    final player = _createPlayer();
    _timerPlayers[asset] = player;
    try {
      await player.setAsset(asset);
      if (generation != _generation) return false;
      await player.setVolume(_volume);
      if (generation != _generation) return false;
      return true;
    } catch (error) {
      if (generation == _generation) {
        AppLogger.w('BELLS', 'No se pudo cargar $asset: $error');
        _timerPlayers.remove(asset);
        await player.dispose();
      }
      return false;
    }
  }

  Future<void> setTimerEnabled(bool enabled, double volume) async {
    if (_timerStopped && !_timerInstalling) return;
    if (enabled && !_enabled) _update();
    _enabled = enabled;
    setVolume(volume);
    if (!enabled) await _clearTimerBell();
  }

  bool stopBellsAndReportEnd() {
    _checkEndStarted(_activeBell?.position ?? Duration.zero);
    _generation++;
    _timerInstalling = false;
    _timerStopped = true;
    _enabled = false;
    unawaited(_clearTimerBell());
    return _endStarted;
  }

  Future<void> enable(double volume) async {
    if (_enabled && _trackReady) return;
    final generation = ++_generation;
    _enabled = true;
    _trackReady = false;
    _schedule.reset();
    final bell = _trackBell ??= _createPlayer();
    setVolume(volume);
    _trackLoading ??= bell.setAsset(kSessionBellAsset).then<void>((_) {});
    try {
      await _trackLoading;
      if (generation != _generation) return;
      _trackReady = true;
      _update();
    } catch (_) {
      if (generation != _generation) return;
      _trackLoading = null;
      rethrow;
    }
  }

  void setVolume(double volume) {
    _volume = volume;
    unawaited(_trackBell?.setVolume(volume));
    for (final player in _timerPlayers.values) {
      unawaited(player.setVolume(volume));
    }
  }

  void seekTimer(Duration position) {
    final timer = _timerSchedule;
    if (timer == null) return;
    unawaited(_clearTimerBell());
    timer.seek(position.inMilliseconds);
  }

  void reset() {
    _schedule.reset();
    _timerSchedule?.reset();
    _endStarted = false;
    unawaited(_clearTimerBell());
    unawaited(_trackBell?.pause());
  }

  Future<void> disable() async {
    _generation++;
    _timerInstalling = false;
    _enabled = false;
    _trackReady = false;
    _timerStopped = true;
    _schedule.reset();
    _timerSchedule?.reset();
    _endStarted = false;
    final clearing = _clearTimerBell();
    _trackLoading = null;
    final players = _timerPlayers.values.toList();
    _timerPlayers.clear();
    await Future.wait([
      clearing,
      if (_trackBell case final bell?) bell.stop(),
      for (final player in players) player.dispose(),
    ]);
  }

  Future<void> _clearTimerBell() async {
    _ringGeneration++;
    _pendingEnd = false;
    final bell = _activeBell;
    _activeBell = null;
    final subscription = _endPosition;
    _endPosition = null;
    final previous = _clearingBell;
    if (bell == null && subscription == null) {
      await previous;
      return;
    }
    final clearing = Future.wait([
      ?previous,
      if (bell != null) bell.pause(),
      if (subscription != null) subscription.cancel(),
    ]).then<void>((_) {});
    _clearingBell = clearing;
    try {
      await clearing;
    } finally {
      if (identical(_clearingBell, clearing)) _clearingBell = null;
    }
  }

  void _update() {
    final timer = _timerSchedule;
    if (timer == null) {
      _updateTrack();
      return;
    }
    if (_timerStopped || _timerInstalling) return;
    if (primary.processingState == ProcessingState.completed) {
      unawaited(_clearTimerBell());
      return;
    }
    if (!_primaryPlaying) {
      unawaited(_activeBell?.pause());
      return;
    }
    final cue = timer.update(
      primary.position.inMilliseconds,
      enabled: _enabled,
    );
    if (cue != null) {
      unawaited(_ringTimer(cue));
    } else if (_activeBell case final bell?
        when _enabled &&
            bell.processingState == ProcessingState.ready &&
            !bell.playing) {
      unawaited(bell.play());
    }
  }

  bool get _primaryPlaying =>
      primary.playing && primary.processingState == ProcessingState.ready;

  void _updateTrack() {
    final bell = _trackBell;
    if (!_enabled || !_trackReady || bell == null) return;
    if (!_primaryPlaying) {
      unawaited(bell.pause());
      return;
    }
    if (_schedule.update(
      primary.position,
      primary.duration ?? Duration.zero,
      speed: primary.speed,
    )) {
      unawaited(_ringTrack(bell));
    } else if (bell.processingState == ProcessingState.ready &&
        !bell.playing &&
        bell.position > Duration.zero) {
      unawaited(bell.play());
    }
  }

  Future<void> _ringTrack(AudioPlayer bell) async {
    final generation = _generation;
    try {
      await bell.seek(Duration.zero);
      if (generation == _generation && _enabled && _primaryPlaying) {
        await bell.play();
      }
    } catch (error, stack) {
      AppLogger.e('BELLS', 'No se pudo tocar la campana', error, stack);
    }
  }

  Future<void> _ringTimer(TimerBellCue cue) async {
    final clearing = _clearTimerBell();
    final generation = _ringGeneration;
    final bell =
        _timerPlayers[cue.assetKey] ?? _timerPlayers[kSessionBellAsset];
    try {
      await clearing;
      if (bell == null || generation != _ringGeneration) return;
      await bell.seek(Duration.zero);
      if (generation != _ringGeneration || !_enabled || !_primaryPlaying) {
        return;
      }
      _activeBell = bell;
      if (cue.kind == TimerBellKind.end) {
        _pendingEnd = true;
        _endPosition = bell.positionStream.listen((position) {
          if (generation == _ringGeneration) _checkEndStarted(position);
        });
      }
      await bell.play();
    } catch (error, stack) {
      if (generation == _ringGeneration) {
        AppLogger.e('BELLS', 'No se pudo tocar la campana', error, stack);
      }
    }
  }

  void _checkEndStarted(Duration position) {
    if (_pendingEnd && position > Duration.zero) {
      _endStarted = true;
      _pendingEnd = false;
    }
  }
}
