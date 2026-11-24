import 'package:flutter/material.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_house_content.dart';
import 'package:medito/models/timer/timer_preset.dart';
import 'package:medito/models/timer/timer_settings.dart';

import 'timer_preset_manager_sheet.dart';

/// «Prácticas de la casa»: las prácticas que publica la organización, arriba
/// de los temporizadores guardados. Tocar una la carga en la pantalla igual
/// que un temporizador guardado; no empieza. Nombre y descripción se
/// muestran tal como llegan del servidor.
class TimerHousePractices extends StatelessWidget {
  const TimerHousePractices({
    super.key,
    required this.practices,
    required this.onLoad,
    this.enabled = true,
  });

  final List<TimerHousePractice> practices;
  final void Function(TimerHousePractice practice, TimerSettings settings)
  onLoad;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // Solo las que de verdad pueden empezar; sin ninguna no hay sección.
    final usable = [
      for (final practice in practices)
        if (practice.toSettings() case final settings?) (practice, settings),
    ];
    if (usable.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.timerHousePracticesTitle),
        const SizedBox(height: 8),
        for (final (practice, settings) in usable) ...[
          _HousePracticeCard(
            practice: practice,
            settings: settings,
            enabled: enabled,
            onTap: () => onLoad(practice, settings),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _HousePracticeCard extends StatelessWidget {
  const _HousePracticeCard({
    required this.practice,
    required this.settings,
    required this.enabled,
    required this.onTap,
  });

  final TimerHousePractice practice;
  final TimerSettings settings;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final onSurface = theme.colorScheme.onSurface;
    final radius = BorderRadius.circular(16);
    // La misma línea de duración que un temporizador guardado.
    final summary = timerPresetLengthLabel(
      TimerPreset(name: practice.name, settings: settings, sound: null),
      l10n,
    );
    final description = practice.description;
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: onSurface.withValues(alpha: 0.7),
    );
    // Para el lector de pantalla es un botón con nombre y duración.
    return Semantics(
      button: true,
      enabled: enabled,
      label: '${practice.name}, $summary',
      hint: description,
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: Material(
        color: theme.cardColor,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            // Sin alto fijo: crece con el tamaño de letra.
            constraints: const BoxConstraints(minHeight: 58),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    practice.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(summary, style: secondary),
                  if (description != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
