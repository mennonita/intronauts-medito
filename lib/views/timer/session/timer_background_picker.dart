import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_background.dart';
import 'package:medito/providers/timer/timer_background_provider.dart';

import 'timer_backgrounds.dart';

Future<void> showTimerBackgroundPicker(BuildContext context) {
  final container = ProviderScope.containerOf(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: timerPickerBarrierColor,
    builder: (sheetContext) => SizedBox(
      height:
          MediaQuery.sizeOf(sheetContext).height * timerPickerHeightFraction,
      child: UncontrolledProviderScope(
        container: container,
        child: const SafeArea(top: false, child: TimerBackgroundPicker()),
      ),
    ),
  );
}

class TimerBackgroundPicker extends ConsumerWidget {
  const TimerBackgroundPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final selected = ref.watch(timerBackgroundProvider);
    final theme = Theme.of(context);
    final groups = {
      TimerBackgroundKind.animation: l10n.timerBackgroundAnimation,
      TimerBackgroundKind.image: l10n.timerBackgroundImage,
      TimerBackgroundKind.color: l10n.timerBackgroundColor,
      TimerBackgroundKind.black: l10n.timerBackgroundNone,
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      children: [
        Text(
          l10n.timerBackgroundTitle,
          style: theme.textTheme.titleLarge,
          semanticsLabel: l10n.timerBackgroundTitle,
        ),
        for (final MapEntry(:key, :value) in groups.entries) ...[
          const SizedBox(height: 16),
          Text(value, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final background in TimerBackground.values)
                if (background.kind == key)
                  _BackgroundTile(
                    background: background,
                    label: _label(background, l10n),
                    selected: background == selected,
                    onTap: () => ref
                        .read(timerBackgroundProvider.notifier)
                        .set(background),
                  ),
            ],
          ),
        ],
      ],
    );
  }

  String _label(TimerBackground background, AppLocalizations l10n) =>
      switch (background) {
        TimerBackground.breathing => l10n.timerBackgroundBreathing,
        TimerBackground.waves => l10n.timerBackgroundWaves,
        TimerBackground.particles => l10n.timerBackgroundParticles,
        TimerBackground.sunrise => l10n.timerBackgroundSunrise,
        TimerBackground.mist => l10n.timerBackgroundMist,
        TimerBackground.night => l10n.timerBackgroundNight,
        TimerBackground.slate => l10n.timerBackgroundSlate,
        TimerBackground.forest => l10n.timerBackgroundForest,
        TimerBackground.plum => l10n.timerBackgroundPlum,
        TimerBackground.ocean => l10n.timerBackgroundOcean,
        TimerBackground.cream => l10n.timerBackgroundCream,
        TimerBackground.ice => l10n.timerBackgroundIce,
        TimerBackground.rose => l10n.timerBackgroundRose,
        TimerBackground.lavender => l10n.timerBackgroundLavender,
        TimerBackground.black => l10n.timerBackgroundNone,
      };
}

class _BackgroundTile extends StatelessWidget {
  const _BackgroundTile({
    required this.background,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final TimerBackground background;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          padding: const EdgeInsets.all(4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        onPressed: onTap,
        child: SizedBox(
          width: 88,
          child: Column(
            children: [
              SizedBox(
                height: 48,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      TimerBackgroundCanvas(background: background),
                      if (selected)
                        const Positioned(
                          top: 4,
                          right: 4,
                          child: CircleAvatar(
                            radius: 10,
                            backgroundColor: Colors.black,
                            child: Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(label, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
