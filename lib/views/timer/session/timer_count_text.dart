import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/src/audio_pigeon.g.dart' show PlaybackState;
import 'package:medito/views/timer/timer_format.dart';

import 'timer_backgrounds.dart';

class TimerCountText extends ConsumerStatefulWidget {
  const TimerCountText({
    super.key,
    required this.request,
    required this.foreground,
  });

  final PlaybackRequest request;
  final Color foreground;

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
    final request = widget.request;
    final isStopwatch = request.timerMode == TimerMode.stopwatch;
    final reading = timerClockReading(
      positionMs: positionMs,
      plannedDurationMs: isStopwatch ? null : request.plannedDurationMs,
      hasExtraTime: request.hasExtraTime,
    );
    final l10n = AppLocalizations.of(context)!;
    final label = isStopwatch
        ? l10n.timerModeStopwatch
        : reading.isExtraTime
        ? l10n.timerExtraTime
        : l10n.timerTitle;
    final time = reading.isExtraTime
        ? l10n.timerExtraTimeCount(reading.time)
        : reading.time;
    final style = TextStyle(
      color: widget.foreground,
      shadows: timerForegroundShadows(widget.foreground),
    );

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: style.copyWith(fontSize: 15)),
          const SizedBox(height: 4),
          Text(
            time,
            style: style.copyWith(
              fontSize: 72,
              height: 1,
              fontWeight: FontWeight.w300,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
