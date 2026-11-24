import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/exceptions/app_error.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/track/track.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/player/ios_audio_handler.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/repositories/background_sounds/background_sounds_repository.dart';
import 'package:medito/repositories/downloader/downloader_repository.dart';
import 'package:medito/services/audio/ios_session_bells.dart';
import 'package:medito/services/network/http_api_service.dart';
import 'package:medito/src/audio_pigeon.g.dart' show MeditoAudioServiceApi;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Http extends Mock implements HttpApiService {}

class _Downloader extends Mock implements DownloaderRepository {}

class _Ambient extends Mock implements AudioPlayer {}

class _Bells extends Mock implements IosSessionBells {}

class _Handler extends Mock implements IosAudioHandler {
  @override
  final sessionBells = _Bells();

  @override
  bool playing = true;

  @override
  Duration? duration = const Duration(minutes: 2);

  @override
  void Function(bool)? duckAmbient;

  final positions = StreamController<Duration>.broadcast(sync: true);

  @override
  Stream<Duration> get positionStream => positions.stream;
}

const _old = BackgroundSoundsModel(
  id: 'rain',
  version: '1',
  title: 'Rain',
  path: 'https://example.com/rain-v1.mp3',
  duration: 60,
);

final _updated = _old.copyWith(
  version: '2',
  title: 'New rain',
  path: 'https://example.com/rain-v2.mp3',
);

const _timer = PlaybackRequest(
  trackId: 'timer-120',
  fileId: 'timer',
  title: 'Temporizador',
  description: '',
  coverUrl: '',
  remoteUrl: '',
  duration: 120,
  hasBackgroundSound: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory cache;
  late SharedPreferences prefs;
  late ProviderContainer container;
  late BackgroundSoundsNotifier notifier;
  late _Downloader downloader;
  late _Ambient ambient;
  late _Handler handler;
  late List<String> loaded;
  late List<String> downloads;
  late List<double> volumes;
  late int playCalls;
  late int stopCalls;
  late bool playing;
  late Future<void> Function() finishStop;

  File file(String name) => File('${cache.path}/$name');
  File cached(BackgroundSoundsModel sound) =>
      file(backgroundSoundFileName(sound));
  Map<String, dynamic> mappedFiles() => jsonDecode(
    prefs.getString(SharedPreferenceConstants.backgroundSoundCacheFiles) ??
        '{}',
  );

  void cacheOldVersion() {
    cached(_old).writeAsStringSync('version 1');
    prefs.setString(
      SharedPreferenceConstants.backgroundSoundCacheFiles,
      jsonEncode({_old.id: backgroundSoundFileName(_old)}),
    );
  }

  Future<void> open({
    List<BackgroundSoundsModel>? catalog,
    List<BackgroundSoundsModel> savedCatalog = const [],
    List<BackgroundSoundsModel> legacyDownloads = const [],
    List<Track> guidedDownloads = const [],
    bool useAndroidAudio = false,
  }) async {
    const oldSwitch = SharedPreferenceConstants.timerSessionBellsEnabled;
    SharedPreferences.setMockInitialValues({
      SharedPreferenceConstants.bgSound: jsonEncode(_old.toJson()),
      SharedPreferenceConstants.bgSoundVolume: 40.0,
      SharedPreferenceConstants.bgSoundCatalog: jsonEncode(
        savedCatalog.map((sound) => sound.toJson()).toList(),
      ),
      SharedPreferenceConstants.listBgSound: [
        for (final sound in legacyDownloads)
          jsonEncode(sound.toJson()..remove('version')),
      ],
      SharedPreferenceConstants.downloads: jsonEncode(guidedDownloads),
      oldSwitch: false,
    });
    prefs = await SharedPreferences.getInstance();
    final http = _Http();
    when(() => http.getRequest(any())).thenAnswer((_) async {
      if (catalog == null) throw const ServerError();
      return {'results': catalog.map((sound) => sound.toJson()).toList()};
    });
    when(
      () => downloader.downloadFile(any(), fileName: any(named: 'fileName')),
    ).thenAnswer((invocation) async {
      final name = invocation.namedArguments[#fileName] as String;
      downloads.add(name);
      await file(name).writeAsString('descarga completa');
    });
    container = ProviderContainer(
      overrides: [
        backgroundSoundCacheDirectoryProvider.overrideWithValue(
          () async => cache,
        ),
        backgroundSoundsRepositoryProvider.overrideWith(
          (ref) => BackgroundSoundsRepositoryImpl(client: http, ref: ref),
        ),
        sharedPreferencesProvider.overrideWithValue(prefs),
        downloaderRepositoryProvider.overrideWithValue(downloader),
        backgroundSoundsNotifierProvider.overrideWith(
          () => BackgroundSoundsNotifier(
            ambientPlayer: ambient,
            audioHandler: () => handler,
            useAndroidAudio: useAndroidAudio,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    notifier = container.read(backgroundSoundsNotifierProvider.notifier);
  }

  void audioHost(
    String method,
    FutureOr<Object?> Function(Object? message) handle,
  ) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.medito.MeditoAudioServiceApi.$method',
      MeditoAudioServiceApi.pigeonChannelCodec,
    );
    messenger.setMockDecodedMessageHandler(channel, (message) async {
      return [await handle(message)];
    });
    addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
  }

  Future<void> settled() {
    final done = Completer<void>();
    final subscription = container.listen(backgroundSoundsNotifierProvider, (
      previous,
      next,
    ) {
      if (next.downloadingBgSound == null &&
          (loaded.isNotEmpty || next.failedBgSound != null)) {
        done.complete();
      }
    });
    return done.future
        .timeout(const Duration(seconds: 5))
        .whenComplete(subscription.close);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('background-sounds-');
    cache = await Directory('${root.path}/cache').create();
    downloader = _Downloader();
    ambient = _Ambient();
    handler = _Handler();
    loaded = [];
    downloads = [];
    volumes = [];
    playCalls = 0;
    stopCalls = 0;
    playing = false;
    finishStop = () async {};
    iosAmbientActive = false;

    when(() => ambient.setFilePath(any())).thenAnswer((call) async {
      loaded.add(call.positionalArguments.single as String);
      return null;
    });
    when(() => ambient.play()).thenAnswer((_) async {
      playing = true;
      playCalls++;
    });
    when(() => ambient.pause()).thenAnswer((_) async => playing = false);
    when(() => ambient.stop()).thenAnswer((_) async {
      playing = false;
      stopCalls++;
      await finishStop();
    });
    when(() => ambient.playing).thenAnswer((_) => playing);
    when(() => ambient.volume).thenAnswer((_) => volumes.last);
    when(() => ambient.setVolume(any())).thenAnswer((call) async {
      volumes.add(call.positionalArguments.single as double);
    });
  });

  tearDown(() async {
    await handler.positions.close();
    await root.delete(recursive: true);
  });

  test('a stored preference resolves to the catalog version by id', () async {
    await open(catalog: [_updated]);
    final done = settled();
    notifier.restoreTimerBackgroundSound(_timer);
    await done;
    expect(downloads, [backgroundSoundFileName(_updated)]);
    expect(loaded, [cached(_updated).path]);
    expect(
      container.read(backgroundSoundsNotifierProvider).selectedBgSound,
      _updated,
    );
    expect(
      container.read(backgroundSoundsNotifierProvider).bellsEnabled,
      isTrue,
    );
    notifier.setSessionBells(false);
    expect(
      container.read(backgroundSoundsNotifierProvider).bellsEnabled,
      isTrue,
    );
  });

  test(
    'a failed new download uses the mapped version after catalog refresh',
    () async {
      await open(catalog: [_updated], savedCatalog: [_old]);
      cacheOldVersion();
      file('Rain.mp3').writeAsStringSync('legado');
      await container.read(backgroundSoundsProvider.future);
      when(
        () => downloader.downloadFile(any(), fileName: any(named: 'fileName')),
      ).thenThrow(StateError('descarga interrumpida'));

      final done = settled();
      notifier.restoreTimerBackgroundSound(
        _timer.copyWith(overrideBackgroundSound: true, backgroundSound: _old),
      );
      await done;
      expect(loaded, [cached(_old).path]);
      expect(mappedFiles(), {_old.id: backgroundSoundFileName(_old)});
      expect(cached(_updated).existsSync(), isFalse);
      expect(file('Rain.mp3').existsSync(), isTrue);
      expect(
        container.read(backgroundSoundsNotifierProvider).failedBgSound,
        isNull,
      );
    },
  );

  test(
    'offline uses the previous file even with a newer catalog on disk',
    () async {
      await open(savedCatalog: [_updated]);
      cacheOldVersion();
      final offlineCatalog = Completer<BackgroundSoundCatalog>();
      final subscription = container.listen(backgroundSoundCatalogProvider, (
        previous,
        next,
      ) {
        if (!offlineCatalog.isCompleted &&
            next.offline &&
            next.downloadedIds.contains(_old.id)) {
          offlineCatalog.complete(next);
        }
      });
      addTearDown(subscription.close);
      final done = settled();
      notifier.restoreTimerBackgroundSound(_timer);
      await done;
      final catalog = await offlineCatalog.future.timeout(
        const Duration(seconds: 5),
      );
      expect(catalog.isAvailable(_updated), isTrue);
      expect(loaded, [cached(_old).path]);
      expect(downloads, isEmpty);
      expect(mappedFiles(), {_old.id: backgroundSoundFileName(_old)});
    },
  );

  test(
    'a cached last-timer id still has metadata outside the catalog',
    () async {
      await open(savedCatalog: [_updated.copyWith(id: 'new entry')]);
      cacheOldVersion();
      await prefs.setStringList(SharedPreferenceConstants.listBgSound, [
        jsonEncode(_old.toJson()),
      ]);
      await prefs.remove(SharedPreferenceConstants.bgSound);
      final repo = container.read(backgroundSoundsRepositoryProvider);
      final byId = repo.fetchCachedBackgroundSounds().singleWhere(
        (sound) => sound.id == _old.id,
      );
      final done = settled();
      notifier.restoreTimerBackgroundSound(
        _timer.copyWith(overrideBackgroundSound: true, backgroundSound: byId),
      );
      await done;
      expect(loaded, [cached(_old).path]);
      expect(downloads, isEmpty);
    },
  );

  test(
    'offline uses the safe legacy file when there is no cache map',
    () async {
      await open();
      final legacy = file('Rain.mp3')..writeAsStringSync('legado');
      final done = settled();
      notifier.restoreTimerBackgroundSound(_timer);
      await done;
      expect(loaded, [legacy.path]);
      expect(downloads, isEmpty);
      expect(legacy.existsSync(), isTrue);
    },
  );

  test('the old files stay until their replacement exists', () async {
    await open(
      catalog: [_updated.copyWith(title: _old.title)],
      legacyDownloads: [_old],
    );
    cacheOldVersion();
    final legacy = file('Rain.mp3')..writeAsStringSync('legado');
    final started = Completer<void>();
    final release = Completer<void>();
    when(
      () => downloader.downloadFile(any(), fileName: any(named: 'fileName')),
    ).thenAnswer((invocation) async {
      started.complete();
      await release.future;
      final name = invocation.namedArguments[#fileName] as String;
      await file(name).writeAsString('descarga completa');
    });

    final done = settled();
    notifier.restoreTimerBackgroundSound(_timer);
    await started.future;
    expect(cached(_old).existsSync(), isTrue);
    expect(legacy.existsSync(), isTrue);
    expect(cached(_updated).existsSync(), isFalse);
    expect(mappedFiles(), {_old.id: backgroundSoundFileName(_old)});
    expect(
      prefs.getBool(SharedPreferenceConstants.backgroundSoundCacheV2Migrated),
      isNot(isTrue),
    );

    release.complete();
    await done;
    expect(cached(_updated).existsSync(), isTrue);
    expect(cached(_old).existsSync(), isFalse);
    expect(legacy.existsSync(), isFalse);
    expect(mappedFiles(), {_old.id: backgroundSoundFileName(_updated)});
    expect(
      prefs.getBool(SharedPreferenceConstants.backgroundSoundCacheV2Migrated),
      isTrue,
    );
  });

  for (final prepared in [true, false]) {
    test(
      prepared
          ? 'Android keeps the old files until the new version is prepared'
          : 'Android falls back when it cannot prepare the new download',
      () async {
        await open(
          catalog: [_updated],
          legacyDownloads: [_old],
          useAndroidAudio: true,
        );
        cacheOldVersion();
        final legacy = file('Rain.mp3')..writeAsStringSync('legado');
        final preparing = Completer<void>();
        final preparation = Completer<bool>();
        String? selectedPath;
        audioHost('setBackgroundSound', (message) {
          final uri = (message as List<Object?>).single as String?;
          selectedPath = uri == null ? null : Uri.parse(uri).toFilePath();
          return null;
        });
        audioHost('stopBackgroundSound', (_) => null);
        audioHost('setBackgroundSoundVolume', (_) => null);
        audioHost('playBackgroundSound', (_) {
          loaded.add(selectedPath!);
          if (selectedPath != cached(_updated).path) return true;
          preparing.complete();
          return preparation.future;
        });

        final done = settled();
        notifier.restoreTimerBackgroundSound(_timer);
        await preparing.future.timeout(const Duration(seconds: 5));
        expect(cached(_updated).existsSync(), isTrue);
        expect(cached(_old).existsSync(), isTrue);
        expect(legacy.existsSync(), isTrue);
        expect(mappedFiles(), {_old.id: backgroundSoundFileName(_old)});

        preparation.complete(prepared);
        await done;
        expect(loaded, [
          cached(_updated).path,
          if (!prepared) cached(_old).path,
        ]);
        expect(cached(_old).existsSync(), !prepared);
        expect(legacy.existsSync(), !prepared);
        expect(mappedFiles(), {
          _old.id: backgroundSoundFileName(prepared ? _updated : _old),
        });
        expect(
          container.read(backgroundSoundsNotifierProvider).failedBgSound,
          isNull,
        );
      },
    );
  }

  test('a new ambient title cannot delete a guided download', () async {
    final renamed = _updated.copyWith(title: 'track-file');
    await open(catalog: [renamed], legacyDownloads: [_old]);
    final legacy = file('Rain.mp3')..writeAsStringSync('legado');
    final guided = file('track-file.mp3')..writeAsStringSync('meditación');
    final done = settled();
    notifier.handleOnChangeSound(renamed);
    await done;
    expect(legacy.existsSync(), isFalse);
    expect(guided.readAsStringSync(), 'meditación');
    expect(
      prefs.getBool(SharedPreferenceConstants.backgroundSoundCacheV2Migrated),
      isTrue,
    );
  });

  test(
    'a guided download stays even if an old ambient title matches',
    () async {
      final oldTitle = _old.copyWith(title: 'track-file');
      await open(
        catalog: [_updated],
        legacyDownloads: [oldTitle],
        guidedDownloads: [
          const Track(
            id: 'track',
            title: 'Meditación',
            description: '',
            coverUrl: '',
            isPublished: true,
            hasBackgroundSound: false,
            voices: [
              TrackVoice(
                audioFiles: [
                  TrackAudioFile(
                    id: 'file',
                    path: 'https://example.com/file.mp3',
                    duration: 60,
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      final guided = file('track-file.mp3')..writeAsStringSync('meditación');
      final done = settled();
      notifier.restoreTimerBackgroundSound(_timer);
      await done;
      expect(loaded, [cached(_updated).path]);
      expect(guided.readAsStringSync(), 'meditación');
    },
  );

  test(
    'unsafe legacy names cannot remove files using a slash or backslash',
    () async {
      final unsafe = [
        _updated.copyWith(title: '../x'),
        _updated.copyWith(id: 'nested', title: 'a/b'),
        _updated.copyWith(id: 'backslash', title: r'c\d'),
      ];
      await open(catalog: unsafe, legacyDownloads: unsafe);
      final outside = File('${root.path}/x.mp3')..writeAsStringSync('afuera');
      final nestedDir = Directory('${cache.path}/a')..createSync();
      final nested = File('${nestedDir.path}/b.mp3')..writeAsStringSync('otro');
      final backslash = file(r'c\d.mp3')..writeAsStringSync('otro archivo');
      await prefs.setString(
        SharedPreferenceConstants.backgroundSoundCacheFiles,
        jsonEncode({_old.id: '../x.mp3'}),
      );

      for (final sound in unsafe) {
        loaded.clear();
        final done = settled();
        notifier.restoreTimerBackgroundSound(
          _timer.copyWith(
            overrideBackgroundSound: true,
            backgroundSound: sound,
          ),
        );
        await done;
        expect(loaded, [cached(sound).path]);
      }
      expect(outside.readAsStringSync(), 'afuera');
      expect(nested.readAsStringSync(), 'otro');
      expect(backslash.readAsStringSync(), 'otro archivo');
    },
  );

  test(
    'a download finishing during a pause waits and preserves ducking',
    () async {
      await open(catalog: [_updated]);
      final started = Completer<void>();
      final release = Completer<void>();
      when(
        () => downloader.downloadFile(any(), fileName: any(named: 'fileName')),
      ).thenAnswer((invocation) async {
        started.complete();
        await release.future;
        await cached(_updated).writeAsString('descarga completa');
      });

      final done = settled();
      notifier.restoreTimerBackgroundSound(_timer);
      await started.future;
      handler.playing = false;
      notifier.togglePlayPause(true);
      handler.duckAmbient!(true);
      release.complete();
      await done;

      expect(playCalls, 0);
      final normal = notifier.scaledVolume(40);
      expect(volumes.last, closeTo(normal * 0.2, 0.0001));
      handler.playing = true;
      notifier.togglePlayPause(false);
      expect(playCalls, 1);
      handler.positions.add(const Duration(seconds: 115));
      expect(volumes.last, closeTo(normal * 0.2 * 0.5, 0.0001));
      handler.duckAmbient!(false);
      expect(volumes.last, closeTo(normal * 0.5, 0.0001));
    },
  );

  test(
    'manual fade reaches zero and waits for stop before restoring volume',
    () async {
      await open(catalog: [_updated]);
      final done = settled();
      notifier.restoreTimerBackgroundSound(_timer);
      await done;

      fakeAsync((clock) {
        final stopping = Completer<void>();
        finishStop = () => stopping.future;
        final initialStops = stopCalls;
        final startVolume = volumes.last;
        var completed = false;
        notifier
            .stopTimerAmbient(
              transportAlreadyStopped: false,
              fade: const Duration(seconds: 3),
            )
            .then((_) => completed = true);
        clock.elapse(const Duration(milliseconds: 199));
        expect(volumes.last, startVolume);
        clock.elapse(const Duration(milliseconds: 1));
        expect(volumes.last, closeTo(startVolume * 14 / 15, 0.0001));
        clock.elapse(const Duration(milliseconds: 2800));
        expect(volumes.last, 0);
        expect(stopCalls, initialStops + 1);
        expect(completed, isFalse);
        stopping.complete();
        clock.flushMicrotasks();
        expect(volumes.last, startVolume);
        expect(completed, isTrue);
      });
    },
  );

  test('starting a new session completes and cancels a running fade', () async {
    await open(catalog: [_updated]);
    final done = settled();
    notifier.restoreTimerBackgroundSound(_timer);
    await done;

    fakeAsync((clock) {
      var completed = false;
      notifier
          .stopTimerAmbient(
            transportAlreadyStopped: false,
            fade: const Duration(seconds: 3),
          )
          .then((_) => completed = true);
      clock.elapse(const Duration(milliseconds: 400));
      notifier.restoreTimerBackgroundSound(
        _timer.copyWith(overrideBackgroundSound: true),
      );
      clock.flushMicrotasks();
      expect(completed, isTrue);
      final afterStart = stopCalls;
      final lastVolume = volumes.last;
      clock.elapse(const Duration(seconds: 3));
      expect(stopCalls, afterStart);
      expect(volumes.last, lastVolume);
    });
  });
}
