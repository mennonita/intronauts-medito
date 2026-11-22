import 'package:flutter/material.dart';
import 'package:medito/l10n/app_localizations.dart';

class ReturnMessage extends StatelessWidget {
  const ReturnMessage({
    super.key,
    required this.returns,
    required this.pauseDays,
    this.style,
  });

  final int returns;
  final int? pauseDays;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final gap = pauseDays;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          gap == null ? l10n.returnsCompletion(returns) : l10n.returnedHeadline,
          style: style,
          textAlign: TextAlign.center,
        ),
        if (gap != null) ...[
          const SizedBox(height: 8),
          Text(
            l10n.returnedAfterPause(gap),
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
