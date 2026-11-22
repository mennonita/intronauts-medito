import 'dart:async';

import 'package:just_audio/just_audio.dart';
import '../../models/background_sounds/background_sounds_model.dart';
import '../../utils/logger.dart';
import 'session_bell_schedule.dart';
import 'timer_bell_schedule.dart';

/// Owns one-shot bell playback; ambient loops never enter this controller.
class IosSessionBells {
  IosSessionBells(this.primary, {AudioPlayer? bell})
    : _bell = bell ?? AudioPlayer() {
    _bell.positionStream.listen(_checkEndStarted);
    primary.positionStream.listen((_) => _update());
    primary.playerStateStream.listen((_) => _update());
    primary.positionDiscontinuityStream.listen((event) {
      if (event.reason == PositionDiscontinuityReason.autoAdvance) {
        _schedule.reset();
      } else if (event.reason == PositionDiscontinuityReason.seek) {
        unawaited(_bell.pause());
        _pendingEnd = false;
        final timer = _timerSchedule;
        if (timer == null) {
          _schedule.seek(
            primary.position,
            primary.duration ?? Duration.zero,
            speed: primary.speed,
          );
        } else {
          _timerSeekGeneration++;
          timer.seek(primary.position.inMilliseconds);
        }
      }
      _update();
    });
  }

  final AudioPlayer primary;
  final AudioPlayer _bell;
  final _schedule = SessionBellSchedule();
  TimerBellSchedule? _timerSchedule;
  int? _endOffsetMs;
  bool _endStarted = false;
  bool _pendingEnd = false;
  bool _timerStopped = false;
  bool _timerInstalling = false;
  bool _timerInstallEnabled = false;
  int _timerSeekGeneration = 0;
  bool _enabled = false;
  bool _ready = false;
  int _generation = 0;
  Future<void>? _loading;

  bool get enabled => _enabled;

  Future<void> setBellCues({
    required List<int>? offsetsMs,
    int? endOffsetMs,
    required bool enabled,
    required double volume,
  }) async {
    if (offsetsMs == null && _timerSchedule == null && !_timerInstalling) {
      return;
    }
    final stopping = disable();
    final generation = _generation;
    _timerInstalling = offsetsMs != null;
    _timerInstallEnabled = enabled;
    try {
      await stopping;
      if (generation != _generation) return;
      _timerSchedule = offsetsMs == null ? null : TimerBellSchedule(offsetsMs);
      _endOffsetMs = endOffsetMs;
      _endStarted = false;
      if (offsetsMs != null) await _loadBell(volume, generation);
    } catch (error, stack) {
      AppLogger.e('BELLS', 'No se pudo cargar la campana', error, stack);
    } finally {
      if (generation == _generation) {
        _timerInstalling = false;
        _timerStopped = false;
        _enabled = offsetsMs != null && _timerInstallEnabled;
        _update();
      }
    }
  }

  Future<void> setTimerEnabled(bool enabled, double volume) async {
    if (_timerInstalling) {
      _timerInstallEnabled = enabled;
      return;
    }
    if (_timerStopped) return;
    if (enabled && !_enabled) _update();
    _enabled = enabled;
    final generation = ++_generation;
    if (enabled) {
      await _loadBell(volume, generation);
    } else {
      _pendingEnd = false;
      await _bell.pause();
      if (generation == _generation && _ready) await _bell.seek(Duration.zero);
    }
  }

  bool stopBellsAndReportEnd() {
    // Riesgo aceptado: la posición estimada puede avanzar antes de que suene la campana.
    _checkEndStarted(_bell.position);
    _timerInstalling = false;
    _timerStopped = true;
    _enabled = false;
    _pendingEnd = false;
    _generation++;
    unawaited(_bell.pause());
    return _endStarted;
  }

  Future<void> enable(double volume) async {
    if (_enabled && _ready) return;
    final generation = ++_generation;
    _enabled = true;
    _ready = false;
    _schedule.reset();
    await _loadBell(volume, generation);
  }

  Future<void> _loadBell(double volume, int generation) async {
    _loading ??= _bell
        .setAsset(kSessionBellAsset)
        .then<void>((_) {})
        .catchError((Object error) {
          _loading = null;
          throw error;
        });
    await _loading;
    if (generation != _generation) return;
    await _bell.setVolume(volume);
    if (generation != _generation) return;
    _ready = true;
    _update();
  }

  void setVolume(double volume) => unawaited(_bell.setVolume(volume));

  void reset() {
    _schedule.reset();
    _timerSchedule?.reset();
    _endStarted = false;
    _pendingEnd = false;
    unawaited(_bell.pause());
  }

  Future<void> disable() async {
    _generation++;
    _timerInstalling = false;
    _enabled = false;
    _ready = false;
    _timerStopped = true;
    reset();
    _loading = null;
    await _bell.stop();
  }

  void _update() {
    final timer = _timerSchedule;
    if (timer != null && _timerStopped) return;
    if (timer == null && (!_enabled || !_ready)) return;
    if (primary.processingState == ProcessingState.completed) {
      unawaited(_bell.pause());
      return;
    }
    if (!primary.playing || primary.processingState != ProcessingState.ready) {
      unawaited(_bell.pause());
      return;
    }
    final canRing = _enabled && _ready;
    final timerCue = timer?.update(
      primary.position.inMilliseconds,
      enabled: canRing,
    );
    if (timerCue != null ||
        (timer == null &&
            _schedule.update(
              primary.position,
              primary.duration ?? Duration.zero,
              speed: primary.speed,
            ))) {
      unawaited(_ring(isEnd: timerCue != null && timerCue == _endOffsetMs));
    } else if (canRing &&
        _bell.processingState == ProcessingState.ready &&
        !_bell.playing &&
        _bell.position > Duration.zero) {
      unawaited(_bell.play());
    }
  }

  Future<void> _ring({required bool isEnd}) async {
    final generation = _generation;
    final seekGeneration = _timerSeekGeneration;
    try {
      await _bell.seek(Duration.zero);
      if (!_enabled ||
          generation != _generation ||
          seekGeneration != _timerSeekGeneration) {
        return;
      }
      if (!primary.playing ||
          primary.processingState != ProcessingState.ready) {
        return;
      }
      _pendingEnd = isEnd;
      await _bell.play();
    } catch (error) {
      AppLogger.e('BELLS', 'Bell playback failed: $error');
    }
  }

  void _checkEndStarted(Duration position) {
    if (_pendingEnd && position > Duration.zero) {
      _endStarted = true;
      _pendingEnd = false;
    }
  }
}
