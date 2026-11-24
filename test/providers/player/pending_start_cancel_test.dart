import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/player/download/audio_downloader_provider.dart';
import 'package:medito/providers/player/ios_audio_handler.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/services/audio/ios_session_bells.dart';
import 'package:medito/services/timer/ios_timer_run_store.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AudioHandler extends Mock implements IosAudioHandler {}

class _Bells extends Mock implements IosSessionBells {}

class _Track extends Fake implements Track {}

class _Downloads extends AudioDownloaderProvider {
  @override
  Future<String?> getTrackPath(String fileName) async => null;
}

/// Preferencias reales cuyas escrituras se pueden detener a mitad de camino.
class _GatedPrefs extends Fake implements SharedPreferences {
  _GatedPrefs(this.real);

  final SharedPreferences real;
  Completer<bool>? gate;
  bool fail = false;
  final waiting = <Completer<void>>[];

  Future<void> get reachedGate {
    final reached = Completer<void>();
    waiting.add(reached);
    return reached.future;
  }

  Future<bool> _pass() async {
    final current = gate;
    if (current == null) return !fail;
    for (final reached in waiting) {
      reached.complete();
    }
    waiting.clear();
    return current.future;
  }

  @override
  Object? get(String key) => real.get(key);
  @override
  String? getString(String key) => real.getString(key);
  @override
  Future<bool> setString(String key, String value) async =>
      await _pass() && await real.setString(key, value);
  @override
  Future<bool> remove(String key) async =>
      await _pass() && await real.remove(key);
}

const _guided = PlaybackRequest(
  trackId: 'guiada',
  fileId: 'archivo-guiado',
  title: 'Guiada',
  description: '',
  coverUrl: '',
  remoteUrl: 'file:///tmp/guiada.mp3',
  duration: 600000,
  hasBackgroundSound: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _GatedPrefs gated;
  late IosTimerRunStore store;
  late List<Map<String, dynamic>> recorded;
  late ProviderContainer container;
  late _AudioHandler handler;
  late PlaybackRequest timer;
  late PlayerProvider player;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    gated = _GatedPrefs(prefs);
    recorded = [];
    final originalStore = IosTimerRunStore.instance;
    store = IosTimerRunStore(
      prefs: () async => gated,
      record: (payload) async {
        recorded.add(payload);
        return TimerRecordResult.accepted;
      },
    );
    IosTimerRunStore.instance = store;
    addTearDown(() => IosTimerRunStore.instance = originalStore);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        audioStateProvider.overrideWith(AudioStateNotifier.new),
        audioDownloaderProvider.overrideWith(_Downloads.new),
        playerProvider.overrideWith(
          () => PlayerProvider(useAndroidAudio: false),
        ),
      ],
    );
    addTearDown(container.dispose);
    final originalSink = AudioSessionTracker.logSink;
    AudioSessionTracker.logSink = (_, _) async {};
    addTearDown(() {
      AudioSessionTracker.logSink = originalSink;
      AudioSessionTracker.instance.resetForTesting();
    });
    timer = timerPlaybackRequest(
      mode: TimerMode.countdown,
      duration: const Duration(minutes: 20),
      filePath: '/tmp/timer.wav',
      title: 'Temporizador',
    );
    registerFallbackValue(_Track());
    registerFallbackValue(timer);
    registerFallbackValue(RepeatMode.none);
    handler = _AudioHandler();
    iosAudioHandler = handler;
    final bells = _Bells();
    when(() => handler.sessionBells).thenReturn(bells);
    when(bells.stopBellsAndReportEnd).thenReturn(false);
    when(() => handler.setCustomRepeatMode(any())).thenAnswer((_) async {});
    when(() => handler.setSpeed(1)).thenAnswer((_) async {});
    when(handler.cancelPendingTimerStart).thenAnswer((_) {});
    when(
      () =>
          handler.configureSession(mixWithOthers: any(named: 'mixWithOthers')),
    ).thenAnswer((_) async {});
    when(
      () => handler.setUrl(
        any(),
        any(),
        any(),
        timerBells: any(named: 'timerBells'),
      ),
    ).thenAnswer((_) async {});
    when(handler.play).thenAnswer((_) async {});
    when(
      () => handler.stopRun(any(), full: any(named: 'full')),
    ).thenAnswer((_) async {});
    when(
      () => handler.stopPlayback(full: any(named: 'full')),
    ).thenAnswer((_) async {});
    when(handler.deactivateSession).thenAnswer((_) async {});
    when(() => handler.timerCompleting).thenReturn(false);

    player = container.read(playerProvider.notifier);
    expect(player.reserveStart(timer.timerRunId), isTrue);
    player.prepare(timer);
    await player.play(timer);
    expect(store.liveRunId, timer.timerRunId);

    // Ocho minutos después se abre una guiada en su lugar.
    when(() => handler.timerRunId).thenReturn(timer.timerRunId);
    when(() => handler.position).thenReturn(const Duration(minutes: 8));
  });

  void expectGuidedNeverLoaded() {
    verifyNever(
      () => handler.setUrl(
        any(),
        _guided,
        any(),
        timerBells: any(named: 'timerBells'),
      ),
    );
    verify(handler.play).called(1);
  }

  test('cerrar la guiada mientras se guarda el temporizador cancela solo ese '
      'inicio: el temporizador sigue sonando intacto (REV-01)', () async {
    gated.gate = Completer<bool>();
    final reached = gated.reachedGate;
    player.prepare(_guided);
    final starting = player.play(_guided);
    await reached;

    // La pantalla de la guiada se cierra durante la espera.
    player.stop();

    // El temporizador sigue siendo la sesión viva y su pantalla la dueña;
    // nada lo detuvo ni lo descartó.
    expect(player.activeTimerRequest, timer);
    expect(container.read(playerProvider), timer);
    expect(player.hasActiveSession, isTrue);
    verifyNever(() => handler.stopRun(any(), full: any(named: 'full')));
    verifyNever(() => handler.stopPlayback(full: any(named: 'full')));

    // El guardado falla (también su reintento): el temporizador nunca dejó
    // de sonar.
    gated.fail = true;
    gated.gate!.complete(false);
    gated.gate = null;
    await starting;
    await pumpEventQueue();

    expectGuidedNeverLoaded();
    expect(player.activeTimerRequest, timer);
    expect(container.read(playerProvider), timer);
    expect(store.liveRunId, timer.timerRunId);
    expect(store.active?['runId'], timer.timerRunId);
    expect(recorded, isEmpty);
    verifyNever(() => handler.stopRun(any(), full: any(named: 'full')));
    gated.fail = false;
  });

  test(
    'si el guardado ya cerró el temporizador, se cierra como «Terminar» y la '
    'guiada no empieza (REV-01)',
    () async {
      final closes = <TimerRunCloseResult>[];
      final sub = player.timerCloses.listen(closes.add);
      addTearDown(sub.cancel);
      gated.gate = Completer<bool>();
      final reached = gated.reachedGate;
      player.prepare(_guided);
      final starting = player.play(_guided);
      await reached;

      player.stop();
      expect(container.read(playerProvider), timer);

      gated.gate!.complete(true);
      gated.gate = null;
      await starting;
      await pumpEventQueue();

      expectGuidedNeverLoaded();
      // Guardado una vez con su tiempo, nunca descartado.
      expect(recorded.single[TypeConstants.runIdKey], timer.timerRunId);
      expect(recorded.single[TypeConstants.durationIdKey], 8 * 60000);
      verify(() => handler.stopRun(timer.timerRunId, full: false)).called(1);
      expect(closes.single.runId, timer.timerRunId);
      expect(closes.single.saved, isTrue);
      expect(player.hasActiveSession, isFalse);
    },
  );

  test(
    'si la cuenta cambia durante la espera, la guiada no empieza (REV-01)',
    () async {
      PlaybackAccount.resetForTesting();
      gated.gate = Completer<bool>();
      final reached = gated.reachedGate;
      player.prepare(_guided);
      final starting = player.play(_guided);
      await reached;

      final clearing = PlaybackAccount.clear();
      await clearing.timeout(const Duration(seconds: 5));

      gated.gate!.complete(true);
      gated.gate = null;
      await starting;
      await pumpEventQueue();

      expectGuidedNeverLoaded();
    },
  );
}
