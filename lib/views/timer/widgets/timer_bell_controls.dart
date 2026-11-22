import 'package:flutter/material.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';

class TimerBellControls extends StatelessWidget {
  const TimerBellControls({
    super.key,
    required this.bells,
    required this.showRandom,
    required this.onChanged,
  });

  final TimerBellSettings bells;
  final bool showRandom;
  final ValueChanged<TimerBellSettings> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ExpansionTile(
      title: Text(l10n.timerBells),
      children: [
        SwitchListTile(
          title: Text(l10n.timerStartBell),
          value: bells.start,
          onChanged: (value) => onChanged(bells.copyWith(start: value)),
        ),
        SwitchListTile(
          title: Text(l10n.timerEndBell),
          value: bells.end,
          onChanged: (value) => onChanged(bells.copyWith(end: value)),
        ),
        ListTile(
          title: Text(l10n.timerBellInterval),
          trailing: DropdownButton<int>(
            value: bells.intervalMinutes,
            onChanged: (value) {
              if (value != null) {
                onChanged(bells.copyWith(intervalMinutes: value));
              }
            },
            items: [
              for (final minutes in timerIntervalMinutes)
                DropdownMenuItem(
                  value: minutes,
                  child: Text(
                    minutes == 0
                        ? l10n.timerBellsOff
                        : l10n.timerBellEvery(minutes),
                  ),
                ),
            ],
          ),
        ),
        if (showRandom)
          ListTile(
            title: Text(l10n.timerRandomBells),
            trailing: DropdownButton<int>(
              value: bells.randomCount,
              onChanged: (value) {
                if (value != null) {
                  onChanged(bells.copyWith(randomCount: value));
                }
              },
              items: [
                for (var count = 0; count <= timerMaxRandomBells; count++)
                  DropdownMenuItem(
                    value: count,
                    child: Text(
                      count == 0
                          ? l10n.timerBellsOff
                          : l10n.timerRandomBellCount(count),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
