import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/constants.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/models.dart';
import 'package:medito/models/timer/last_timer_store.dart';
import 'package:medito/models/timer/timer_launch.dart';
import 'package:medito/models/timer/timer_preset.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/providers/providers.dart';
import 'package:medito/providers/timer/timer_presets_provider.dart';
import 'package:medito/providers/timer/timer_settings_provider.dart';
import 'package:medito/repositories/background_sounds/background_sounds_repository.dart';
import 'package:medito/services/analytics/firebase_analytics_service.dart';
import 'package:medito/services/audio/timer_audio_file.dart';
import 'package:medito/repositories/track/track_repository.dart';
import 'package:medito/widgets/network_image_widget.dart';
import 'package:medito/widgets/adaptive/adaptive_page_body.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/views/home/widgets/home_gradient_border.dart';
import 'package:medito/views/player/player_view.dart';
import 'package:medito/widgets/inputs/medito_segmented_tabs.dart';
import 'package:medito/views/player/widgets/bottom_actions/single_back_action_bar.dart';

import 'widgets/timer_bell_controls.dart';
import 'widgets/timer_duration_wheels.dart';
import 'widgets/timer_prep_selector.dart';
import 'widgets/timer_preset_chips.dart';
import 'widgets/timer_preset_manager_sheet.dart';
import 'widgets/timer_preset_name_dialog.dart';
import 'widgets/timer_stages_editor.dart';
import 'widgets/timer_volume_check.dart';

/// The home Timer: pick a length (or an open-ended stopwatch) and a sound,
/// then sit with the regular player. Works fully offline — the session is a
/// locally generated silent track, so nothing is fetched.
class TimerView extends ConsumerStatefulWidget {
  const TimerView({super.key, required this.source, this.launch});

  /// Where the screen was opened from, for timer_opened (see
  /// [AnalyticsEventConstants.timerOpened]).
  final String source;

  /// Arranque desde enlace, widget, atajo o «Repetir»: carga los ajustes y
  /// empieza en cuanto se abre la pantalla.
  final TimerLaunch? launch;

  /// Prepara el archivo silencioso de la sesión; las pruebas lo reemplazan.
  @visibleForTesting
  static Future<String> Function(Duration duration) prepareTimerFile =
      TimerAudioFile.prepare;

  /// Pantalla que se abre al empezar; las pruebas la reemplazan.
  @visibleForTesting
  static WidgetBuilder playerPageBuilder = (_) => const PlayerView();

  @override
  ConsumerState<TimerView> createState() => _TimerViewState();
}

/// Sonido de fondo que eligió un temporizador cargado o un enlace para el
/// próximo inicio; `sound` null = sin sonido de fondo.
typedef _AmbientChoice = ({BackgroundSoundsModel? sound});

/// Ajustes y sonido de fondo que trae un arranque desde fuera.
typedef _ResolvedLaunch = ({
  TimerSettings settings,
  _AmbientChoice? ambient,
  String lengthSource,
});

class _TimerViewState extends ConsumerState<TimerView> {
  final _wheels = GlobalKey<TimerDurationWheelsState>();
  bool _starting = false;
  bool _launchHandled = false;

  /// Null = el sonido de fondo elegido en el reproductor.
  _AmbientChoice? _ambient;

  /// How the countdown length was set, for timer_started: remembered or
  /// default until the user touches a chip (preset) or the wheels (wheel).
  late String _lengthSource;

  /// Cover of the old timer track, shown in the player when it could be
  /// fetched. Never awaited: offline the player falls back to its dark
  /// backdrop and the timer starts just the same.
  String? _coverUrl;

  BackgroundSoundsRepository get _soundRepo =>
      ref.read(backgroundSoundsRepositoryProvider);

  @override
  void initState() {
    super.initState();
    // Last known cover first: its image is in the disk cache, so the
    // backdrop shows offline too. The fetch below refreshes it.
    _coverUrl = ref
        .read(sharedPreferencesProvider)
        .getString(SharedPreferenceConstants.timerCoverUrl);
    unawaited(_loadCover());
    _lengthSource =
        ref
                .read(sharedPreferencesProvider)
                .getInt(SharedPreferenceConstants.timerMinutes) ==
            null
        ? 'default'
        : 'remembered';
    final analytics = FirebaseAnalyticsService();
    unawaited(
      analytics.logEvent(
        name: AnalyticsEventConstants.timerOpened,
        parameters: {AnalyticsEventConstants.paramSource: widget.source},
      ),
    );
    unawaited(analytics.logScreenView(screenName: 'TimerView'));
    final launch = widget.launch;
    if (launch != null && !launch.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_handleLaunch(launch));
      });
    }
  }

  Future<void> _loadCover() async {
    try {
      final track = await ref
          .read(trackRepositoryProvider)
          .fetchTrack(kLegacyTimerTrackId);
      final url = track.coverUrl;
      if (!mounted || url.isEmpty || HTTPConstants.isDeadDomain(url)) return;
      unawaited(
        ref
            .read(sharedPreferencesProvider)
            .setString(SharedPreferenceConstants.timerCoverUrl, url),
      );
      if (url != _coverUrl) setState(() => _coverUrl = url);
      // Warm the image so the player opens with it instead of fading it in.
      unawaited(precacheImage(NetworkImage(url), context, onError: (_, _) {}));
    } catch (e) {
      AppLogger.d('TIMER', 'Timer cover unavailable: $e');
    }
  }

  /// Sonido de fondo global (el del reproductor); «ninguno» cuenta como null.
  BackgroundSoundsModel? _globalAmbient() {
    final sound = _soundRepo.getSelectedBgSoundFromSharedPreferences();
    return sound?.id == kNoneBackgroundSoundId ? null : sound;
  }

  /// Sonido de fondo con el que empezaría la próxima sesión.
  BackgroundSoundsModel? _currentAmbient() {
    final ambient = _ambient;
    return ambient == null ? _globalAmbient() : ambient.sound;
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Empieza con los ajustes en pantalla, o con los de un arranque desde
  /// fuera ([launch]) sin guardarlos: los ajustes guardados no cambian y el
  /// «último temporizador» se guarda solo cuando el reloj avanza (§4.10).
  /// Reserva el reproductor antes de cualquier espera: dos inicios seguidos
  /// (dos enlaces, un enlace y un toque) nunca abren dos sesiones, y una
  /// sesión en curso sigue intacta.
  Future<void> _start({_ResolvedLaunch? launch}) async {
    if (_starting) return;
    final TimerSettings settings =
        launch?.settings ?? ref.read(timerSettingsProvider);
    if (!settings.canStart) return;
    final l10n = AppLocalizations.of(context)!;
    final player = ref.read(playerProvider.notifier);
    final runId = newTimerRunId();
    if (!player.reserveStart(runId)) {
      _showSnack(l10n.timerLaunchBusy);
      return;
    }
    // Desde aquí la sesión es de esta cuenta, aunque cambie después (R50).
    final ownerId = player.statsOwnerId;
    setState(() => _starting = true);
    unawaited(HapticFeedback.mediumImpact());

    var handedOff = false;
    try {
      final volumeOk = await confirmTimerVolume(
        context,
        output: settings.bells.output,
        stillValid: () => player.isReserved(runId),
      );
      // Si una meditación guiada tomó el reproductor, se detiene sin avisar.
      if (!player.isReserved(runId) || !mounted || !volumeOk) return;
      final path = await TimerView.prepareTimerFile(settings.fileDuration);
      if (!player.isReserved(runId) || !mounted) return;

      final ambient = launch?.ambient ?? _ambient;
      final lengthSource = launch?.lengthSource ?? _lengthSource;
      final request = timerPlaybackRequest(
        mode: settings.mode,
        duration: settings.sessionDuration,
        filePath: path,
        title: settings.mode == TimerMode.stopwatch
            ? l10n.timerModeStopwatch
            : l10n.timerTitle,
        coverUrl: _coverUrl,
        bells: settings.bells,
        extraTime: settings.hasExtraTime,
        runId: runId,
        ownerId: ownerId,
        stopLabel: l10n.timerEndSession,
        overrideBackgroundSound: ambient != null,
        backgroundSound: ambient?.sound,
        prepMs: settings.prepSeconds * 1000,
        stages: settings.isMultiStage ? settings.stages : const [],
        spokenText: (minutes) => l10n.timerSpokenTimeLeft(minutes),
      );
      final startedAmbient = request.resolveBackgroundSound(_globalAmbient());
      unawaited(
        FirebaseAnalyticsService().logEvent(
          name: AnalyticsEventConstants.timerStarted,
          parameters: {
            AnalyticsEventConstants.paramTimerMode: settings.mode.name,
            AnalyticsEventConstants.paramDurationMinutes:
                settings.mode == TimerMode.stopwatch
                ? 0
                : settings.plannedDuration.inMinutes,
            if (settings.mode == TimerMode.countdown)
              AnalyticsEventConstants.paramLengthSource: lengthSource,
            // Ambient sound and bells, as last left in the player.
            AnalyticsEventConstants.paramSoundId:
                startedAmbient?.id ?? kNoneBackgroundSoundId,
            AnalyticsEventConstants.paramSessionBells:
                _soundRepo.getSessionBellsEnabled(forTimer: true) ? 1 : 0,
          },
        ),
      );
      // Solo se prepara: PlayerProvider lo guarda como «último temporizador»
      // cuando esta sesión de verdad empieza a sonar.
      LastTimerStore.stage(
        runId,
        LastTimerSnapshot(
          settings: settings.toSnapshotJson(),
          backgroundSoundId: startedAmbient?.id,
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      player.prepare(request);
      handedOff = true;
      unawaited(
        Navigator.push(
          context,
          MaterialPageRoute(builder: TimerView.playerPageBuilder),
        ),
      );
    } catch (e, st) {
      AppLogger.e('TIMER', 'Failed to start timer', e, st);
      if (player.isReserved(runId)) _showSnack(l10n.timerStartError);
    } finally {
      // Toda salida antes de abrir el reproductor suelta la reserva.
      if (!handedOff) player.releaseStart(runId);
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Arranque desde fuera: una sesión en curso nunca se reemplaza; si el
  /// arranque no se puede resolver la pantalla queda como está, sin error.
  /// Sin ninguna espera antes de reservar: los ajustes del arranque van
  /// directo al inicio y nunca se guardan como ajustes de la pantalla, así
  /// que cancelar el aviso de volumen o perder la carrera contra otro
  /// arranque no deja nada escrito.
  Future<void> _handleLaunch(TimerLaunch launch) async {
    if (_launchHandled) return;
    _launchHandled = true;
    final resolved = _resolveLaunch(launch);
    if (resolved == null) {
      if (ref.read(playerProvider.notifier).hasActiveSession) {
        _showSnack(AppLocalizations.of(context)!.timerLaunchBusy);
      }
      return;
    }
    await _start(launch: resolved);
  }

  _ResolvedLaunch? _resolveLaunch(TimerLaunch launch) {
    final name = launch.presetName;
    if (name != null) {
      for (final preset in ref.read(timerPresetsProvider)) {
        if (preset.name == name) {
          return (
            settings: preset.settings,
            ambient: (sound: preset.sound),
            lengthSource: 'preset',
          );
        }
      }
    }
    if (launch.last) {
      final snapshot = LastTimerStore.read(ref.read(sharedPreferencesProvider));
      final settings = snapshot == null
          ? null
          : TimerSettings.fromSnapshotJson(snapshot.settings);
      if (snapshot != null && settings != null) {
        return (
          settings: settings,
          ambient: _ambientFromId(snapshot.backgroundSoundId),
          lengthSource: 'launch',
        );
      }
    }
    final minutes = launch.minutes;
    if (minutes != null) {
      return (
        settings: ref
            .read(timerSettingsProvider)
            .copyWith(
              mode: TimerMode.countdown,
              minutes: minutes,
              stages: const [],
              extraTime: false,
            ),
        ambient: null,
        lengthSource: 'launch',
      );
    }
    return null;
  }

  /// Sonido de fondo guardado con «Repetir»: sin id = sin sonido; un id que
  /// ya no está en el catálogo deja el sonido actual (null).
  _AmbientChoice? _ambientFromId(String? id) {
    if (id == null || id == kNoneBackgroundSoundId) return (sound: null);
    final global = _globalAmbient();
    if (global?.id == id) return (sound: global);
    try {
      for (final sound in _soundRepo.fetchCachedBackgroundSounds()) {
        if (sound.id == id) return (sound: sound);
      }
    } catch (e) {
      AppLogger.w('TIMER', 'Catálogo de sonidos no disponible: $e');
    }
    return null;
  }

  /// Tocar un temporizador guardado lo carga en la pantalla; no empieza.
  Future<void> _loadPreset(TimerPreset preset) async {
    unawaited(HapticFeedback.selectionClick());
    final l10n = AppLocalizations.of(context)!;
    final applied = await ref
        .read(timerSettingsProvider.notifier)
        .apply(preset.settings);
    if (!mounted) return;
    if (!applied) {
      showTimerPresetWriteError(context);
      return;
    }
    _ambient = (sound: preset.sound);
    _lengthSource = 'preset';
    if (preset.settings.mode == TimerMode.countdown) {
      unawaited(_wheels.currentState?.animateTo(preset.settings.minutes));
    }
    _showSnack(l10n.timerPresetLoaded(preset.name));
  }

  Future<void> _onPresetAction(
    TimerPreset preset,
    TimerPresetAction action,
  ) async {
    final notifier = ref.read(timerPresetsProvider.notifier);
    final index = ref
        .read(timerPresetsProvider)
        .indexWhere((item) => item.id == preset.id);
    if (index < 0) return;
    switch (action) {
      case TimerPresetAction.rename:
        await renameTimerPreset(context, ref, preset);
      case TimerPresetAction.update:
        final settings = ref.read(timerSettingsProvider);
        if (!settings.canStart) return;
        final sound = _currentAmbient();
        final updated = await notifier.update(
          preset.id,
          preset.copyWith(
            settings: settings,
            sound: sound,
            clearSound: sound == null,
          ),
        );
        if (!mounted) return;
        if (updated) {
          _showSnack(AppLocalizations.of(context)!.timerPresetUpdated);
        } else {
          showTimerPresetWriteError(context);
        }
      case TimerPresetAction.moveUp:
      case TimerPresetAction.moveDown:
        final to = action == TimerPresetAction.moveUp ? index - 1 : index + 1;
        final moved = await notifier.move(preset.id, to);
        if (!moved && mounted) showTimerPresetWriteError(context);
      case TimerPresetAction.delete:
        await deleteTimerPreset(context, ref, preset);
    }
  }

  Future<void> _savePreset(TimerSettings settings) async {
    final l10n = AppLocalizations.of(context)!;
    final sound = _currentAmbient();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => TimerPresetNameDialog(
        initialName: timerPresetAutoName(settings, l10n),
      ),
    );
    if (!mounted || name == null) return;
    final saved = await ref
        .read(timerPresetsProvider.notifier)
        .save(name, settings, sound);
    if (!saved && mounted) showTimerPresetWriteError(context);
  }

  void _selectPreset(int minutes) {
    unawaited(HapticFeedback.selectionClick());
    _lengthSource = 'preset';
    ref.read(timerSettingsProvider.notifier).setMinutes(minutes);
    _wheels.currentState?.animateTo(minutes);
  }

  void _setStages(List<TimerStage> stages) {
    final notifier = ref.read(timerSettingsProvider.notifier);
    // Las partes solo existen en cuenta regresiva.
    if (stages.isNotEmpty) notifier.setMode(TimerMode.countdown);
    unawaited(notifier.setStages(stages));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final settings = ref.watch(timerSettingsProvider);
    final isStopwatch = settings.mode == TimerMode.stopwatch;
    final isMultiStage = settings.isMultiStage;
    final presets = ref.watch(timerPresetsProvider);
    final atPresetLimit = presets.length >= kMaxTimerPresets;
    final settingsNotifier = ref.read(timerSettingsProvider.notifier);
    final showZeroHint = !isStopwatch && !settings.canStart;
    final hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
    );

    final coverUrl = _coverUrl;

    // Laid out like the track screen: cover card, title, then the controls.
    return Scaffold(
      bottomNavigationBar: SingleBackButtonActionBar(
        onBackPressed: () => Navigator.pop(context),
      ),
      body: AdaptivePageBody(
        maxWidth: 600,
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (coverUrl != null) ...[
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: HomeGradientBorder(
                            backgroundColor: Theme.of(context).cardColor,
                            borderRadius: 20,
                            borderWidth: 0.5,
                            child: NetworkImageWidget(
                              url: coverUrl,
                              shouldCache: true,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      MeditoSegmentedTabs(
                        labels: [l10n.timerTitle, l10n.timerModeStopwatch],
                        selectedIndex: settings.mode.index,
                        onChanged: (index) {
                          unawaited(HapticFeedback.selectionClick());
                          ref
                              .read(timerSettingsProvider.notifier)
                              .setMode(TimerMode.values[index]);
                        },
                      ),
                      if (presets.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(l10n.timerSavedPresets),
                        const SizedBox(height: 8),
                        TimerSavedPresetChips(
                          presets: presets,
                          enabled: !_starting,
                          canUpdate: settings.canStart,
                          onLoad: _loadPreset,
                          onAction: _onPresetAction,
                        ),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            onPressed: () =>
                                showTimerPresetManagerSheet(context),
                            child: Text(l10n.timerManagePresets),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (isStopwatch) const _StopwatchInfo(),
                            // Kept mounted while hidden so switching back
                            // keeps the wheels' position. Por partes, cada
                            // parte lleva sus minutos y las ruedas se ocultan.
                            Visibility(
                              visible: !isStopwatch && !isMultiStage,
                              maintainState: true,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  TimerDurationWheels(
                                    key: _wheels,
                                    minutes: settings.minutes,
                                    // Only user drags report here; a
                                    // preset's spin is suppressed.
                                    onChanged: (minutes) {
                                      _lengthSource = 'wheel';
                                      ref
                                          .read(timerSettingsProvider.notifier)
                                          .setMinutes(minutes);
                                    },
                                  ),
                                  const SizedBox(height: 16),
                                  TimerDurationChips(
                                    selectedMinutes: settings.minutes,
                                    onSelected: _selectPreset,
                                  ),
                                ],
                              ),
                            ),
                            if (!isStopwatch)
                              TimerStagesEditor(
                                stages: settings.stages,
                                currentMinutes: settings.minutes,
                                onChanged: _setStages,
                              ),
                          ],
                        ),
                      ),
                      TimerPrepSelector(
                        prepSeconds: settings.prepSeconds,
                        onChanged: (seconds) =>
                            unawaited(settingsNotifier.setPrepSeconds(seconds)),
                      ),
                      TimerBellControls(
                        bells: settings.bells,
                        showRandom: !isStopwatch,
                        onChanged: settingsNotifier.setBells,
                      ),
                      if (!isStopwatch && !isMultiStage) ...[
                        SwitchListTile(
                          title: Text(l10n.timerExtraTime),
                          subtitle: Text(l10n.timerExtraTimeDescription),
                          value: settings.extraTime,
                          onChanged: settingsNotifier.setExtraTime,
                        ),
                        if (settings.extraTime && !settings.bells.end)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Text(
                              l10n.timerExtraTimeBellHint,
                              style: hintStyle,
                            ),
                          ),
                      ],
                      OutlinedButton(
                        onPressed: settings.canStart && !atPresetLimit
                            ? () => _savePreset(settings)
                            : null,
                        child: Text(l10n.timerSavePreset),
                      ),
                      if (atPresetLimit) Text(l10n.timerPresetLimit),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Se anuncia al lector de pantalla al aparecer.
                    Semantics(
                      liveRegion: true,
                      child: showZeroHint
                          ? Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                l10n.timerZeroHint,
                                textAlign: TextAlign.center,
                                style: hintStyle,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    _StartButton(
                      enabled: settings.canStart,
                      loading: _starting,
                      onPressed: () => unawaited(_start()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StopwatchInfo extends StatelessWidget {
  const _StopwatchInfo();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final onSurface = theme.colorScheme.onSurface;
    return HomeGradientBorder(
      backgroundColor: theme.cardColor,
      borderRadius: 16,
      borderWidth: 0.5,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.all_inclusive_rounded, color: onSurface, size: 24),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Same type as the sound rows in the player's sheet.
                  Text(
                    l10n.timerStopwatchTitle,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.timerStopwatchCaption,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 14,
                      color: onSurface.withValues(alpha: 0.7),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StartButton extends StatelessWidget {
  const _StartButton({
    required this.enabled,
    required this.loading,
    required this.onPressed,
  });

  final bool enabled;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // Same as the track screen's Play: the themed primary button at 56pt.
    // Alto mínimo, no fijo: con letra grande el botón crece.
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: double.infinity,
        minHeight: 56,
      ),
      child: ElevatedButton(
        onPressed: enabled && !loading ? onPressed : null,
        child: loading
            ? SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: context.onBrandAccent,
                ),
              )
            : Text(AppLocalizations.of(context)!.timerStart),
      ),
    );
  }
}
