import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:medito/utils/stats_updater.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

String buildPracticeCsv({
  required List<LocalAudioCompleted> account,
  required bool accountVerified,
  required List<LocalAudioCompleted> device,
  required AppLocalizations l10n,
  required DateTime Function(int ms) toLocal,
}) {
  final rows = [
    for (final completion in account)
      (completion: completion, fromAccount: accountVerified),
    for (final completion in device)
      (completion: completion, fromAccount: false),
  ]..sort((a, b) => a.completion.timestamp.compareTo(b.completion.timestamp));

  final dateFormat = DateFormat('yyyy-MM-dd', 'en_US');
  final timeFormat = DateFormat('HH:mm', 'en_US');
  final csv = StringBuffer(l10n.exportCsvHeader)..write('\r\n');
  for (final row in rows) {
    final completion = row.completion;
    final dateTime = toLocal(completion.timestamp);
    final isTimer = isTimerSessionId(completion.id);
    final isManual = isManualSession(completion);
    final kind = switch ((isTimer, isManual)) {
      (true, _) => l10n.exportKindTimer,
      (_, true) => l10n.exportKindManual,
      _ => l10n.exportKindGuided,
    };
    final minutes = timerSessionDuration(completion.id)?.inMinutes;
    final cells = [
      dateFormat.format(dateTime),
      timeFormat.format(dateTime),
      kind,
      minutes?.toString() ?? '',
      isTimer || isManual ? '' : completion.id,
      row.fromAccount ? l10n.exportSourceAccount : l10n.exportSourceDevice,
    ];
    csv
      ..write(cells.map(_escapeCell).join(','))
      ..write('\r\n');
  }
  return csv.toString();
}

final _formulaStart = RegExp(r'^[-=+@]');
final _csvSpecialCharacter = RegExp(r'[,"\r\n]');

String _escapeCell(String value) {
  final guarded = _formulaStart.hasMatch(value) ? "'$value" : value;
  if (!_csvSpecialCharacter.hasMatch(guarded)) return guarded;
  return '"${guarded.replaceAll('"', '""')}"';
}

Future<void> sharePracticeCsv(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final stats = StatsManager();
  final generation = stats.localGeneration;
  try {
    // Carga el historial local antes de pedirlo para evitar la sincronización.
    await stats.hasLocalStats();
    final owner = stats.verifiedUserId;
    bool sameAccount() =>
        stats.localGeneration == generation && stats.verifiedUserId == owner;
    final account = (await stats.localAllStats).audioCompleted ?? const [];
    final device = await stats.preVerificationCompletions();
    if (!context.mounted) return;
    if (!sameAccount()) {
      throw StateError('Practice history changed accounts');
    }
    if (account.isEmpty && device.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.exportEmpty)));
      return;
    }

    final csv = buildPracticeCsv(
      account: account,
      accountVerified: owner != null,
      device: device,
      l10n: l10n,
      toLocal: DateTime.fromMillisecondsSinceEpoch,
    );
    final date = DateFormat('yyyy-MM-dd', 'en_US').format(DateTime.now());
    final temp = await getTemporaryDirectory();
    final folder = await temp.createTemp('practice-export-');
    try {
      final file = File('${folder.path}/mi-practica-$date.csv');
      await file.writeAsBytes(utf8.encode('\uFEFF$csv'));
      if (!context.mounted) return;
      if (!sameAccount()) {
        throw StateError('Practice history changed accounts');
      }
      final box = context.findRenderObject() as RenderBox?;
      final origin = box != null && box.hasSize
          ? box.localToGlobal(Offset.zero) & box.size
          : null;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: l10n.exportShareSubject,
          sharePositionOrigin: origin,
        ),
      );
    } finally {
      await folder.delete(recursive: true);
    }
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.exportFailed)));
  }
}
