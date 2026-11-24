import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/providers/timer/timer_preferences_provider.dart';
import 'package:medito/services/export/practice_export.dart';
import 'package:medito/views/settings/mindfulness_bells_tile.dart';

class TimerSettingsSection extends ConsumerStatefulWidget {
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
  ConsumerState<TimerSettingsSection> createState() =>
      _TimerSettingsSectionState();
}

class _TimerSettingsSectionState extends ConsumerState<TimerSettingsSection> {
  final _exportRowKey = GlobalKey();
  bool _sharing = false;

  Future<void> _sharePractice() async {
    final rowContext = _exportRowKey.currentContext;
    if (_sharing || rowContext == null) return;
    setState(() => _sharing = true);
    try {
      await sharePracticeCsv(rowContext);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final preferences = ref.watch(timerPreferencesProvider);
    final notifier = ref.read(timerPreferencesProvider.notifier);
    final showBells = widget.isAndroid ?? (!kIsWeb && Platform.isAndroid);
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final divider = Divider(
      height: 0.7,
      thickness: 0.7,
      indent: 16,
      endIndent: 16,
      color: onSurface.withValues(alpha: 0.2),
    );

    return ListTileTheme.merge(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      titleTextStyle: theme.textTheme.labelMedium?.copyWith(color: onSurface),
      subtitleTextStyle: theme.textTheme.titleSmall?.copyWith(
        color: onSurface.withValues(alpha: 0.7),
        letterSpacing: 0,
        height: 1.7,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.buildSectionTitle(context, l10n.timerSettingsSection),
          widget.buildSectionCard([
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
          widget.buildSectionTitle(context, l10n.settingsTimerOnlyTitle),
          widget.buildSectionCard([
            SwitchListTile(
              title: Text(l10n.settingsTimerOnlyOpen),
              value: preferences.openOnTimer,
              onChanged: notifier.setOpenOnTimer,
            ),
            divider,
            SwitchListTile(
              title: Text(l10n.settingsTimerOnlySkipEnd),
              value: preferences.skipEndScreen,
              onChanged: notifier.setSkipEndScreen,
            ),
            divider,
            ListTile(
              key: _exportRowKey,
              title: Text(l10n.settingsExportPractice),
              subtitle: Text(l10n.settingsExportPracticeSubtitle),
              onTap: _sharing ? null : _sharePractice,
            ),
          ]),
        ],
      ),
    );
  }
}
