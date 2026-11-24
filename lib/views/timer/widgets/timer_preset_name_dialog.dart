import 'package:flutter/material.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/models/timer/timer_preset.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/models/timer/timer_settings.dart';
import 'package:medito/views/timer/timer_format.dart';

/// Nombre que se propone al guardar, como «20 min · Campana clásica»: la
/// duración (o «Cronómetro») y la campana de inicio; sin ella, la de cierre;
/// sin ninguna, «Sin campanas». Por partes, la campana de la primera parte
/// ocupa el lugar de la de inicio.
String timerPresetAutoName(TimerSettings settings, AppLocalizations l10n) {
  final duration = settings.mode == TimerMode.stopwatch
      ? l10n.timerModeStopwatch
      : formatTimerLength(settings.plannedDuration, l10n);
  final bells = settings.bells;
  final String bell;
  if (settings.isMultiStage) {
    bell = BellSound.resolve(settings.stages.first.sound).name(l10n);
  } else if (bells.start) {
    bell = BellSound.resolve(bells.startSound).name(l10n);
  } else if (bells.end) {
    bell = BellSound.resolve(bells.endSound).name(l10n);
  } else {
    bell = l10n.timerBellsSummaryNone;
  }
  return l10n.timerPresetAutoName(duration, bell);
}

/// Pide el nombre de un temporizador guardado. Se abre con [initialName]
/// escrito (nombre automático al guardar, nombre actual al cambiarlo).
class TimerPresetNameDialog extends StatefulWidget {
  const TimerPresetNameDialog({
    super.key,
    required this.initialName,
    this.title,
  });

  final String initialName;

  /// Título del diálogo; sin él dice «Guardar temporizador».
  final String? title;

  @override
  State<TimerPresetNameDialog> createState() => _TimerPresetNameDialogState();
}

class _TimerPresetNameDialogState extends State<TimerPresetNameDialog> {
  TextEditingController? _name;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // El campo admite hasta el máximo de letras: un nombre automático más
    // largo se corta.
    _name ??= TextEditingController(
      text: widget.initialName.characters
          .take(kMaxTimerPresetNameLength)
          .toString()
          .trim(),
    );
  }

  @override
  void dispose() {
    _name?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = _name!;
    final valid = TimerPreset.isValidName(name.text.trim());
    return AlertDialog(
      title: Text(widget.title ?? l10n.timerSavePreset),
      content: TextField(
        autofocus: true,
        controller: name,
        maxLength: kMaxTimerPresetNameLength,
        decoration: InputDecoration(labelText: l10n.timerPresetName),
        onChanged: (_) => setState(() {}),
        onSubmitted: (value) {
          if (TimerPreset.isValidName(value.trim())) {
            Navigator.pop(context, value.trim());
          }
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.timerPresetCancel),
        ),
        TextButton(
          onPressed: valid
              ? () => Navigator.pop(context, name.text.trim())
              : null,
          child: Text(l10n.timerPresetSave),
        ),
      ],
    );
  }
}
