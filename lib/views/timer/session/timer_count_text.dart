import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_timeline.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/src/audio_pigeon.g.dart' show PlaybackState;
import 'package:medito/views/timer/timer_format.dart';

import 'timer_backgrounds.dart';

class TimerCountText extends ConsumerStatefulWidget {
  const TimerCountText({
    super.key,
    required this.request,
    required this.foreground,
    this.paused = false,
  });

  final PlaybackRequest request;
  final Color foreground;

  /// La sesión está en pausa (no suena y no está cargando).
  final bool paused;

  @override
  ConsumerState<TimerCountText> createState() => _TimerCountTextState();
}

class _TimerCountTextState extends ConsumerState<TimerCountText> {
  bool _hasSessionUpdate = false;

  bool _belongsToSession(PlaybackState state) {
    final request = widget.request;
    final track = state.track;
    // Los temporizadores con tiempo extra comparten un ID de pista.
    // Si llegan ambos IDs, los dos tienen que coincidir.
    if (track.id.isEmpty && track.fileId.isEmpty) return false;
    if (track.id.isNotEmpty && track.id != request.trackId) return false;
    if (track.fileId.isNotEmpty && track.fileId != request.fileId) return false;

    return state.isPlaying ||
        (!state.isCompleted &&
            (state.duration - request.duration).abs() <= 2000);
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasSessionUpdate) {
      ref.listen(audioStateProvider, (_, next) {
        if (!_hasSessionUpdate && _belongsToSession(next)) {
          setState(() => _hasSessionUpdate = true);
        }
      });
    }

    final positionMs = _hasSessionUpdate
        ? ref.watch(audioStateProvider.select((state) => state.position))
        : 0;
    final l10n = AppLocalizations.of(context)!;
    final reading = timerCountReading(
      l10n,
      request: widget.request,
      positionMs: positionMs,
      paused: widget.paused,
    );
    final style = TextStyle(
      color: widget.foreground,
      shadows: timerForegroundShadows(widget.foreground),
    );

    // El lector de pantalla oye una frase completa, no los dígitos sueltos.
    return Semantics(
      label: reading.semantics,
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(reading.label, style: style.copyWith(fontSize: 15)),
            const SizedBox(height: 4),
            Text(
              reading.time,
              style: style.copyWith(
                fontSize: 72,
                height: 1,
                fontWeight: FontWeight.w300,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lo que muestra y dice el reloj de la sesión en [positionMs] (posición del
/// archivo, con la preparación incluida).
@visibleForTesting
({String label, String time, String semantics}) timerCountReading(
  AppLocalizations l10n, {
  required PlaybackRequest request,
  required int positionMs,
  bool paused = false,
}) {
  final timeline = TimerTimeline.fromRequest(request);
  final position = positionMs < 0 ? 0 : positionMs;
  final String label;
  final String time;
  final String sentence;
  var prefixed = paused;

  if (timeline.inPrep(position)) {
    // Preparación: cuenta hacia el inicio, aún no cuenta como meditado.
    final prep = Duration(milliseconds: timeline.prepRemainingMs(position));
    label = l10n.timerPrepLabel;
    time = formatTimerClock(prep, roundUp: true);
    final left = _ceilToSecond(prep);
    sentence = l10n.timerTimeLeftSemantics(
      timerSpokenForm(left),
      timerSpokenDuration(l10n, left),
    );
    prefixed = true;
  } else {
    final elapsedMs = timeline.elapsedMs(position);
    final clock = timerClockReading(
      positionMs: elapsedMs,
      plannedDurationMs: timeline.isStopwatch ? null : timeline.plannedMs,
      hasExtraTime: timeline.extraTime,
    );
    final stageIndex = timeline.stageIndexAt(position);
    final stageKinds = request.timerStageKinds;
    if (timeline.isStopwatch) {
      label = l10n.timerModeStopwatch;
    } else if (clock.isExtraTime) {
      label = l10n.timerExtraTime;
      prefixed = true;
    } else if (stageIndex != null && stageIndex < stageKinds.length) {
      label = l10n.timerStageLabel(
        _stageName(l10n, stageKinds[stageIndex]),
        stageIndex + 1,
        timeline.stageDurationsMs.length,
      );
      prefixed = true;
    } else {
      label = l10n.timerTitle;
    }
    time = clock.isExtraTime
        ? l10n.timerExtraTimeCount(clock.time)
        : clock.time;
    if (timeline.isStopwatch || clock.isExtraTime) {
      final counted = clock.isExtraTime
          ? elapsedMs - timeline.plannedMs
          : elapsedMs;
      sentence = l10n.timerTimeElapsedSemantics(
        timerSpokenDuration(l10n, Duration(milliseconds: counted)),
      );
    } else {
      final remaining = timeline.remainingMs(position) ?? 0;
      final left = _ceilToSecond(Duration(milliseconds: remaining));
      sentence = l10n.timerTimeLeftSemantics(
        timerSpokenForm(left),
        timerSpokenDuration(l10n, left),
      );
    }
  }

  // En pausa manda sobre cualquier otra etiqueta.
  final shownLabel = paused ? l10n.timerPaused : label;
  return (
    label: shownLabel,
    time: time,
    semantics: prefixed ? '$shownLabel. $sentence' : sentence,
  );
}

// Igual que la cuenta en pantalla: lo que falta se redondea hacia arriba.
Duration _ceilToSecond(Duration d) =>
    d.inMicroseconds.remainder(Duration.microsecondsPerSecond) == 0
    ? d
    : Duration(seconds: d.inSeconds + 1);

String _stageName(AppLocalizations l10n, String kind) => switch (kind) {
  'walk' => l10n.timerStageWalk,
  'rest' => l10n.timerStageRest,
  _ => l10n.timerStageSit,
};
