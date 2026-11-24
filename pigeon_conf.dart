import 'package:pigeon/pigeon.dart';

// Genera el puente con dart run pigeon --input pigeon_conf.dart.

// #docregion config
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/audio_pigeon.g.dart',
    dartPackageName: 'medito',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/meditofoundation/medito/pigeon/AudioPigeon.g.kt',
    kotlinOptions: KotlinOptions(package: 'meditofoundation.medito.pigeon'),
  ),
)
// #enddocregion config
// #docregion host-definitions
//ignore:prefer-match-file-name
class AudioData {
  AudioData({
    required this.url,
    required this.track,
    this.timerSeed,
    this.timerHasExtraTime,
    this.timerStopLabel,
    this.timerPrepMs,
    this.timerPlannedMs,
    this.timerIsStopwatch,
    this.timerBellOutput,
    this.timerMixWithOthers,
    this.dndRequested,
    this.timerLanguageTag,
    this.timerPausedText,
    this.timerPrepText,
    this.timerExtraTimeText,
    this.timerHeadphonesPausedText,
    this.timerOtherAudioPausedText,
    this.timerAlertsChannelName,
    this.timerRunId,
    this.timerOwnerId,
    this.timerBackupTitle,
    this.timerBackupBody,
    this.timerBackupChannelName,
    this.timerBackupSilentChannelName,
    this.timerDndRuleName,
  });

  String url;
  Track track;
  int? timerSeed;
  bool? timerHasExtraTime;
  String? timerStopLabel;
  // Cuenta regresiva antes de la campana de inicio, en ms.
  int? timerPrepMs;
  // Duración planeada en ms; cinco horas para el cronómetro.
  int? timerPlannedMs;
  // Indica si la sesión usa el modo cronómetro.
  bool? timerIsStopwatch;
  // Salida de la campana: sonido, vibración o ambos.
  String? timerBellOutput;
  // Permite que suene el audio de otras apps durante la sesión.
  bool? timerMixWithOthers;
  // La persona activó No molestar y Android concedió acceso.
  bool? dndRequested;
  // Etiqueta de idioma que se usa para leer los avisos en voz alta.
  String? timerLanguageTag;
  // Texto que indica que la sesión está en pausa.
  String? timerPausedText;
  // Texto que aparece durante la preparación.
  String? timerPrepText;
  // Texto que indica que empezó el tiempo extra.
  String? timerExtraTimeText;
  // Aviso de pausa por desconexión de audífonos.
  String? timerHeadphonesPausedText;
  // Aviso de pausa porque otra app empezó a sonar.
  String? timerOtherAudioPausedText;
  // Nombre del canal de avisos del temporizador.
  String? timerAlertsChannelName;
  // Identificador de la sesión para recuperación, avisos y notas.
  String? timerRunId;
  // Identificador verificado al reservar la sesión; vacío si no se verificó.
  String? timerOwnerId;
  // Título del aviso de respaldo que marca el fin de la sesión.
  String? timerBackupTitle;
  // Texto del aviso de respaldo con la duración ya incluida.
  String? timerBackupBody;
  // Nombre del canal del aviso de respaldo con sonido.
  String? timerBackupChannelName;
  // Nombre del canal del aviso de respaldo sin sonido.
  String? timerBackupSilentChannelName;
  // Nombre de la regla de No molestar para Android 15 en adelante.
  String? timerDndRuleName;
}

class BellCue {
  BellCue({required this.offsetMs, required this.kind, required this.assetKey});

  int offsetMs;
  String kind;
  String assetKey;
}

enum RepeatMode { none, once, infinite }

@HostApi()
abstract class MeditoAndroidAudioServiceManager {
  void startService();

  @async
  bool isServiceReady();
}

@HostApi()
abstract class MeditoWidgetManager {
  @async
  bool pinWidget(String widgetType);
}

@HostApi()
abstract class MeditoAppIconManager {
  @async
  String? getAlternateIconName();

  @async
  void setAlternateIconName(String? iconName);
}

enum HealthConnectStatus { available, notInstalled, notSupported }

@HostApi()
abstract class MeditoHealthConnectManager {
  @async
  HealthConnectStatus getStatus();

  @async
  bool hasMindfulnessPermissions();

  @async
  bool requestMindfulnessPermissions();

  // Clave estable: Health Connect no duplica un reintento.
  @async
  bool writeMindfulnessSession(
    int startEpochMs,
    int endEpochMs,
    String clientRecordId,
  );

  void openHealthConnectInstall();
}

@HostApi()
abstract class MeditoAudioServiceApi {
  bool playAudio(AudioData audioData);

  void playPauseAudio();

  void stopAudio();

  void setSpeed(double speed);

  void seekToPosition(int position);

  void skip10SecondsForward();

  void skip10SecondsBackward();

  void setRepeatMode(RepeatMode mode);

  void setBackgroundSound(String? uri);

  void setBackgroundSoundVolume(double volume);

  void stopBackgroundSound();

  /// Start/middle/end bells, independent of the ambient background sound.
  void setSessionBells(bool enabled);

  void setBellCues(bool useTrackSchedule, List<BellCue> cues);

  TimerStopReport stopTimerPlayback(int sessionSeed, bool save);

  // Confirma que el reproductor pudo preparar el archivo.
  @async
  bool playBackgroundSound();

  void pauseBackgroundSound();
}

// #enddocregion host-definitions

// #docregion flutter-definitions
class PlaybackState {
  bool isPlaying;
  bool isBuffering;
  bool isSeeking;
  bool isCompleted;
  int position;
  int duration;
  Speed speed;
  int volume;
  Track track;
  BackgroundSound? backgroundSound;
  // true cuando empezó a sonar la campana final de esta sesión; null en guiadas.
  bool? endCueRang;
  // Identificador de la sesión del temporizador; null en meditaciones guiadas.
  String? runId;
  // true mientras el temporizador está listo pero su reloj espera el foco de
  // audio (llamada en curso o foco en espera); null en meditaciones guiadas.
  bool? waitingForFocus;

  PlaybackState({
    required this.isPlaying,
    required this.isBuffering,
    required this.isSeeking,
    required this.isCompleted,
    required this.position,
    required this.duration,
    required this.speed,
    required this.volume,
    required this.track,
    this.backgroundSound,
    this.endCueRang,
    this.runId,
    this.waitingForFocus,
  });
}

class BackgroundSound {
  String? uri;
  String title;

  BackgroundSound({required this.uri, required this.title});
}

class Speed {
  double speed;

  Speed({required this.speed});
}

class Track {
  String id;
  String title;
  String fileId;
  String description;
  String imageUrl;
  String? artist;
  String? artistUrl;

  Track({
    required this.id,
    required this.title,
    required this.fileId,
    required this.description,
    required this.imageUrl,
    this.artist,
    this.artistUrl,
  });
}

class TimerEndedData {
  TimerEndedData({
    required this.positionMs,
    required this.mode,
    required this.elapsedSeconds,
    required this.recorded,
  });

  int positionMs;
  String mode;
  int elapsedSeconds;
  bool recorded;
}

class CompletionData {
  String trackId;
  int duration;
  String fileId;
  String? guideId;
  int timestamp;
  String? userToken;
  TimerEndedData? timerEnded;
  // Identificador de la sesión del temporizador; null en meditaciones guiadas.
  String? runId;
  // Dueño de las estadísticas al reservar la sesión: id verificado, vacío si no está verificado.
  String? ownerId;
  // true si Android la recuperó tras cerrarse la app.
  bool? recovered;

  CompletionData({
    required this.trackId,
    required this.duration,
    required this.fileId,
    required this.guideId,
    required this.timestamp,
    required this.userToken,
    this.runId,
    this.ownerId,
    this.recovered,
  });
}

@FlutterApi()
abstract class MeditoAudioServiceCallbackApi {
  void updatePlaybackState(PlaybackState state);
  @async
  bool handleCompletedTrack(CompletionData completionData);
  // A repeated play-through (repeat once / forever): adds listening time only.
  @async
  bool handleRepeatPlaythrough(CompletionData completionData);
  void reportPlayerError(
    String errorCode,
    String message,
    int positionMs,
    int durationMs,
    String? runId,
  );
}

// #enddocregion flutter-definitions

class TimerStopReport {
  TimerStopReport({
    required this.positionMs,
    required this.endCueRang,
    required this.stopped,
    this.completionPersisted,
    this.runId,
  });

  int positionMs;
  bool endCueRang;
  bool stopped;
  bool? completionPersisted;
  // Identificador de la sesión del temporizador; null en meditaciones guiadas.
  String? runId;
}

@FlutterApi()
abstract class MeditoTimerStopCallbackApi {
  @async
  void timerStopped(int sessionSeed, TimerStopReport report);
}
