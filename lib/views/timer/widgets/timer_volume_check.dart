import 'package:flutter/material.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_bell_settings.dart';
import 'package:medito/services/timer/timer_device_channel.dart';

/// Revisa el volumen de multimedia antes de empezar (Android). Con volumen en
/// cero y campanas con sonido pregunta si se empieza así. Devuelve true para
/// seguir y false si la persona canceló, la pantalla ya no está o
/// [stillValid] dice que el inicio ya no sigue en pie.
Future<bool> confirmTimerVolume(
  BuildContext context, {
  required TimerBellOutput output,
  bool Function()? stillValid,
}) async {
  // Con solo vibración no importa el volumen.
  if (output == TimerBellOutput.vibration) return true;
  final volume = await TimerDeviceChannel.mediaVolumeFraction();
  if (volume == null || volume > 0) return true;
  if (!context.mounted) return false;
  if (stillValid != null && !stillValid()) return false;
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.timerVolumeZeroTitle),
      content: Text(l10n.timerVolumeZeroBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.timerPresetCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.timerStartAnyway),
        ),
      ],
    ),
  );
  return confirmed == true;
}
