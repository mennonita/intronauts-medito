import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/providers/providers.dart';
import 'package:medito/views/timer/timer_format.dart';

/// Muestra el cronómetro o el tiempo extra sin una barra para adelantar.
class StopwatchElapsedWidget extends ConsumerWidget {
  const StopwatchElapsedWidget({super.key, this.plannedDurationMs});

  final int? plannedDurationMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positionMs = ref.watch(audioStateProvider.select((s) => s.position));
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    final planned = plannedDurationMs;
    final extraTime = planned != null && positionMs >= planned;
    final elapsed = Duration(
      milliseconds: planned == null
          ? positionMs
          : extraTime
          ? positionMs - planned
          : planned - positionMs,
    );
    final text = extraTime
        ? l10n.timerExtraTimeElapsed(
            '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}',
          )
        : formatTimerClock(elapsed);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: textTheme.displayMedium?.copyWith(
            color: ColorConstants.white,
            fontFamily: googleSans,
            fontSize: 44,
            fontWeight: FontWeight.w300,
            height: 1,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (planned == null) ...[
          const SizedBox(height: 6),
          Text(
            l10n.timerElapsed,
            style: textTheme.titleSmall?.copyWith(
              color: ColorConstants.white.withValues(alpha: 0.7),
              fontFamily: googleSans,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}
