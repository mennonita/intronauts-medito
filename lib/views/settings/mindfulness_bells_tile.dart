import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/providers/notification/mindfulness_bells_provider.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/utils/notification_permission_flow.dart';
import 'package:medito/utils/permission_handler.dart';
import 'package:permission_handler/permission_handler.dart';

class MindfulnessBellsTile extends ConsumerStatefulWidget {
  const MindfulnessBellsTile({super.key});

  @override
  ConsumerState<MindfulnessBellsTile> createState() =>
      _MindfulnessBellsTileState();
}

class _MindfulnessBellsTileState extends ConsumerState<MindfulnessBellsTile> {
  bool _busy = false;

  Future<bool> _ensurePermission() async {
    final status = await Permission.notification.status;
    if (status.isGranted) return true;
    if (!mounted) return false;

    if (status.isPermanentlyDenied) {
      final openSettings = await showNotificationsBlockedDialog(context);
      return openSettings && mounted && await openSettingsAndAwaitPermission();
    }

    final proceed = await showNotificationPermissionPrimer(context);
    return proceed &&
        mounted &&
        await PermissionHandler.requestNotificationPermission(context);
  }

  Future<void> _setEnabled(bool enabled) => _change(() async {
    if (enabled && !await _ensurePermission()) {
      if (mounted) {
        _showMessage(
          AppLocalizations.of(context)!.mindfulnessBellsPermissionNeeded,
        );
      }
      return;
    }
    if (!mounted) return;
    await ref.read(mindfulnessBellsProvider.notifier).setEnabled(enabled);
  });

  Future<void> _change(Future<void> Function() apply) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await apply();
    } catch (error, stack) {
      AppLogger.e(
        'MINDFULNESS_BELLS',
        'No se pudo cambiar el horario',
        error,
        stack,
      );
      if (mounted) _showMessage(AppLocalizations.of(context)!.anErrorOccurred);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final config = ref.watch(mindfulnessBellsProvider);
    final notifier = ref.read(mindfulnessBellsProvider.notifier);
    final material = MaterialLocalizations.of(context);
    final hourNeedsPadding =
        hourFormat(of: material.timeOfDayFormat(alwaysUse24HourFormat: true)) ==
        HourFormat.H;

    String formatHour(int hour) {
      final formatted = material.formatTimeOfDay(
        TimeOfDay(hour: hour, minute: 0),
        alwaysUse24HourFormat: true,
      );
      return hour < 10 && hourNeedsPadding
          ? '${material.formatDecimal(0)}$formatted'
          : formatted;
    }

    return Column(
      children: [
        SwitchListTile(
          title: Text(l10n.mindfulnessBellsTitle),
          subtitle: Text(l10n.mindfulnessBellsSubtitle),
          value: config.enabled,
          onChanged: _busy ? null : _setEnabled,
        ),
        if (config.enabled) ...[
          _dropdown(
            value: config.startHour,
            min: 5,
            max: 22,
            label: (hour) => l10n.mindfulnessBellsFrom(formatHour(hour)),
            onChanged: notifier.setStartHour,
          ),
          _dropdown(
            value: config.endHour,
            min: 6,
            max: 23,
            label: (hour) => l10n.mindfulnessBellsUntil(formatHour(hour)),
            onChanged: notifier.setEndHour,
          ),
          _dropdown(
            value: config.everyHours,
            min: 1,
            max: 4,
            label: l10n.mindfulnessBellsEvery,
            onChanged: notifier.setEveryHours,
          ),
        ],
      ],
    );
  }

  Widget _dropdown({
    required int value,
    required int min,
    required int max,
    required String Function(int) label,
    required Future<void> Function(int) onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: DropdownButton<int>(
        value: value,
        isExpanded: true,
        style: ListTileTheme.of(context).titleTextStyle,
        items: [
          for (var option = min; option <= max; option++)
            DropdownMenuItem(value: option, child: Text(label(option))),
        ],
        onChanged: _busy
            ? null
            : (option) {
                if (option != null) _change(() => onChanged(option));
              },
      ),
    );
  }
}
