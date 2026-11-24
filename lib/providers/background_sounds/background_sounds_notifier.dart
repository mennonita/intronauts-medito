import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/strings/shared_preference_constants.dart';
import '../../models/background_sounds/background_sounds_model.dart';
import '../../models/player/playback_request.dart';
import '../../models/timer/bell_sound.dart';
import '../../models/timer/timer_session.dart';
import '../../models/track/track.dart';
import '../../repositories/background_sounds/background_sounds_repository.dart';
import '../../repositories/downloader/downloader_repository.dart';
import '../../repositories/track/track_repository.dart';
import '../../services/account/playback_account.dart';
import '../../services/audio/session_bell_preview.dart';
import '../../src/audio_pigeon.g.dart' show MeditoAudioServiceApi;
import '../../utils/logger.dart';
import '../../utils/utils.dart' show getAudioFileExtension;
import '../player/ios_audio_handler.dart';
import '../player/player_provider.dart';
import '../shared_preference/shared_preference_provider.dart';

part 'background_sounds_notifier.g.dart';

final _api = MeditoAudioServiceApi();
final iosBackgroundPlayer = AudioPlayer(handleInterruptions: false)
  ..setLoopMode(LoopMode.all);

/// Whether [iosBackgroundPlayer] holds an ambient sound to resume with the
/// session. Session bells are separate (IosSessionBells), so this is no
/// longer implied by "bells are off".
bool iosAmbientActive = false;

String backgroundSoundFileName(BackgroundSoundsModel sound) {
  final hash = sha256.convert([
    ...utf8.encode(sound.id),
    0,
    ...utf8.encode(sound.version),
  ]);
  return 'bg-${hash.toString().substring(0, 32)}.mp3';
}

final backgroundSoundCacheDirectoryProvider =
    Provider<Future<Directory> Function()>(
      (ref) => getApplicationDocumentsDirectory,
    );

final _backgroundSoundCacheProvider = Provider<_BackgroundSoundCache>(
  (ref) => _BackgroundSoundCache(
    ref.watch(sharedPreferencesProvider),
    ref.watch(backgroundSoundCacheDirectoryProvider),
    ref.watch(trackRepositoryProvider).fetchTrackFromPreference,
  ),
);

class _BackgroundSoundCache {
  _BackgroundSoundCache(this._prefs, this._getDirectory, this._guidedDownloads);

  final SharedPreferences _prefs;
  final Future<Directory> Function() _getDirectory;
  final Future<List<Track>> Function() _guidedDownloads;
  final _downloads = <String, Future<String?>>{};
  List<BackgroundSoundsModel>? _fetchedCatalog;
  static final _cacheName = RegExp(r'^bg-[0-9a-f]{32}\.mp3$');
  static const _legacyDownloadsKey = 'background_sound_legacy_downloads';
  late final Future<List<BackgroundSoundsModel>> legacyDownloads =
      _saveLegacyDownloads();

  Future<List<BackgroundSoundsModel>> _saveLegacyDownloads() async {
    final snapshot = _prefs.getStringList(_legacyDownloadsKey);
    final entries =
        snapshot ??
        _prefs.getStringList(SharedPreferenceConstants.listBgSound) ??
        const [];
    final records = <String>[];
    final sounds = <BackgroundSoundsModel>[];
    for (final entry in entries) {
      try {
        final json = jsonDecode(entry);
        // La lista anterior a la caché por versión no guardaba este campo.
        if (json is! Map<String, dynamic> || json.containsKey('version')) {
          continue;
        }
        final sound = BackgroundSoundsModel.fromJson(json);
        if (_isAmbient(sound)) {
          records.add(entry);
          sounds.add(sound);
        }
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    // Conserva la lista anterior antes de agregar nuevas selecciones.
    if (snapshot == null) {
      try {
        if (!await _prefs.setStringList(_legacyDownloadsKey, records)) {
          return const [];
        }
      } on Exception catch (error) {
        AppLogger.w('BG_SOUND', 'No se pudo guardar la lista anterior: $error');
        return const [];
      }
    }
    return sounds;
  }

  Map<String, String> _mappedFiles() {
    final encoded = _prefs.get(
      SharedPreferenceConstants.backgroundSoundCacheFiles,
    );
    if (encoded is! String) return {};
    try {
      final decoded = jsonDecode(encoded);
      return {
        if (decoded is Map<String, dynamic>)
          for (final entry in decoded.entries)
            if (entry.value is String &&
                _cacheName.hasMatch(entry.value as String))
              entry.key: entry.value as String,
      };
    } on FormatException {
      return {};
    }
  }

  File? _legacyFile(Directory directory, String title) {
    if (title.isEmpty ||
        title == '.' ||
        title == '..' ||
        title.contains(RegExp(r'[/\\\x00]'))) {
      return null;
    }
    final name = '$title.mp3';
    // Un título antiguo puede coincidir con el nombre de otra descarga.
    if (_cacheName.hasMatch(name)) return null;
    final file = File(p.join(directory.path, name));
    return p.canonicalize(file.parent.path) == p.canonicalize(directory.path)
        ? file
        : null;
  }

  Future<String?> currentFile(BackgroundSoundsModel sound) async {
    final dir = await _getDirectory();
    final file = File(p.join(dir.path, backgroundSoundFileName(sound)));
    return await file.exists() ? file.path : null;
  }

  Stream<String> fallbackFiles(
    String id,
    Set<String> titles, {
    String? excluding,
  }) async* {
    final dir = await _getDirectory();
    final mappedName = _mappedFiles()[id];
    if (mappedName != null) {
      final file = File(p.join(dir.path, mappedName));
      if (file.path != excluding && await file.exists()) yield file.path;
    }
    for (final title in titles) {
      final file = _legacyFile(dir, title);
      if (file != null && file.path != excluding && await file.exists()) {
        yield file.path;
      }
    }
  }

  Future<String?> download(
    BackgroundSoundsModel sound,
    DownloaderRepository downloader, {
    bool replace = false,
  }) {
    final name = backgroundSoundFileName(sound);
    return _downloads.putIfAbsent(name, () async {
      try {
        final dir = await _getDirectory();
        final target = File(p.join(dir.path, name));
        // El descargador conserva los archivos existentes. La copia de
        // reparación se mueve al nombre final cuando termina la descarga.
        final downloadName = replace ? '$name.refresh' : name;
        await downloader.downloadFile(sound.path, fileName: downloadName);
        if (replace) {
          await File(p.join(dir.path, downloadName)).rename(target.path);
        }
        return await target.exists() ? target.path : null;
      } finally {
        _downloads.remove(name);
      }
    });
  }

  Future<void> remember(
    BackgroundSoundsModel sound, {
    required bool Function() isCurrent,
  }) async {
    final dir = await _getDirectory();
    if (!isCurrent()) return;
    final name = backgroundSoundFileName(sound);
    final replacement = File(p.join(dir.path, name));
    if (!await replacement.exists() || !isCurrent()) return;
    final mapped = _mappedFiles();
    final previous = mapped[sound.id];
    if (previous != name) {
      mapped[sound.id] = name;
      final saved = await _prefs.setString(
        SharedPreferenceConstants.backgroundSoundCacheFiles,
        jsonEncode(mapped),
      );
      if (!saved) return;
    }

    final latest = _mappedFiles();
    if (!isCurrent() || latest[sound.id] != name || !replacement.existsSync()) {
      return;
    }
    final belongsToAnotherSound = _fetchedCatalog?.any(
      (other) =>
          other.id != sound.id && backgroundSoundFileName(other) == previous,
    );
    if (previous != null &&
        !latest.containsValue(previous) &&
        belongsToAnotherSound != true) {
      _delete(File(p.join(dir.path, previous)));
    }
    final legacy = await legacyDownloads;
    final titles = {
      for (final item in legacy)
        if (item.id == sound.id) item.title,
    };
    if (titles.isNotEmpty && isCurrent()) {
      final guided = await _guidedDownloads();
      if (!isCurrent()) return;
      final guidedNames = {
        for (final track in guided)
          for (final voice in track.voices)
            for (final file in voice.audioFiles)
              '${track.id}-${file.id}${getAudioFileExtension(file.path)}',
      };
      final current = _mappedFiles();
      for (final title in titles) {
        final file = _legacyFile(dir, title);
        if (file == null || guidedNames.contains(p.basename(file.path))) {
          continue;
        }
        final shared = legacy.any((other) {
          if (other.id == sound.id || other.title != title) return false;
          final mappedName = current[other.id];
          return mappedName == null ||
              !File(p.join(dir.path, mappedName)).existsSync();
        });
        if (!shared) _delete(file);
      }
    }
    await _checkLegacyMigration();
  }

  void _delete(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException catch (_) {
      // Se vuelve a intentar cuando exista otra copia lista para usar.
    }
  }

  Future<void> catalogFetched(List<BackgroundSoundsModel> sounds) {
    _fetchedCatalog = sounds;
    return _checkLegacyMigration();
  }

  Future<void> _checkLegacyMigration() async {
    final catalog = _fetchedCatalog;
    if (catalog == null ||
        _prefs.getBool(
              SharedPreferenceConstants.backgroundSoundCacheV2Migrated,
            ) ==
            true) {
      return;
    }
    try {
      final dir = await _getDirectory();
      for (final sound in await legacyDownloads) {
        final file = _legacyFile(dir, sound.title);
        if (file != null && await file.exists()) return;
      }
      if (identical(catalog, _fetchedCatalog)) {
        await _prefs.setBool(
          SharedPreferenceConstants.backgroundSoundCacheV2Migrated,
          true,
        );
      }
    } on Exception catch (error) {
      AppLogger.w('BG_SOUND', 'No se pudo revisar la migración: $error');
    }
  }
}

bool _isAmbient(BackgroundSoundsModel sound) =>
    sound.id != kNoneBackgroundSoundId && sound.id != kSessionBellsId;

Duration? _retryCatalog(int retryCount, Object error) => null;

@Riverpod(retry: _retryCatalog)
Future<List<BackgroundSoundsModel>> backgroundSounds(Ref ref) async {
  final backgroundSoundsRepository = ref.watch(
    backgroundSoundsRepositoryProvider,
  );
  final cache = ref.read(_backgroundSoundCacheProvider);
  ref.keepAlive();

  // Limita la espera sin conexión. La hoja vuelve a intentar al abrirse.
  final sounds = await backgroundSoundsRepository
      .fetchBackgroundSounds()
      .timeout(const Duration(seconds: 10));
  await cache.catalogFetched(sounds);
  return sounds;
}

/// What a background sound picker can show without waiting on the network.
class BackgroundSoundCatalog {
  const BackgroundSoundCatalog({
    required this.sounds,
    required this.downloadedIds,
    required this.offline,
    required this.loading,
  });

  /// Ambient sounds only (None and session bells are listed separately).
  final List<BackgroundSoundsModel> sounds;

  /// Sounds whose file is on this device, so they play offline.
  final Set<String> downloadedIds;

  /// The live list could not be fetched: only [downloadedIds] can play.
  final bool offline;

  /// The live list is still being fetched and nothing is cached yet.
  final bool loading;

  bool isAvailable(BackgroundSoundsModel sound) =>
      !offline || downloadedIds.contains(sound.id);
}

final _downloadedBackgroundSoundIdsProvider =
    FutureProvider.autoDispose<Set<String>>((ref) async {
      final repo = ref.watch(backgroundSoundsRepositoryProvider);
      final sounds = repo.fetchCachedBackgroundSounds().where(_isAmbient);
      final ids = <String>{};
      if (sounds.isEmpty) return ids;
      final cache = ref.watch(_backgroundSoundCacheProvider);
      final saved = await repo.fetchLocallySavedBackgroundSounds() ?? [];
      final selected = repo.getSelectedBgSoundFromSharedPreferences();
      for (final sound in sounds) {
        if (await cache.currentFile(sound) != null ||
            !await cache.fallbackFiles(sound.id, {
              sound.title,
              if (selected?.id == sound.id) selected!.title,
              for (final item in saved)
                if (item.id == sound.id) item.title,
            }).isEmpty) {
          ids.add(sound.id);
        }
      }
      return ids;
    });

/// The live sound list when it loads, otherwise the cached one, with which
/// sounds are playable offline. Lets the pickers render at once instead of a
/// shimmer that never resolves without a connection.
final backgroundSoundCatalogProvider =
    Provider.autoDispose<BackgroundSoundCatalog>((ref) {
      final live = ref.watch(backgroundSoundsProvider);
      final cached = ref
          .read(backgroundSoundsRepositoryProvider)
          .fetchCachedBackgroundSounds();
      final all = live.value ?? cached;
      final ambient = all.where(_isAmbient).toList();
      final offline = live.hasError;
      final downloaded = offline
          ? ref.watch(_downloadedBackgroundSoundIdsProvider).value ??
                const <String>{}
          : const <String>{};
      return BackgroundSoundCatalog(
        sounds: ambient,
        downloadedIds: downloaded,
        offline: offline,
        loading: live.isLoading && ambient.isEmpty,
      );
    });

@riverpod
Future<List<BackgroundSoundsModel>?> fetchLocallySavedBackgroundSounds(
  Ref ref,
) {
  final backgroundSoundsRepository = ref.watch(
    backgroundSoundsRepositoryProvider,
  );
  ref.watch(backgroundSoundsNotifierProvider);
  ref.keepAlive();

  return backgroundSoundsRepository.fetchLocallySavedBackgroundSounds();
}

class BackgroundSoundsState {
  final double volume;
  final BackgroundSoundsModel? selectedBgSound;
  final BackgroundSoundsModel? downloadingBgSound;

  /// Sound that could not be downloaded or played. Drives the retry affordance
  /// on its row — without it a failure is completely silent: the row looks
  /// selected and nothing ever plays.
  final BackgroundSoundsModel? failedBgSound;

  /// Start/middle/end bells. Independent of [selectedBgSound]: bells and an
  /// ambient sound can play together.
  final bool bellsEnabled;

  const BackgroundSoundsState({
    this.volume = 50,
    this.selectedBgSound,
    this.downloadingBgSound,
    this.failedBgSound,
    this.bellsEnabled = false,
  });

  /// Whether anything plays over the session (lights the player's sound
  /// button).
  bool get hasAnySound =>
      bellsEnabled ||
      (selectedBgSound != null &&
          selectedBgSound!.id != kNoneBackgroundSoundId);

  BackgroundSoundsState copyWith({
    bool? bellsEnabled,
    double? volume,
    Object? selectedBgSound = _sentinel,
    Object? downloadingBgSound = _sentinel,
    Object? failedBgSound = _sentinel,
  }) {
    return BackgroundSoundsState(
      bellsEnabled: bellsEnabled ?? this.bellsEnabled,
      volume: volume ?? this.volume,
      selectedBgSound: selectedBgSound == _sentinel
          ? this.selectedBgSound
          : selectedBgSound as BackgroundSoundsModel?,
      downloadingBgSound: downloadingBgSound == _sentinel
          ? this.downloadingBgSound
          : downloadingBgSound as BackgroundSoundsModel?,
      failedBgSound: failedBgSound == _sentinel
          ? this.failedBgSound
          : failedBgSound as BackgroundSoundsModel?,
    );
  }
}

const _sentinel = Object();

const _noneSound = BackgroundSoundsModel(
  id: kNoneBackgroundSoundId,
  title: 'None',
  path: '',
  duration: 0,
);

final backgroundSoundsNotifierProvider =
    NotifierProvider<BackgroundSoundsNotifier, BackgroundSoundsState>(
      () => BackgroundSoundsNotifier(),
    );

class BackgroundSoundsNotifier extends Notifier<BackgroundSoundsState> {
  BackgroundSoundsNotifier({
    AudioPlayer? ambientPlayer,
    IosAudioHandler Function()? audioHandler,
    bool? useAndroidAudio,
  }) : _playerOverride = ambientPlayer,
       _audioHandler = audioHandler ?? (() => iosAudioHandler),
       _useAndroidAudio = useAndroidAudio ?? Platform.isAndroid;

  final AudioPlayer? _playerOverride;
  final IosAudioHandler Function() _audioHandler;
  final bool _useAndroidAudio;
  AudioPlayer get _ambientPlayer => _playerOverride ?? iosBackgroundPlayer;

  StreamSubscription<Duration>? _fadeSubscription;
  Timer? _fadeTimer;
  Completer<void>? _manualFade;
  int _generation = 0;
  Object? _iosSession;
  bool _ducked = false;
  double _endFade = 1;
  bool _timerScope = false;

  void setTimerScope(bool isTimer) {
    _timerScope = isTimer;
    if (_manualFade != null) unawaited(_stopAmbient());
    if (!_useAndroidAudio && (Platform.isIOS || _playerOverride != null)) {
      final previousSession = _iosSession;
      _bindIosSession();
      if (previousSession != _iosSession && iosAmbientActive) {
        unawaited(_stopAmbient());
      }
      // El controlador de iOS entrega el cambio incluso sin una pista cargada.
      _audioHandler().duckAmbient = _setAmbientDucked;
    }
  }

  ({bool enabled, double volume}) prepareTimerBells() {
    final repo = ref.read(backgroundSoundsRepositoryProvider);
    final volume = repo.getBgSoundVolume() ?? state.volume;
    state = state.copyWith(bellsEnabled: true, volume: volume);
    return (enabled: true, volume: scaledVolume(volume));
  }

  @override
  BackgroundSoundsState build() {
    ref.onDispose(() {
      _fadeSubscription?.cancel();
      _cancelManualFade();
    });
    return const BackgroundSoundsState();
  }

  void handleOnChangeVolume(double vol) {
    AppLogger.d('BG_SOUND', 'Changing volume to $vol');
    ref.read(backgroundSoundsRepositoryProvider).handleOnChangeVolume(vol);

    final scaledVol = scaledVolume(vol);
    state = state.copyWith(volume: vol);
    if (!_useAndroidAudio) _audioHandler().sessionBells.setVolume(scaledVol);
    AppLogger.d('BG_SOUND', 'Scaled volume: $scaledVol');

    if (_useAndroidAudio) {
      AppLogger.d('BG_SOUND', 'Setting Android background sound volume');
      _api.setBackgroundSoundVolume(scaledVol);
    } else {
      AppLogger.d('BG_SOUND', 'Setting iOS background sound volume');
      _applyIosVolume();
    }
  }

  void handleOnChangeSound(
    BackgroundSoundsModel? sound, {
    bool preview = true,
  }) => _selectSound(sound, preview: preview, persist: true);

  void _selectSound(
    BackgroundSoundsModel? sound, {
    required bool preview,
    required bool persist,
  }) {
    AppLogger.d('BG_SOUND', 'Changing sound to: ${sound?.title}');
    state = state.copyWith(
      selectedBgSound: sound,
      downloadingBgSound: null,
      failedBgSound: null,
    );

    // Las campanas antes se guardaban como un sonido de fondo.
    if (sound?.id == kSessionBellsId) {
      if (persist) setSessionBells(true, preview: preview);
      _selectSound(_noneSound, preview: preview, persist: persist);
      return;
    }

    String? previousTitle;
    if (persist && sound != null) {
      final repo = ref.read(backgroundSoundsRepositoryProvider);
      final previous = repo.getSelectedBgSoundFromSharedPreferences();
      if (previous?.id == sound.id) previousTitle = previous?.title;
      repo.saveSelectedBgSoundToSharedPreferences(sound);
      unawaited(_updateItemsInSavedBgSoundList(sound));
    }

    final stopped = _stopAmbient();
    if (sound == null || sound.id == kNoneBackgroundSoundId) {
      unawaited(stopped);
    } else {
      unawaited(_downloadAndPlay(sound, stopped, previousTitle: previousTitle));
    }
  }

  /// Vuelve a descargar el sonido cuando falla la reproducción.
  void retryDownload(BackgroundSoundsModel sound) {
    AppLogger.d('BG_SOUND', 'Retrying download for: ${sound.title}');
    state = state.copyWith(
      selectedBgSound: sound,
      downloadingBgSound: null,
      failedBgSound: null,
    );
    unawaited(_downloadAndPlay(sound, _stopAmbient(), forceRedownload: true));
  }

  /// Guarda el ajuste de las campanas guiadas y toca una muestra al activarlas.
  void setSessionBells(bool enabled, {bool preview = true}) {
    if (_timerScope) {
      state = state.copyWith(bellsEnabled: true);
      return;
    }
    ref
        .read(backgroundSoundsRepositoryProvider)
        .saveSessionBellsEnabled(enabled);
    state = state.copyWith(bellsEnabled: enabled);
    unawaited(_applySessionBells(enabled, preview: preview));
  }

  Future<void> _applySessionBells(bool enabled, {required bool preview}) async {
    final player = ref.read(playerProvider.notifier);
    final session = player.playbackIdentity;
    final account = PlaybackAccount.generation;
    try {
      final volume = scaledVolume(state.volume);
      if (_useAndroidAudio) {
        await _api.setSessionBells(enabled);
      } else if (enabled) {
        await _audioHandler().sessionBells.enable(volume);
      } else {
        await _audioHandler().sessionBells.disable();
      }
      if (PlaybackAccount.isCurrent(account) &&
          session == player.playbackIdentity &&
          !_timerScope &&
          enabled &&
          preview &&
          state.bellsEnabled) {
        await ref
            .read(sessionBellPreviewProvider)
            .play(volume, assetKey: BellSound.resolve(null).assetKey);
      }
    } catch (error, stack) {
      AppLogger.e(
        'BELLS',
        'No se pudo cambiar el ajuste de campanas',
        error,
        stack,
      );
    }
  }

  Future<void> _downloadAndPlay(
    BackgroundSoundsModel stored,
    Future<void> stopped, {
    bool forceRedownload = false,
    String? previousTitle,
  }) async {
    final generation = _generation;
    final player = ref.read(playerProvider.notifier);
    final session = player.playbackIdentity;
    final account = PlaybackAccount.generation;
    bool isCurrent() =>
        ref.mounted &&
        generation == _generation &&
        session == player.playbackIdentity &&
        PlaybackAccount.isCurrent(account);

    final cache = ref.read(_backgroundSoundCacheProvider);
    final downloader = ref.read(downloaderRepositoryProvider);
    var sound = stored;
    try {
      await stopped;
      if (!isCurrent()) return;

      final repo = ref.read(backgroundSoundsRepositoryProvider);
      var catalog = repo.fetchCachedBackgroundSounds();
      final saved = await repo.fetchLocallySavedBackgroundSounds() ?? [];
      if (!isCurrent()) return;
      final titles = {
        stored.title,
        ?previousTitle,
        for (final item in [...catalog, ...saved])
          if (item.id == stored.id) item.title,
      };
      var offline = false;
      try {
        catalog = await ref.read(backgroundSoundsProvider.future);
      } catch (_) {
        offline = true;
        if (isCurrent()) {
          catalog = ref
              .read(backgroundSoundsRepositoryProvider)
              .fetchCachedBackgroundSounds();
        }
      }
      if (!isCurrent()) return;
      final catalogSound = catalog
          .where((item) => item.id == stored.id)
          .firstOrNull;
      sound = catalogSound ?? stored;
      titles.add(sound.title);
      state = state.copyWith(selectedBgSound: sound);

      Future<bool> playFallback({String? excluding}) async {
        await for (final path in cache.fallbackFiles(
          sound.id,
          titles,
          excluding: excluding,
        )) {
          if (!isCurrent()) return false;
          if (await _play(path, isCurrent)) {
            if (isCurrent()) {
              unawaited(_updateItemsInSavedBgSoundList(stored));
            }
            return true;
          }
        }
        return false;
      }

      Future<void> keepCurrentFile() async {
        if (!isCurrent()) return;
        unawaited(_updateItemsInSavedBgSoundList(sound));
        try {
          await cache.remember(sound, isCurrent: isCurrent);
        } on Exception catch (error) {
          AppLogger.w(
            'BG_SOUND',
            'No se pudo guardar el archivo actual: $error',
          );
        }
        if (isCurrent()) ref.invalidate(_downloadedBackgroundSoundIdsProvider);
      }

      final current = await cache.currentFile(sound);
      if (!isCurrent()) return;
      final preferFallback = offline || catalogSound == null;
      if (preferFallback && await playFallback()) return;
      if (!isCurrent()) return;
      if (!forceRedownload &&
          current != null &&
          await _play(current, isCurrent)) {
        await keepCurrentFile();
        return;
      }
      if (!isCurrent()) return;

      try {
        if (sound.path.isNotEmpty) {
          state = state.copyWith(downloadingBgSound: sound);
          final downloaded = await cache.download(
            sound,
            downloader,
            replace: current != null,
          );
          if (!isCurrent()) return;
          if (downloaded != null && await _play(downloaded, isCurrent)) {
            await keepCurrentFile();
            return;
          }
        }
      } catch (error, stack) {
        AppLogger.e(
          'BG_SOUND',
          'No se pudo descargar ${sound.id}',
          error,
          stack,
        );
      }

      if (isCurrent() &&
          !preferFallback &&
          await playFallback(excluding: forceRedownload ? null : current)) {
        return;
      }
      if (isCurrent()) state = state.copyWith(failedBgSound: sound);
    } catch (error, stack) {
      AppLogger.e('BG_SOUND', 'No se pudo preparar ${sound.id}', error, stack);
      if (isCurrent()) state = state.copyWith(failedBgSound: sound);
    } finally {
      if (isCurrent()) state = state.copyWith(downloadingBgSound: null);
    }
  }

  Future<bool> _play(String path, bool Function() isCurrent) async {
    getVolumeFromPref();
    try {
      if (_useAndroidAudio) {
        await _api.setBackgroundSound(Uri.file(path).toString());
        if (!isCurrent()) return false;
        final prepared = await _api.playBackgroundSound();
        if (!prepared || !isCurrent()) return false;
        await _api.setBackgroundSoundVolume(scaledVolume(state.volume));
      } else {
        _bindIosSession();
        await _ambientPlayer.setFilePath(path);
        if (!isCurrent()) return false;
        iosAmbientActive = true;
        await _applyIosVolume();
        if (!isCurrent()) return false;
        // El controlador reanuda el fondo junto con el reloj si sigue en pausa.
        if (_audioHandler().playing) unawaited(_ambientPlayer.play());
        _handleFadeAtEndForIos();
      }
      return isCurrent();
    } catch (error, stack) {
      AppLogger.e('BG_SOUND', 'No se pudo reproducir $path', error, stack);
      if (isCurrent()) iosAmbientActive = false;
      return false;
    }
  }

  void togglePlayPause(bool isPlaying) {
    if (_useAndroidAudio) {
      if (isPlaying) {
        unawaited(_api.pauseBackgroundSound());
      } else {
        unawaited(_api.playBackgroundSound());
      }
    } else if (iosAmbientActive) {
      if (isPlaying) {
        unawaited(_ambientPlayer.pause());
      } else if (_iosSession ==
              ref.read(playerProvider.notifier).playbackIdentity &&
          _audioHandler().playing) {
        unawaited(_ambientPlayer.play());
      }
    }
  }

  Future<void> stopTimerAmbient({
    required bool transportAlreadyStopped,
    Duration fade = Duration.zero,
  }) {
    if (transportAlreadyStopped ||
        _useAndroidAudio ||
        fade <= Duration.zero ||
        !iosAmbientActive) {
      return _stopAmbient(transportAlreadyStopped: transportAlreadyStopped);
    }

    _endAmbientPlayback();
    final generation = _generation;
    final startVolume = _ambientPlayer.volume;
    final done = _manualFade = Completer<void>();
    const step = Duration(milliseconds: 200);

    void ramp(Duration elapsed) {
      final remaining = fade - elapsed;
      final delay = remaining < step ? remaining : step;
      _fadeTimer = Timer(delay, () async {
        if (generation != _generation) return;
        final next = elapsed + delay;
        final fraction = (fade - next).inMicroseconds / fade.inMicroseconds;
        if (next < fade) ramp(next);
        try {
          await _ambientPlayer.setVolume(startVolume * fraction);
          if (next < fade || generation != _generation) return;
          await _ambientPlayer.stop();
          if (generation != _generation) return;
          final storedVolume = ref
              .read(backgroundSoundsRepositoryProvider)
              .getBgSoundVolume();
          await _ambientPlayer.setVolume(
            scaledVolume(storedVolume ?? state.volume),
          );
        } catch (error, stack) {
          AppLogger.e(
            'BG_SOUND',
            'No se pudo bajar el sonido de fondo',
            error,
            stack,
          );
          if (next == fade && generation == _generation) {
            await _stopIosAmbient();
          }
        } finally {
          if (next == fade && generation == _generation) _cancelManualFade();
        }
      });
    }

    ramp(Duration.zero);
    return done.future;
  }

  void _cancelManualFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _manualFade?.complete();
    _manualFade = null;
  }

  /// Detiene el sonido de fondo y las campanas al cerrar la sesión.
  void stopBackgroundSound() {
    unawaited(_stopAmbient());
    if (_useAndroidAudio) {
      unawaited(_api.setSessionBells(false));
    } else {
      unawaited(_audioHandler().sessionBells.disable());
    }
  }

  void _endAmbientPlayback() {
    _generation++;
    _cancelManualFade();
    unawaited(ref.read(sessionBellPreviewProvider).stop());
    iosAmbientActive = false;
    _fadeSubscription?.cancel();
    _fadeSubscription = null;
    _endFade = 1;
  }

  Future<void> _stopAmbient({bool transportAlreadyStopped = false}) async {
    _endAmbientPlayback();
    if (transportAlreadyStopped) return;
    if (_useAndroidAudio) {
      await _api.setBackgroundSound(null);
      await _api.stopBackgroundSound();
    } else if (Platform.isIOS || _playerOverride != null) {
      await _stopIosAmbient();
    }
  }

  Future<void> _stopIosAmbient() async {
    try {
      await _ambientPlayer.stop();
    } catch (error, stack) {
      AppLogger.e(
        'BG_SOUND',
        'No se pudo detener el sonido de fondo',
        error,
        stack,
      );
    }
  }

  Future<void> _updateItemsInSavedBgSoundList(
    BackgroundSoundsModel sound,
  ) async {
    final provider = ref.read(backgroundSoundsRepositoryProvider);
    final cache = ref.read(_backgroundSoundCacheProvider);
    await cache.legacyDownloads;
    if (ref.mounted) await provider.updateItemsInSavedBgSoundList(sound);
  }

  void restoreTimerBackgroundSound(PlaybackRequest request) {
    if (!_timerScope) setTimerScope(true);
    state = state.copyWith(bellsEnabled: true);
    final repo = ref.read(backgroundSoundsRepositoryProvider);
    final sound = request.resolveBackgroundSound(
      request.overrideBackgroundSound
          ? null
          : repo.getSelectedBgSoundFromSharedPreferences(),
    );
    _selectSound(sound, preview: false, persist: false);
  }

  void playBackgroundSoundFromPref() {
    final repo = ref.read(backgroundSoundsRepositoryProvider);
    final selectedBgSound = repo.getSelectedBgSoundFromSharedPreferences();
    handleOnChangeSound(selectedBgSound, preview: false);
    setSessionBells(
      repo.getSessionBellsEnabled(forTimer: _timerScope),
      preview: false,
    );
  }

  void getVolumeFromPref() {
    var value =
        ref.read(backgroundSoundsRepositoryProvider).getBgSoundVolume() ?? 50.0;
    handleOnChangeVolume(value);
  }

  void _bindIosSession() {
    final session = ref.read(playerProvider.notifier).playbackIdentity;
    if (_iosSession == session) return;
    _iosSession = session;
    _ducked = false;
  }

  void _setAmbientDucked(bool ducked) {
    if (!ref.mounted ||
        _iosSession != ref.read(playerProvider.notifier).playbackIdentity) {
      return;
    }
    _ducked = ducked;
    if (iosAmbientActive) unawaited(_applyIosVolume());
  }

  Future<void> _applyIosVolume() async {
    if (_manualFade != null) return;
    await _ambientPlayer.setVolume(
      scaledVolume(state.volume) * _endFade * (_ducked ? 0.2 : 1),
    );
  }

  void _handleFadeAtEndForIos() {
    _fadeSubscription?.cancel();
    const fadeMs = 10000;
    _fadeSubscription = _audioHandler().positionStream.listen((position) {
      if (_iosSession != ref.read(playerProvider.notifier).playbackIdentity) {
        return;
      }
      final duration = _audioHandler().duration?.inMilliseconds ?? 0;
      _endFade = duration == 0
          ? 1
          : ((duration - position.inMilliseconds) / fadeMs).clamp(0.0, 1.0);
      unawaited(_applyIosVolume());
    });
  }

  double scaledVolume(double vol) {
    var scale = Platform.isIOS ? 0.3 : 0.5;
    return (vol / 100) * scale;
  }
}
