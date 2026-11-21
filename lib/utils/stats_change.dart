import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/local_audio_completed.dart';
import 'package:medito/utils/audio_completion_tracker.dart';

class StatsChange {
  final Map<String, dynamic> json;

  StatsChange(this.json);

  StatsChange.completion(LocalAudioCompleted session, int duration)
    : this({
        'type': 'complete',
        'session': session.toJson(),
        'duration': duration,
      });

  StatsChange.remove(LocalAudioCompleted session)
    : this({'type': 'remove', 'session': session.toJson()});

  StatsChange.repeat(int duration)
    : this({'type': 'repeat', 'duration': duration});

  StatsChange.check(List<String> ids, bool checked)
    : this({'type': 'check', 'ids': List.of(ids), 'checked': checked});

  StatsChange.restore(LocalAllStats stats)
    : this({'type': 'restore', 'stats': stats.toJson()});

  LocalAllStats apply(LocalAllStats stats, int now, {bool replay = false}) {
    switch (json['type']) {
      case 'complete':
      case 'remove':
        final session = LocalAudioCompleted.fromJson(
          json['session'] as Map<String, dynamic>,
        );
        bool matches(LocalAudioCompleted item) =>
            item.id == session.id && item.timestamp == session.timestamp;
        final sessions = stats.audioCompleted ?? [];
        if (json['type'] == 'complete') {
          if (replay && sessions.any(matches)) return stats;
          return AudioCompletionTracker.updateStatsWithCompletedAudio(
            stats: stats,
            audioCompleted: session,
            duration: json['duration'] as int,
          );
        }
        final remaining = sessions.where((item) => !matches(item)).toList();
        if (remaining.length == sessions.length) return stats;
        return stats.copyWith(
          audioCompleted: remaining,
          totalTracksCompleted: (stats.totalTracksCompleted - 1).clamp(
            0,
            1 << 31,
          ),
          updated: now,
        );
      case 'repeat':
        return AudioCompletionTracker.addRepeatListeningTime(
          stats: stats,
          duration: json['duration'] as int,
        );
      case 'check':
        final tracks = [...?stats.tracksChecked];
        final ids = (json['ids'] as List).cast<String>().toSet();
        if (json['checked'] == true) {
          tracks.addAll(ids.difference(tracks.toSet()));
        } else {
          tracks.removeWhere(ids.contains);
        }
        if (tracks.length == (stats.tracksChecked?.length ?? 0)) return stats;
        return stats.copyWith(tracksChecked: tracks, updated: now);
      case 'restore':
        return LocalAllStats.fromJson(
          json['stats'] as Map<String, dynamic>,
        ).copyWith(updated: now);
      default:
        return stats;
    }
  }
}
