// ignore_for_file: use_build_context_synchronously

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:medito/constants/icons/medito_icons.dart';
import 'package:medito/utils/health_kit_manager.dart';
import 'package:medito/utils/health_sync_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../widgets/snackbar_widget.dart';
import '../../l10n/app_localizations.dart';
import '../home/widgets/bottom_sheet/row_item_widget.dart';
import '../../widgets/medito_icon.dart';

/// Interruptor del permiso de Salud. Encenderlo pide permiso de escritura y,
/// si se da, guarda el permiso de la cuenta actual; apagarlo lo quita y vacía
/// la cola.
class HealthSyncTile extends StatefulWidget {
  const HealthSyncTile({
    super.key,
    this.hasUnderline = true,
    this.manager,
    this.isAndroid,
  });

  final bool hasUnderline;

  /// Para pruebas; por defecto el de la app.
  final HealthKitManager? manager;

  /// Para pruebas; por defecto la plataforma real.
  final bool? isAndroid;

  @override
  State<HealthSyncTile> createState() => _HealthSyncTileState();
}

class _HealthSyncTileState extends State<HealthSyncTile> {
  bool _enabled = false;
  bool _busy = false;

  HealthKitManager get _manager => widget.manager ?? HealthKitManager();
  bool get _isAndroid => widget.isAndroid ?? Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _enabled = HealthSyncQueue.hasConsent(prefs));
  }

  Future<void> _setEnabled(bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (on) {
        await _turnOn();
      } else {
        await HealthSyncQueue.setConsent(false);
        if (mounted) setState(() => _enabled = false);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOn() async {
    final l10n = AppLocalizations.of(context)!;
    final manager = _manager;

    if (_isAndroid && !await manager.isHealthConnectAvailable()) {
      await manager.installHealthConnect();
      if (mounted) showSnackBar(context, l10n.healthConnectNotInstalled);
      return;
    }

    // En iOS la ventana del sistema puede cerrarse sin dar permiso: se
    // confirma que de verdad hay permiso de escritura.
    final granted =
        await manager.requestAuthorization() && await manager.hasWriteAccess();
    if (!granted) {
      if (!mounted) return;
      final explanation = _isAndroid
          ? l10n.permissionExplanationAndroid
          : l10n.permissionExplanation;
      showSnackBar(context, explanation);
      return;
    }

    await HealthSyncQueue.setConsent(true);
    if (mounted) setState(() => _enabled = true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = _isAndroid ? l10n.syncWithHealthConnect : l10n.syncWithHealth;
    return RowItemWidget(
      icon: MeditoIcon(
        assetName: MeditoIcons.health,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      title: title,
      hasUnderline: widget.hasUnderline,
      isSwitch: true,
      switchValue: _enabled,
      onSwitchChanged: _busy ? null : _setEnabled,
      onTap: _busy ? null : () => _setEnabled(!_enabled),
    );
  }
}
