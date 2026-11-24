import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:medito/models/track/track.dart';
import '../background_sounds/background_sounds_model.dart';
import '../timer/bell_sound.dart';
import '../timer/timer_bell_settings.dart';

part 'playback_request.freezed.dart';
part 'playback_request.g.dart';

/// Everything the player needs to start (and keep showing) a track: a single
/// resolved voice + length variant, plus enough metadata to render the player
/// UI, lock screen, and notification without reaching back into the full
/// [Track] graph.
@freezed
abstract class PlaybackRequest with _$PlaybackRequest {
  const factory PlaybackRequest({
    required String trackId,
    required String fileId,
    required String title,
    required String description,
    required String coverUrl,
    required String remoteUrl,
    required int duration,
    required bool hasBackgroundSound,
    String? guideName,
    TrackArtist? artist,
    int? timerPlannedDurationMs,
    int? timerSeed,
    String? timerStopLabel,
    @Default(0) int timerPrepMs,
    @Default(false) bool timerExtraTime,
    @Default(<int>[]) List<int> timerStageDurationsMs,
    @Default(<String>[]) List<String> timerStageKinds,
    @Default('sound') String timerBellOutput,
    @Default('') String timerRunId,
    @Default('') String timerOwnerId,
    @JsonKey(toJson: _timerCuesToJson) List<TimerBellCue>? timerBellCues,
    @Default(defaultBellSoundId) BellSoundId timerEndSound,
    @Default(true) bool timerEndBellEnabled,
    @Default(false) bool overrideBackgroundSound,
    BackgroundSoundsModel? backgroundSound,
  }) = _PlaybackRequest;

  factory PlaybackRequest.fromJson(Map<String, Object?> json) =>
      _$PlaybackRequestFromJson(json);

  factory PlaybackRequest.fromTrack(
    Track track,
    TrackVoice voice,
    TrackAudioFile file,
  ) => PlaybackRequest(
    trackId: track.id,
    fileId: file.id,
    title: track.title,
    description: track.description,
    coverUrl: track.coverUrl,
    remoteUrl: file.path,
    duration: file.duration,
    hasBackgroundSound: track.hasBackgroundSound,
    guideName: voice.guideName,
    artist: track.artist,
  );
}

List<Map<String, Object>>? _timerCuesToJson(List<TimerBellCue>? cues) =>
    cues?.map((cue) => cue.toJson()).toList();
