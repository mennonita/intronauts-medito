import 'package:flutter/material.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_preset.dart';

class TimerPresetNameDialog extends StatefulWidget {
  const TimerPresetNameDialog({super.key});

  @override
  State<TimerPresetNameDialog> createState() => _TimerPresetNameDialogState();
}

class _TimerPresetNameDialogState extends State<TimerPresetNameDialog> {
  TextEditingController? _name;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _name ??= TextEditingController(
      text: AppLocalizations.of(context)!.timerDefaultPresetName,
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
      title: Text(l10n.timerSavePreset),
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
