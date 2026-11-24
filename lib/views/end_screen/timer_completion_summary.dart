import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_launch.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/timer/timer_content_provider.dart';
import 'package:medito/views/timer/timer_format.dart';
import 'package:medito/views/timer/timer_view.dart';

import 'timer_health_card.dart';
import 'timer_note_sheet.dart';

class TimerCompletionSummary extends ConsumerWidget {
  const TimerCompletionSummary({
    super.key,
    required this.request,
    this.timerElapsed,
  });

  final PlaybackRequest request;
  final Duration? timerElapsed;

  Future<void> _openNote(BuildContext context) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TimerNoteSheet(sessionId: request.timerRunId),
    );
    if (!context.mounted || saved != true) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.timerNoteSaved)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final elapsed =
        timerElapsed ?? Duration(milliseconds: request.plannedDurationMs);
    final closingText =
        ref.watch(timerClosingTextProvider).asData?.value ??
        l10n.timerClosingFallback;
    const minimumSize = Size(48, 48);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.timerCompletedTitle(formatTimerLength(elapsed, l10n)),
              style: theme.textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            closingText,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (request.timerRunId.isNotEmpty)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: minimumSize),
                  onPressed: () => _openNote(context),
                  child: Text(l10n.timerSaveNote),
                ),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: minimumSize),
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => const TimerView(
                      source: AnalyticsEventConstants.sourceEndScreen,
                      launch: TimerLaunch(last: true),
                    ),
                  ),
                ),
                child: Text(l10n.timerRepeat),
              ),
            ],
          ),
          const TimerHealthCard(),
        ],
      ),
    );
  }
}
