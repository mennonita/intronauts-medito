import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/providers/timer/timer_content_provider.dart';
import 'package:medito/repositories/timer/timer_content_repository.dart';

final _noteReceiptProvider = Provider((ref) => _NoteReceipt());

class _NoteReceipt {
  ({String sessionId, String text})? latest;
}

class TimerNoteSheet extends ConsumerStatefulWidget {
  const TimerNoteSheet({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<TimerNoteSheet> createState() => _TimerNoteSheetState();
}

class _TimerNoteSheetState extends ConsumerState<TimerNoteSheet> {
  late final TextEditingController _controller;
  bool _saving = false;
  TimerNoteSaveResult? _result;

  bool get _saved => _result == TimerNoteSaveResult.saved;
  bool get _conflict => _result == TimerNoteSaveResult.conflict;
  bool get _readOnly => _saved || _conflict;
  bool get _canSave =>
      !_saving && !_readOnly && _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    final latest = ref.read(_noteReceiptProvider).latest;
    if (latest != null && latest.sessionId == widget.sessionId) {
      _result = TimerNoteSaveResult.saved;
      _controller = TextEditingController(text: latest.text);
    } else {
      _controller = TextEditingController();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final sessionId = widget.sessionId;
    final text = _controller.text.trim();
    final receipt = ref.read(_noteReceiptProvider);
    final latest = receipt.latest;
    if (latest != null && latest.sessionId == sessionId) {
      final matches = latest.text == text;
      if (matches) _controller.text = text;
      FocusScope.of(context).unfocus();
      setState(() {
        _result = matches
            ? TimerNoteSaveResult.saved
            : TimerNoteSaveResult.conflict;
      });
      return;
    }
    setState(() {
      _saving = true;
      _result = null;
    });
    final result = await ref
        .read(timerContentRepositoryProvider)
        .submitNote(sessionId: sessionId, note: text);
    if (result == TimerNoteSaveResult.saved) {
      receipt.latest = (sessionId: sessionId, text: text);
    }
    if (!mounted) return;
    if (result == TimerNoteSaveResult.saved) _controller.text = text;
    if (result == TimerNoteSaveResult.saved ||
        result == TimerNoteSaveResult.conflict) {
      FocusScope.of(context).unfocus();
    }
    setState(() {
      _saving = false;
      _result = result;
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
                controller: _controller,
                autofocus: !_readOnly,
                readOnly: _saving || _readOnly,
                keyboardType: TextInputType.multiline,
                minLines: 3,
                maxLines: 6,
                maxLength: 2000,
                decoration: InputDecoration(
                  hintText: l10n.timerNoteHint,
                  errorText: _result != null && !_saved
                      ? l10n.timerNoteError
                      : null,
                  errorMaxLines: 3,
                ),
                onChanged: (_) => setState(() => _result = null),
              ),
              if (_saved) Text(l10n.timerNoteSaved),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(_saved),
                      child: Text(
                        _readOnly ? l10n.timerDone : l10n.timerPresetCancel,
                      ),
                    ),
                    if (!_readOnly)
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
