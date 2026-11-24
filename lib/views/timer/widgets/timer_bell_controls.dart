import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/providers/timer/timer_settings_provider.dart';

import 'timer_bell_sound_picker.dart';

String timerBellsSummary(
  AppLocalizations l10n,
  TimerBellSettings bells, {
  required bool isStopwatch,
}) {
  final parts = [
    if (bells.start) (l10n.timerSummaryStart, bells.startSound),
    if (bells.end) (l10n.timerSummaryEnd, bells.endSound),
    if (bells.intervalMinutes > 0)
      (l10n.timerSummaryInterval(bells.intervalMinutes), bells.intervalSound),
    if (!isStopwatch && bells.randomCount > 0)
      (l10n.timerSummaryRandom(bells.randomCount), bells.randomSound),
  ];
  if (parts.isEmpty) return l10n.timerBellsSummaryNone;

  final timing = parts.map((part) => part.$1).join(', ');
  return [
    timing[0].toUpperCase() + timing.substring(1),
    BellSound.resolve(parts.first.$2).name(l10n),
    if (bells.output == TimerBellOutput.vibration) l10n.timerSummaryVibration,
  ].join(' · ');
}

class TimerBellControls extends ConsumerWidget {
  const TimerBellControls({
    super.key,
    required this.bells,
    required this.showRandom,
    required this.onChanged,
    bool? showSpokenCues,
  }) : _showSpokenCues = showSpokenCues;

  final TimerBellSettings bells;
  final bool showRandom;
  final ValueChanged<TimerBellSettings> onChanged;
  final bool? _showSpokenCues;

  bool get showSpokenCues =>
      _showSpokenCues ?? defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isMultiStage = ref.watch(
      timerSettingsProvider.select((settings) => settings.isMultiStage),
    );
    return ExpansionTile(
      title: Text(l10n.timerBells),
      subtitle: Text(
        timerBellsSummary(
          l10n,
          isMultiStage ? bells.copyWith(start: false) : bells,
          isStopwatch: !showRandom,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      children: [
        if (!isMultiStage) ...[
          SwitchListTile(
            title: Text(l10n.timerStartBell),
            value: bells.start,
            onChanged: (value) => onChanged(bells.copyWith(start: value)),
          ),
          if (bells.start)
            _soundAndRepeats(
              context,
              soundId: bells.startSound,
              repeats: bells.startRepeats,
              onSoundChanged: (id) => onChanged(bells.copyWith(startSound: id)),
              onRepeatsChanged: (value) =>
                  onChanged(bells.copyWith(startRepeats: value)),
            ),
        ],
        SwitchListTile(
          title: Text(l10n.timerEndBell),
          value: bells.end,
          onChanged: (value) => onChanged(bells.copyWith(end: value)),
        ),
        if (bells.end)
          _soundAndRepeats(
            context,
            soundId: bells.endSound,
            repeats: bells.endRepeats,
            onSoundChanged: (id) => onChanged(bells.copyWith(endSound: id)),
            onRepeatsChanged: (value) =>
                onChanged(bells.copyWith(endRepeats: value)),
          ),
        _dropdownRow(
          label: l10n.timerBellInterval,
          value: bells.intervalMinutes,
          options: timerIntervalMinutes,
          optionLabel: (minutes) =>
              minutes == 0 ? l10n.timerBellsOff : l10n.timerBellEvery(minutes),
          onSelected: (value) =>
              onChanged(bells.copyWith(intervalMinutes: value)),
        ),
        if (bells.intervalMinutes > 0)
          _soundAndRepeats(
            context,
            soundId: bells.intervalSound,
            repeats: bells.intervalRepeats,
            onSoundChanged: (id) =>
                onChanged(bells.copyWith(intervalSound: id)),
            onRepeatsChanged: (value) =>
                onChanged(bells.copyWith(intervalRepeats: value)),
          ),
        if (showRandom) ...[
          _dropdownRow(
            label: l10n.timerRandomBells,
            value: bells.randomCount,
            options: List.generate(timerMaxRandomBells + 1, (count) => count),
            optionLabel: (count) => count == 0
                ? l10n.timerBellsOff
                : l10n.timerRandomBellCount(count),
            onSelected: (value) =>
                onChanged(bells.copyWith(randomCount: value)),
          ),
          if (bells.randomCount > 0)
            _soundAndRepeats(
              context,
              soundId: bells.randomSound,
              repeats: bells.randomRepeats,
              onSoundChanged: (id) =>
                  onChanged(bells.copyWith(randomSound: id)),
              onRepeatsChanged: (value) =>
                  onChanged(bells.copyWith(randomRepeats: value)),
            ),
        ],
        ListTile(
          title: Semantics(
            header: true,
            child: Text(l10n.timerBellOutputTitle),
          ),
        ),
        RadioGroup<TimerBellOutput>(
          groupValue: bells.output,
          onChanged: (value) {
            if (value != null) onChanged(bells.copyWith(output: value));
          },
          child: Column(
            children: [
              RadioListTile(
                value: TimerBellOutput.sound,
                title: Text(l10n.timerBellOutputSound),
              ),
              RadioListTile(
                value: TimerBellOutput.vibration,
                title: Text(l10n.timerBellOutputVibration),
              ),
              RadioListTile(
                value: TimerBellOutput.soundAndVibration,
                title: Text(l10n.timerBellOutputBoth),
              ),
            ],
          ),
        ),
        if (bells.output == TimerBellOutput.vibration)
          ListTile(subtitle: Text(l10n.timerBellOutputVibrationHint)),
        if (showRandom && showSpokenCues)
          SwitchListTile(
            title: Text(l10n.timerSpokenCues),
            subtitle: Text(l10n.timerSpokenCuesDescription),
            value: bells.spokenCues,
            onChanged: (value) => onChanged(bells.copyWith(spokenCues: value)),
          ),
      ],
    );
  }

  Widget _dropdownRow({
    required String label,
    required int value,
    required Iterable<int> options,
    required String Function(int) optionLabel,
    required ValueChanged<int> onSelected,
  }) => ListTile(
    title: Text(label),
    subtitle: DropdownButton<int>(
      value: value,
      isExpanded: true,
      itemHeight: null,
      onChanged: (value) {
        if (value != null) onSelected(value);
      },
      items: [
        for (final option in options)
          DropdownMenuItem(value: option, child: Text(optionLabel(option))),
      ],
    ),
  );

  Widget _soundAndRepeats(
    BuildContext context, {
    required BellSoundId soundId,
    required int repeats,
    required ValueChanged<BellSoundId> onSoundChanged,
    required ValueChanged<int> onRepeatsChanged,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final sound = BellSound.resolve(soundId);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 16),
      child: Column(
        children: [
          ListTile(
            title: Text(l10n.bellSoundSelection(sound.name(l10n))),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showTimerBellSoundPicker(
              context,
              selected: sound.id,
              onSelected: onSoundChanged,
            ),
          ),
          _dropdownRow(
            label: l10n.timerBellRepeats,
            value: repeats,
            options: timerBellRepeatOptions,
            optionLabel: l10n.timerBellRepeatCount,
            onSelected: onRepeatsChanged,
          ),
        ],
      ),
    );
  }
}
