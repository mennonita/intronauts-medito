import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/icons/medito_icons.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_preset.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/timer/timer_presets_provider.dart';
import 'package:medito/views/timer/timer_format.dart';
import 'package:medito/widgets/medito_icon.dart';

import 'timer_preset_name_dialog.dart';

/// Duración que se muestra junto al nombre de un temporizador guardado.
String timerPresetLengthLabel(TimerPreset preset, AppLocalizations l10n) =>
    preset.settings.mode == TimerMode.stopwatch
    ? l10n.timerModeStopwatch
    : formatTimerLength(preset.settings.plannedDuration, l10n);

void showTimerPresetWriteError(BuildContext context) {
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(l10n.timerPresetWriteError)));
}

/// Cambia el nombre de [preset] con el diálogo ya escrito con el actual.
Future<void> renameTimerPreset(
  BuildContext context,
  WidgetRef ref,
  TimerPreset preset,
) async {
  final l10n = AppLocalizations.of(context)!;
  final notifier = ref.read(timerPresetsProvider.notifier);
  final name = await showDialog<String>(
    context: context,
    builder: (_) => TimerPresetNameDialog(
      initialName: preset.name,
      title: l10n.timerPresetRename,
    ),
  );
  if (name == null || name == preset.name) return;
  final saved = await notifier.rename(preset.id, name);
  if (!saved && context.mounted) showTimerPresetWriteError(context);
}

/// Pregunta antes de borrar [preset].
Future<void> deleteTimerPreset(
  BuildContext context,
  WidgetRef ref,
  TimerPreset preset,
) async {
  final l10n = AppLocalizations.of(context)!;
  final notifier = ref.read(timerPresetsProvider.notifier);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.timerDeletePresetQuestion(preset.name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.timerPresetCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.timerPresetDelete),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final deleted = await notifier.delete(preset);
  if (!deleted && context.mounted) showTimerPresetWriteError(context);
}

Future<void> showTimerPresetManagerSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const TimerPresetManagerSheet(),
    );

/// «Editar guardados»: ordenar, cambiar nombre y borrar temporizadores.
class TimerPresetManagerSheet extends ConsumerWidget {
  const TimerPresetManagerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final presets = ref.watch(timerPresetsProvider);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                l10n.timerManagePresets,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                itemCount: presets.length,
                // El destino ya descuenta el elemento que se mueve.
                onReorderItem: (from, target) async {
                  if (target == from) return;
                  final moved = await ref
                      .read(timerPresetsProvider.notifier)
                      .move(presets[from].id, target);
                  if (!moved && context.mounted) {
                    showTimerPresetWriteError(context);
                  }
                },
                itemBuilder: (context, index) {
                  final preset = presets[index];
                  return ListTile(
                    key: ValueKey(preset.id),
                    title: Text(preset.name),
                    subtitle: Text(timerPresetLengthLabel(preset, l10n)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: l10n.timerPresetRename,
                          icon: const MeditoIcon(
                            assetName: MeditoIcons.pencil,
                            size: 22,
                          ),
                          onPressed: () =>
                              renameTimerPreset(context, ref, preset),
                        ),
                        IconButton(
                          tooltip: l10n.timerPresetDelete,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () =>
                              deleteTimerPreset(context, ref, preset),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.timerDone),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
