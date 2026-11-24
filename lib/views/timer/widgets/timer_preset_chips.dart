import 'package:flutter/material.dart';
import 'package:medito/constants/constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_preset.dart';
import 'package:medito/models/timer/timer_session.dart';

import 'timer_preset_manager_sheet.dart';

/// Lo que se puede hacer con un temporizador guardado desde su menú.
enum TimerPresetAction { rename, update, moveUp, moveDown, delete }

/// Temporizadores guardados: tocar uno lo carga en la pantalla (no empieza);
/// el botón de tres puntos abre sus opciones.
class TimerSavedPresetChips extends StatelessWidget {
  const TimerSavedPresetChips({
    super.key,
    required this.presets,
    required this.onLoad,
    required this.onAction,
    this.enabled = true,
    this.canUpdate = true,
  });

  static const minSize = 58.0;

  /// Falso cuando los ajustes en pantalla no pueden guardarse (0 minutos).
  final bool canUpdate;
  final List<TimerPreset> presets;
  final ValueChanged<TimerPreset> onLoad;
  final void Function(TimerPreset preset, TimerPresetAction action) onAction;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < presets.length; i++)
          _SavedPresetChip(
            preset: presets[i],
            isFirst: i == 0,
            isLast: i == presets.length - 1,
            enabled: enabled,
            canUpdate: canUpdate,
            onLoad: () => onLoad(presets[i]),
            onAction: (action) => onAction(presets[i], action),
          ),
      ],
    );
  }
}

class _SavedPresetChip extends StatelessWidget {
  const _SavedPresetChip({
    required this.preset,
    required this.isFirst,
    required this.isLast,
    required this.enabled,
    required this.canUpdate,
    required this.onLoad,
    required this.onAction,
  });

  final TimerPreset preset;
  final bool isFirst;
  final bool isLast;
  final bool enabled;
  final bool canUpdate;
  final VoidCallback onLoad;
  final ValueChanged<TimerPresetAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final onSurface = theme.colorScheme.onSurface;
    final radius = BorderRadius.circular(16);
    // Sin alto fijo: crece con el tamaño de letra.
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: TimerSavedPresetChips.minSize,
        minHeight: TimerSavedPresetChips.minSize,
      ),
      child: Material(
        color: theme.cardColor,
        borderRadius: radius,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InkWell(
                borderRadius: radius,
                onTap: enabled ? onLoad : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: TimerSavedPresetChips.minSize,
                  ),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 4, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          preset.name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          timerPresetLengthLabel(preset, l10n),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            PopupMenuButton<TimerPresetAction>(
              tooltip: l10n.timerPresetOptions(preset.name),
              icon: const Icon(Icons.more_vert),
              enabled: enabled,
              onSelected: onAction,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: TimerPresetAction.rename,
                  child: Text(l10n.timerPresetRename),
                ),
                PopupMenuItem(
                  value: TimerPresetAction.update,
                  enabled: canUpdate,
                  child: Text(l10n.timerPresetUpdate),
                ),
                PopupMenuItem(
                  value: TimerPresetAction.moveUp,
                  enabled: !isFirst,
                  child: Text(l10n.timerPresetMoveUp),
                ),
                PopupMenuItem(
                  value: TimerPresetAction.moveDown,
                  enabled: !isLast,
                  child: Text(l10n.timerPresetMoveDown),
                ),
                PopupMenuItem(
                  value: TimerPresetAction.delete,
                  child: Text(l10n.timerPresetDelete),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Duraciones de un toque (3, 5, 10, 15 y 20 min). Círculos de al menos
/// [minSize] que crecen con el tamaño de letra y bajan de renglón si no caben.
class TimerDurationChips extends StatelessWidget {
  const TimerDurationChips({
    super.key,
    required this.selectedMinutes,
    required this.onSelected,
  });

  static const minSize = 58.0;

  final int selectedMinutes;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final size = MediaQuery.textScalerOf(
      context,
    ).scale(minSize).clamp(minSize, double.infinity);
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      // Separación mínima: cinco círculos caben en un teléfono de 360 dp.
      spacing: 4,
      runSpacing: 8,
      children: [
        for (final minutes in kTimerPresetMinutes)
          _DurationChip(
            minutes: minutes,
            size: size,
            selected: minutes == selectedMinutes,
            label: l10n.min,
            semanticLabel: l10n.timerPresetSemantics(minutes),
            onTap: () => onSelected(minutes),
            theme: theme,
          ),
      ],
    );
  }
}

class _DurationChip extends StatelessWidget {
  const _DurationChip({
    required this.minutes,
    required this.size,
    required this.selected,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    required this.theme,
  });

  final int minutes;
  final double size;
  final bool selected;
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final background = selected ? context.brandAccent : theme.cardColor;
    final foreground = selected
        ? context.onBrandAccent
        : theme.colorScheme.onSurface;
    return Semantics(
      label: semanticLabel,
      button: true,
      selected: selected,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: size,
        height: size,
        decoration: BoxDecoration(color: background, shape: BoxShape.circle),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$minutes',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground.withValues(alpha: 0.7),
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
