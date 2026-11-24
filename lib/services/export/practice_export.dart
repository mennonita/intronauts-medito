import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/utils/logger.dart';
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
bool _sharingPracticeCsv = false;

class PracticeExport {
  static const _folderPrefix = 'practice-export-';
  static const _retention = Duration(hours: 1);
  static final _fileName = RegExp(
    r'^mi-practica-\d{4}-\d{2}-\d{2}(?:-[a-zA-Z0-9_-]+)?\.csv$',
  );
  static int _generation = 0;

  static Future<void> cleanupExpiredCopies() => _cleanup(expiredOnly: true);

  static Future<void> clearForAccountChange() {
    _generation++;
    return _cleanup();
  }

  static Future<void> _cleanup({
    bool expiredOnly = false,
    Directory? temp,
  }) async {
    final before = expiredOnly ? DateTime.now().subtract(_retention) : null;
    try {
      final cache = temp ?? await getTemporaryDirectory();
      await for (final entry in cache.list(followLinks: false)) {
        if (entry is! Directory) continue;
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final isExportFolder = name.startsWith(_folderPrefix);
        if (!isExportFolder && name != 'share_plus') continue;
        var canRemoveFolder =
            before == null || (await entry.stat()).modified.isBefore(before);
        await for (final file in entry.list(followLinks: false)) {
          if (file is File && _fileName.hasMatch(file.uri.pathSegments.last)) {
            final modified = (await file.stat()).modified;
            if (before == null || modified.isBefore(before)) {
              await _deleteIfPresent(file);
              canRemoveFolder = true;
            }
          }
        }
        if (isExportFolder && canRemoveFolder && await entry.list().isEmpty) {
          await _deleteIfPresent(entry);
        }
      }
    } catch (error) {
      if (!expiredOnly) rethrow;
      AppLogger.w(
        'EXPORT',
        'No se pudo limpiar la caché de exportación: $error',
      );
    }
  }
}

Future<void> _deleteIfPresent(FileSystemEntity entry) async {
  try {
    await entry.delete();
  } on PathNotFoundException {
    // El sistema pudo limpiar la caché antes.
  }
}

String _escapeCell(String value) {
  final guarded = _formulaStart.hasMatch(value) ? "'$value" : value;
  if (!_csvSpecialCharacter.hasMatch(guarded)) return guarded;
  return '"${guarded.replaceAll('"', '""')}"';
}

Future<void> sharePracticeCsv(BuildContext context) async {
  if (_sharingPracticeCsv) return;
  final l10n = AppLocalizations.of(context)!;
  final stats = StatsManager();
  final generation = stats.localGeneration;
  final exportGeneration = PracticeExport._generation;
  _sharingPracticeCsv = true;
  try {
    final temp = await getTemporaryDirectory();
    await PracticeExport._cleanup(expiredOnly: true, temp: temp);
    // Carga el historial local antes de pedirlo para evitar la sincronización.
    await stats.hasLocalStats();
    final owner = stats.verifiedUserId;
    bool sameAccount() =>
        PracticeExport._generation == exportGeneration &&
        stats.localGeneration == generation &&
        stats.verifiedUserId == owner;
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
    final folder = await temp.createTemp(PracticeExport._folderPrefix);
    final android = defaultTargetPlatform == TargetPlatform.android;
    final folderName = folder.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final suffix = folderName.substring(PracticeExport._folderPrefix.length);
    final name = android
        ? 'mi-practica-$date-$suffix.csv'
        : 'mi-practica-$date.csv';
    final file = File('${folder.path}/$name');
    // Android copia el archivo a una carpeta propia y conserva solo el nombre.
    final sharedCopy = android ? File('${temp.path}/share_plus/$name') : file;
    var keepCopy = false;
    try {
      if (!sameAccount()) return;
      await file.writeAsBytes(utf8.encode('\uFEFF$csv'));
      if (!context.mounted) return;
      if (!sameAccount()) {
        throw StateError('Practice history changed accounts');
      }
      final box = context.findRenderObject() as RenderBox?;
      final origin = box != null && box.hasSize
          ? box.localToGlobal(Offset.zero) & box.size
          : null;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/csv')],
          subject: l10n.exportShareSubject,
          sharePositionOrigin: origin,
        ),
      );
      keepCopy = result.status != ShareResultStatus.dismissed && sameAccount();
    } finally {
      if (android || !keepCopy) {
        await _deleteIfPresent(file);
        await _deleteIfPresent(folder);
      }
      if (android && !keepCopy) await _deleteIfPresent(sharedCopy);
    }
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.exportFailed)));
  } finally {
    _sharingPracticeCsv = false;
  }
}
