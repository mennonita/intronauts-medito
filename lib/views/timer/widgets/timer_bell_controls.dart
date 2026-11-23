import 'package:flutter/material.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';

import 'timer_bell_sound_picker.dart';

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
        if (bells.start)
          _soundRow(
            context,
            bells.startSound,
            (id) => onChanged(bells.copyWith(startSound: id)),
          ),
        SwitchListTile(
          title: Text(l10n.timerEndBell),
          value: bells.end,
          onChanged: (value) => onChanged(bells.copyWith(end: value)),
        ),
        if (bells.end)
          _soundRow(
            context,
            bells.endSound,
            (id) => onChanged(bells.copyWith(endSound: id)),
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
        if (bells.intervalMinutes > 0 || !showRandom)
          _soundRow(
            context,
            bells.intervalSound,
            (id) => onChanged(bells.copyWith(intervalSound: id)),
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
        if (showRandom && bells.randomCount > 0)
          _soundRow(
            context,
            bells.randomSound,
            (id) => onChanged(bells.copyWith(randomSound: id)),
          ),
      ],
    );
  }

  Widget _soundRow(
    BuildContext context,
    BellSoundId id,
    ValueChanged<BellSoundId> onSelected,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final sound = BellSound.resolve(id);
    return ListTile(
      title: Text(l10n.bellSoundSelection(sound.name(l10n))),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showTimerBellSoundPicker(
        context,
        selected: sound.id,
        onSelected: onSelected,
      ),
    );
  }
}
