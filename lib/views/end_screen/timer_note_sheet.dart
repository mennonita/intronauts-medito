import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/providers/timer/timer_content_provider.dart';

class TimerNoteSheet extends ConsumerStatefulWidget {
  const TimerNoteSheet({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<TimerNoteSheet> createState() => _TimerNoteSheetState();
}

class _TimerNoteSheetState extends ConsumerState<TimerNoteSheet> {
  String _note = '';
  bool _saving = false;
  bool _saveFailed = false;

  bool get _canSave => !_saving && _note.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    final saved = await ref
        .read(timerContentRepositoryProvider)
        .saveNote(sessionId: widget.sessionId, note: _note);
    if (!mounted) return;
    if (saved && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _saveFailed = !saved;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                autofocus: true,
                readOnly: _saving,
                keyboardType: TextInputType.multiline,
                minLines: 3,
                maxLines: 6,
                maxLength: 2000,
                decoration: InputDecoration(
                  hintText: l10n.timerNoteHint,
                  errorText: _saveFailed ? l10n.timerNoteError : null,
                  errorMaxLines: 3,
                ),
                onChanged: (value) => setState(() {
                  _note = value;
                  _saveFailed = false;
                }),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: Text(l10n.timerPresetCancel),
                    ),
                    FilledButton(
                      onPressed: _canSave ? _save : null,
                      child: Text(l10n.timerPresetSave),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
