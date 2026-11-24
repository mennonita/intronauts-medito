import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/utils/health_kit_manager.dart';
import 'package:medito/utils/health_sync_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class TimerHealthAccess {
  Future<bool> isAvailable();
  Future<bool> requestAuthorization();
  Future<bool> hasWriteAccess();
}

final timerHealthAccessProvider = Provider<TimerHealthAccess>(
  (_) => _PlatformHealthAccess(),
);

class _PlatformHealthAccess implements TimerHealthAccess {
  @override
  Future<bool> isAvailable() async =>
      Platform.isIOS ||
      (Platform.isAndroid &&
          await HealthKitManager().isHealthConnectAvailable());

  @override
  Future<bool> requestAuthorization() =>
      HealthKitManager().requestAuthorization();

  @override
  Future<bool> hasWriteAccess() => HealthKitManager().hasWriteAccess();
}

class TimerHealthCard extends ConsumerStatefulWidget {
  const TimerHealthCard({super.key});

  @override
  ConsumerState<TimerHealthCard> createState() => _TimerHealthCardState();
}

class _TimerHealthCardState extends ConsumerState<TimerHealthCard> {
  late final SharedPreferences _prefs;
  late final TimerHealthAccess _access;
  bool _available = false;
  bool _busy = false;

  bool get _shouldOfferConsent =>
      _prefs.getBool(SharedPreferenceConstants.healthPromptDismissed) != true &&
      !HealthSyncQueue.hasConsent(_prefs);

  @override
  void initState() {
    super.initState();
    _prefs = ref.read(sharedPreferencesProvider);
    _access = ref.read(timerHealthAccessProvider);
    if (_shouldOfferConsent) _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    final available = await _access.isAvailable();
    if (mounted && available) setState(() => _available = true);
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        _showMessage(AppLocalizations.of(context)!.errorUnknownMessage);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enable() async {
    final account = _prefs.getString(SharedPreferenceConstants.serverUserId);
    final granted =
        await _access.requestAuthorization() && await _access.hasWriteAccess();
    if (!mounted) return;
    if (!granted) {
      final l10n = AppLocalizations.of(context)!;
      _showMessage(
        Platform.isAndroid
            ? l10n.permissionExplanationAndroid
            : l10n.permissionExplanation,
      );
      return;
    }
    // El permiso de escritura no cambia el consentimiento de otra cuenta.
    if (account != _prefs.getString(SharedPreferenceConstants.serverUserId)) {
      return;
    }
    await HealthSyncQueue.setConsent(true);
  }

  Future<void> _dismiss() async {
    final saved = await _prefs.setBool(
      SharedPreferenceConstants.healthPromptDismissed,
      true,
    );
    if (!saved) {
      if (mounted) {
        _showMessage(AppLocalizations.of(context)!.errorUnknownMessage);
      }
      return;
    }
    await HealthSyncQueue.dropAwaitingConsent();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (!_available || !_shouldOfferConsent) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    const minimumSize = Size(48, 48);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.timerHealthCardTitle, style: textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(l10n.timerHealthCardBody, style: textTheme.bodyMedium),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: minimumSize),
                    onPressed: _busy ? null : () => _runAction(_dismiss),
                    child: Text(l10n.timerHealthCardLater),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: minimumSize),
                    onPressed: _busy ? null : () => _runAction(_enable),
                    child: Text(l10n.timerHealthCardEnable),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
