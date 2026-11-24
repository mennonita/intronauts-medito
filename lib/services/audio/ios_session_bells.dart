import 'dart:async';

import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import '../timer/timer_end_backup.dart';
import '../../models/background_sounds/background_sounds_model.dart';
import '../../models/timer/timer_bell_settings.dart';
import '../../utils/logger.dart';
import 'session_bell_schedule.dart';
import 'timer_bell_schedule.dart';

class IosSessionBells {
  IosSessionBells(this.primary, {AudioPlayer Function()? createPlayer})
    : _createPlayer = createPlayer ?? _newBellPlayer {
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

  // El controlador único de interrupciones pausa y reanuda las campanas; si
  // just_audio también lo hiciera, competiría con él.
  static AudioPlayer _newBellPlayer() =>
      AudioPlayer(handleInterruptions: false);

  /// Tiempo máximo de espera al final del archivo para que suenen completas
  /// las campanas que ya empezaron o están en fila (R53).
  static const drainTimeout = Duration(seconds: 60);

  final AudioPlayer primary;
  final AudioPlayer Function() _createPlayer;

  /// Se llama cuando empieza la campana final, antes de su sonido.
  void Function()? onEndCueStarted;

  /// Respaldo del final que se cancela al empezar la campana final.
  TimerEndBackup? endBackup;
  final _timerQueue = <TimerBellCue>[];
  StreamSubscription<ProcessingState>? _activeDone;
  String _output = 'sound';
  double _duck = 1;
  bool _draining = false;
  bool _activeRinging = false;
  Completer<void>? _drained;
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
  bool get endCueStarted => _endStarted;

  Future<void> setBellCues({
    required List<TimerBellCue>? cues,
    required bool enabled,
    required double volume,
    String output = 'sound',
  }) async {
    if (cues == null && _timerSchedule == null) return;
    final stopping = disable();
    final generation = _generation;
    _output = output;
    _duck = 1;
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
      await player.setVolume(_volume * _duck);
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
    unawaited(_trackBell?.setVolume(volume * _duck));
    for (final player in _timerPlayers.values) {
      unawaited(player.setVolume(volume * _duck));
    }
  }

  /// Baja las campanas mientras otra app pide bajar el volumen.
  void duck(bool ducked) {
    _duck = ducked ? 0.2 : 1;
    setVolume(_volume);
  }

  /// Pausa la campana que suena sin perder la fila (interrupción).
  Future<void> pauseForInterruption() async {
    await Future.wait([
      if (_activeBell case final bell?) bell.pause(),
      if (_trackBell case final bell?) bell.pause(),
    ]);
  }

  /// Al final del archivo deja sonar completas la campana activa y las de la
  /// fila (como máximo [timeout]) antes de soltar los reproductores.
  Future<void> waitTimerBells({Duration timeout = drainTimeout}) async {
    if (_timerSchedule == null || _timerStopped) return;
    _draining = true;
    final drained = _drained ??= Completer<void>();
    _pumpTimer();
    await drained.future.timeout(timeout, onTimeout: () {});
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
    _draining = false;
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
    _timerQueue.clear();
    unawaited(_activeDone?.cancel());
    _activeDone = null;
    final bell = _activeBell;
    _activeBell = null;
    _completeDrain();
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
      // Al final del archivo una campana que suena nunca se corta.
      _timerQueue.addAll(_dueCues(timer, primary.position.inMilliseconds));
      _pumpTimer();
      return;
    }
    if (!_primaryPlaying) {
      unawaited(_activeBell?.pause());
      return;
    }
    _timerQueue.addAll(_dueCues(timer, primary.position.inMilliseconds));
    _pumpTimer();
  }

  /// Campanas que tocan ahora, en orden (pueden ser varias atrasadas).
  List<TimerBellCue> _dueCues(TimerBellSchedule timer, int positionMs) =>
      timer.update(positionMs, enabled: _enabled);

  bool get _atEnd =>
      _draining || primary.processingState == ProcessingState.completed;

  /// Toca la siguiente campana de la fila solo cuando terminó la anterior.
  void _pumpTimer() {
    if (_timerStopped || _timerInstalling) return;
    final active = _activeBell;
    if (active != null) {
      if (_activeRinging &&
          active.processingState == ProcessingState.completed) {
        _bellFinished(active);
        return;
      }
      if (_enabled &&
          (_primaryPlaying || _atEnd) &&
          active.processingState == ProcessingState.ready &&
          !active.playing) {
        unawaited(active.play());
      }
      return;
    }
    if (_timerQueue.isEmpty) {
      if (_atEnd) _completeDrain();
      return;
    }
    if (!_primaryPlaying && !_atEnd) return;
    unawaited(_ringTimer(_timerQueue.removeAt(0)));
  }

  void _bellFinished(AudioPlayer bell) {
    if (!identical(_activeBell, bell)) return;
    unawaited(_activeDone?.cancel());
    _activeDone = null;
    _activeBell = null;
    _pumpTimer();
  }

  void _completeDrain() {
    final drained = _drained;
    _drained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
  }

  void _endCueStarted() {
    unawaited((endBackup ?? TimerEndBackup.instance).cancel());
    onEndCueStarted?.call();
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
    // Voz en iOS: pendiente (sin motor TTS en Dart).
    if (cue.kind.name == 'spoken') {
      _pumpTimer();
      return;
    }
    final generation = _ringGeneration;
    final isEnd = cue.kind == TimerBellKind.end;
    final vibrate = _output == 'vibration' || _output == 'soundAndVibration';
    if (_output == 'vibration') {
      // «Solo vibración» nunca toca audio.
      if (isEnd) {
        _endStarted = true;
        _endCueStarted();
      }
      unawaited(HapticFeedback.vibrate());
      _pumpTimer();
      return;
    }
    final bell =
        _timerPlayers[cue.assetKey] ?? _timerPlayers[kSessionBellAsset];
    if (bell == null) {
      _pumpTimer();
      return;
    }
    _activeBell = bell;
    _activeRinging = false;
    try {
      await bell.seek(Duration.zero);
      if (generation != _ringGeneration || !_enabled) return;
      // Escucha el final solo después de rebobinar: antes el reproductor aún
      // dice «completado» por el toque anterior.
      _activeRinging = true;
      _activeDone = bell.processingStateStream.listen((state) {
        if (state == ProcessingState.completed &&
            generation == _ringGeneration) {
          _bellFinished(bell);
        }
      });
      if (isEnd) {
        _pendingEnd = true;
        _endPosition = bell.positionStream.listen((position) {
          if (generation == _ringGeneration) _checkEndStarted(position);
        });
        _endCueStarted();
      }
      if (!_primaryPlaying && !_atEnd) return;
      if (vibrate) unawaited(HapticFeedback.vibrate());
      await bell.play();
    } catch (error, stack) {
      if (generation == _ringGeneration) {
        AppLogger.e('BELLS', 'No se pudo tocar la campana', error, stack);
        _bellFinished(bell);
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
