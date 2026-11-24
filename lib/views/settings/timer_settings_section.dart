import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/providers/timer/timer_preferences_provider.dart';
import 'package:medito/views/settings/mindfulness_bells_tile.dart';

class TimerSettingsSection extends ConsumerWidget {
  const TimerSettingsSection({
    super.key,
    required this.buildSectionTitle,
    required this.buildSectionCard,
    this.isAndroid,
  });

  final Widget Function(BuildContext, String) buildSectionTitle;
  final Widget Function(List<Widget>) buildSectionCard;
  final bool? isAndroid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final preferences = ref.watch(timerPreferencesProvider);
    final notifier = ref.read(timerPreferencesProvider.notifier);
    final showBells = isAndroid ?? (!kIsWeb && Platform.isAndroid);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final divider = Divider(
      height: 0.7,
      thickness: 0.7,
      indent: 16,
      endIndent: 16,
      color: onSurface.withValues(alpha: 0.2),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buildSectionTitle(context, l10n.timerSettingsSection),
        ListTileTheme.merge(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          titleTextStyle: theme.textTheme.labelMedium?.copyWith(
            color: onSurface,
          ),
          subtitleTextStyle: theme.textTheme.titleSmall?.copyWith(
            color: onSurface.withValues(alpha: 0.7),
            letterSpacing: 0,
            height: 1.7,
          ),
          child: buildSectionCard([
            SwitchListTile(
              title: Text(l10n.timerMixWithOthersTitle),
              subtitle: Text(l10n.timerMixWithOthersSubtitle),
              value: preferences.mixWithOthers,
              onChanged: notifier.setMixWithOthers,
            ),
            divider,
            SwitchListTile(
              title: Text(l10n.timerKeepScreenOnTitle),
              subtitle: Text(l10n.timerKeepScreenOnSubtitle),
              value: preferences.keepScreenOn,
              onChanged: notifier.setKeepScreenOn,
            ),
            if (showBells) ...[divider, const MindfulnessBellsTile()],
          ]),
        ),
      ],
    );
  }
}
