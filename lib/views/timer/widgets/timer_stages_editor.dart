import 'package:flutter/material.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/models/timer/timer_settings.dart';
import 'package:medito/views/timer/timer_format.dart';

import 'timer_bell_sound_picker.dart';

/// Duración de cada parte al prender «Sesión por partes» sin minutos elegidos.
const kDefaultTimerStageMinutes = 20;

/// Minutos de la parte caminando que se agrega al prender las partes.
const kDefaultTimerWalkMinutes = 5;

/// Partes con las que empieza la sesión por partes: sentado, caminando,
/// sentado. Se acortan para que el total no pase de [kMaxTimerMinutes].
List<TimerStage> seedTimerStages(int currentMinutes) {
  final walk = kDefaultTimerWalkMinutes;
  var sit = currentMinutes > 0 ? currentMinutes : kDefaultTimerStageMinutes;
  if (sit * 2 + walk > kMaxTimerMinutes) sit = (kMaxTimerMinutes - walk) ~/ 2;
  return [
    TimerStage(kind: TimerStageKind.sit, minutes: sit),
    TimerStage(kind: TimerStageKind.walk, minutes: walk),
    TimerStage(kind: TimerStageKind.sit, minutes: sit),
  ];
}

String timerStageKindLabel(AppLocalizations l10n, TimerStageKind kind) =>
    switch (kind) {
      TimerStageKind.sit => l10n.timerStageSit,
      TimerStageKind.walk => l10n.timerStageWalk,
      TimerStageKind.rest => l10n.timerStageRest,
    };

/// «Sesión por partes» (solo cuenta regresiva): cada parte tiene su tipo, sus
/// minutos, su campana y las veces que suena (1 a 3). Con el interruptor
/// apagado la lista queda vacía.
class TimerStagesEditor extends StatelessWidget {
  const TimerStagesEditor({
    super.key,
    required this.stages,
    required this.currentMinutes,
    required this.onChanged,
  });

  final List<TimerStage> stages;

  /// Minutos elegidos en las ruedas; dan la duración de las partes sentado.
  final int currentMinutes;
  final ValueChanged<List<TimerStage>> onChanged;

  bool get _enabled => stages.length >= kMinTimerStages;

  int get _total => stages.fold(0, (sum, stage) => sum + stage.minutes);

  void _replace(int index, TimerStage stage) =>
      onChanged([...stages]..[index] = stage);

  void _add() {
    final room = kMaxTimerMinutes - _total;
    if (stages.length >= kMaxTimerStages || room < 1) return;
    final minutes = room < kDefaultTimerWalkMinutes
        ? room
        : kDefaultTimerWalkMinutes;
    onChanged([
      ...stages,
      TimerStage(kind: TimerStageKind.sit, minutes: minutes),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final total = _total;
    final atLimit = stages.length >= kMaxTimerStages;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: Text(l10n.timerStagesTitle),
          subtitle: Text(l10n.timerStagesDescription),
          value: _enabled,
          onChanged: (on) =>
              onChanged(on ? seedTimerStages(currentMinutes) : const []),
        ),
        if (_enabled) ...[
          for (var i = 0; i < stages.length; i++)
            _StageRow(
              stage: stages[i],
              canRemove: stages.length > kMinTimerStages,
              canGrow:
                  total < kMaxTimerMinutes &&
                  stages[i].minutes < kMaxTimerMinutes,
              onChanged: (stage) => _replace(i, stage),
              onRemove: () => onChanged([...stages]..removeAt(i)),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: atLimit || total >= kMaxTimerMinutes ? null : _add,
              icon: const Icon(Icons.add),
              label: Text(l10n.timerStageAdd),
            ),
          ),
          if (atLimit)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.timerStageLimit,
                style: theme.textTheme.bodySmall,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              l10n.timerStagesTotal(
                formatTimerLength(Duration(minutes: total), l10n),
              ),
              style: theme.textTheme.titleSmall,
            ),
          ),
        ],
      ],
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({
    required this.stage,
    required this.canRemove,
    required this.canGrow,
    required this.onChanged,
    required this.onRemove,
  });

  final TimerStage stage;
  final bool canRemove;
  final bool canGrow;
  final ValueChanged<TimerStage> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final soundName = BellSound.resolve(stage.sound).name(l10n);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButton<TimerStageKind>(
                    value: stage.kind,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final kind in TimerStageKind.values)
                        DropdownMenuItem(
                          value: kind,
                          child: Text(timerStageKindLabel(l10n, kind)),
                        ),
                    ],
                    onChanged: (kind) {
                      if (kind != null) onChanged(stage.copyWith(kind: kind));
                    },
                  ),
                ),
                if (canRemove)
                  IconButton(
                    tooltip: l10n.timerStageRemove,
                    icon: const Icon(Icons.close),
                    onPressed: onRemove,
                  ),
              ],
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  tooltip: l10n.timerStageMinus,
                  icon: const Icon(Icons.remove_rounded),
                  onPressed: stage.minutes > 1
                      ? () => onChanged(
                          stage.copyWith(minutes: stage.minutes - 1),
                        )
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    formatTimerLength(stage.duration, l10n),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: l10n.timerStagePlus,
                  icon: const Icon(Icons.add_rounded),
                  onPressed: canGrow
                      ? () => onChanged(
                          stage.copyWith(minutes: stage.minutes + 1),
                        )
                      : null,
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => showTimerBellSoundPicker(
                  context,
                  selected: stage.sound,
                  onSelected: (sound) =>
                      onChanged(stage.copyWith(sound: sound)),
                ),
                child: Text(l10n.bellSoundSelection(soundName)),
              ),
            ),
            // Veces que suena la campana de esta parte, igual que en las
            // campanas generales.
            ListTile(
              contentPadding: const EdgeInsetsDirectional.only(end: 8),
              title: Text(l10n.timerBellRepeats),
              subtitle: DropdownButton<int>(
                value: timerBellRepeatOptions.contains(stage.repeats)
                    ? stage.repeats
                    : timerBellRepeatOptions.first,
                isExpanded: true,
                itemHeight: null,
                items: [
                  for (final option in timerBellRepeatOptions)
                    DropdownMenuItem(
                      value: option,
                      child: Text(l10n.timerBellRepeatCount(option)),
                    ),
                ],
                onChanged: (repeats) {
                  if (repeats != null && repeats != stage.repeats) {
                    onChanged(stage.copyWith(repeats: repeats));
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
