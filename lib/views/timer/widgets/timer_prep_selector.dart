import 'package:flutter/material.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_settings.dart';

/// Cuenta regresiva antes de la campana de inicio: «Sin espera», 10 s, 30 s,
/// 1 min o 2 min. No cuenta como tiempo meditado.
class TimerPrepSelector extends StatelessWidget {
  const TimerPrepSelector({
    super.key,
    required this.prepSeconds,
    required this.onChanged,
  });

  final int prepSeconds;
  final ValueChanged<int> onChanged;

  static String label(AppLocalizations l10n, int seconds) {
    if (seconds == 0) return l10n.timerPrepOff;
    if (seconds < 60) return l10n.timerPrepSecondsOption(seconds);
    return l10n.timerPrepMinutesOption(seconds ~/ 60);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.timerPrepTitle,
            style: theme.textTheme.titleMedium?.copyWith(color: onSurface),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final seconds in kTimerPrepOptions)
                ChoiceChip(
                  label: Text(label(l10n, seconds)),
                  selected: prepSeconds == seconds,
                  onSelected: (_) {
                    if (prepSeconds != seconds) onChanged(seconds);
                  },
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.timerPrepDescription,
            style: theme.textTheme.bodySmall?.copyWith(
              color: onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
