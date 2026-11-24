import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/services/timer/mantra_counter_store.dart';

/// Opciones del contador: «Llevar mi total», «Sumar cuentas», «Borrar mi
/// total» y «Empezar de cero». Todo se queda en el teléfono.
Future<void> showMantraTotalSheet(
  BuildContext context,
  MantraCounterStore store,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => MantraTotalSheet(store: store),
);

class MantraTotalSheet extends StatefulWidget {
  const MantraTotalSheet({super.key, required this.store});

  final MantraCounterStore store;

  @override
  State<MantraTotalSheet> createState() => _MantraTotalSheetState();
}

class _MantraTotalSheetState extends State<MantraTotalSheet> {
  final _addController = TextEditingController();
  bool _adding = false;

  MantraCounterStore get _store => widget.store;

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  /// Número escrito, o null si no está entre 1 y 1 000 000.
  int? get _typedAmount {
    final value = int.tryParse(_addController.text);
    if (value == null || value < 1 || value > MantraCounterStore.maxManualAdd) {
      return null;
    }
    return value;
  }

  void _confirmAdd() {
    final amount = _typedAmount;
    if (amount == null || !_store.addToTotal(amount)) return;
    _addController.clear();
    setState(() => _adding = false);
  }

  Future<bool> _confirm(String question, String action) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(question),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.timerPresetCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _clearTotal() async {
    final l10n = AppLocalizations.of(context)!;
    if (await _confirm(l10n.mantraTotalClearConfirm, l10n.mantraTotalClear)) {
      _store.clearTotal();
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _reset() async {
    final l10n = AppLocalizations.of(context)!;
    if (await _confirm(
      l10n.mantraCounterResetConfirm,
      l10n.mantraCounterReset,
    )) {
      _store.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final enabled = _store.totalEnabled;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    title: Text(l10n.mantraTotalSwitch),
                    value: enabled,
                    onChanged: _store.setTotalEnabled,
                  ),
                  if (enabled) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        l10n.mantraTotalValue(_store.total),
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    if (_adding)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const ValueKey('mantra-add-field'),
                                controller: _addController,
                                autofocus: true,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(7),
                                ],
                                decoration: InputDecoration(
                                  hintText: l10n.mantraTotalAddHint,
                                ),
                                onChanged: (_) => setState(() {}),
                                onSubmitted: (_) => _confirmAdd(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: _typedAmount == null
                                  ? null
                                  : _confirmAdd,
                              child: Text(l10n.mantraTotalAddConfirm),
                            ),
                          ],
                        ),
                      )
                    else
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          onPressed: () => setState(() => _adding = true),
                          child: Text(l10n.mantraTotalAdd),
                        ),
                      ),
                  ],
                  // Un total guardado se puede borrar aunque esté apagado.
                  if (enabled || _store.total > 0)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        onPressed: _clearTotal,
                        child: Text(l10n.mantraTotalClear),
                      ),
                    ),
                  const Divider(),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: _reset,
                      child: Text(l10n.mantraCounterReset),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
