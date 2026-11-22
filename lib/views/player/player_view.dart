// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'package:medito/widgets/adaptive/adaptive_player_layout.dart';
import 'package:medito/models/player/playback_request.dart';
import 'dart:ui';
import 'dart:io';

import 'package:medito/constants/constants.dart';
import 'package:medito/exceptions/app_error.dart';
import 'package:medito/models/events/donation/donation_page_model.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/utils/audio_session_tracker.dart';
import 'package:medito/providers/timer/timer_session_closer.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/utils/utils.dart';
import 'package:medito/models/stripe/paywall_config_model.dart';
import 'package:medito/providers/donation/donation_page_provider.dart';
import 'package:medito/providers/donation/end_screen_donation_experiment.dart';
import 'package:medito/providers/stripe/payment_service_provider.dart';
import 'package:medito/providers/providers.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/services/analytics/firebase_analytics_service.dart';
import 'package:medito/views/end_screen/end_screen_view.dart';
import 'package:medito/views/player/session_completion_gate.dart';
import 'package:medito/views/player/widgets/artist_title_widget.dart';
import 'package:medito/views/player/widgets/bottom_actions/player_action_bar.dart';
import 'package:medito/views/player/widgets/duration_indicator_widget.dart';
import 'package:medito/views/player/widgets/stopwatch_elapsed_widget.dart';
import 'package:medito/views/player/widgets/player_buttons/player_buttons_widget.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/background_sounds/background_sounds_notifier.dart';
import '../../widgets/errors/medito_error_widget.dart';
import '../../utils/health_kit_manager.dart';

class PlayerView extends ConsumerStatefulWidget {
  const PlayerView({super.key});

  @override
  ConsumerState<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends ConsumerState<PlayerView> {
  bool _endScreenOpened = false;
  bool _isClosing = false;
  bool _timerStopped = false;
  StreamSubscription<TimerCloseResult>? _timerCloseSubscription;
  // Set when play() throws (e.g. offline, native audio failed to start). The
  // caller no longer awaits play() before navigating — we own starting
  // playback here — so this is how a start failure surfaces to the user.
  bool _startFailed = false;

  /// Whether playback has actually started on this screen. Until it has, the
  /// play button shows a spinner regardless of the shared audio state, which
  /// can still hold the previous session's values or briefly read "loaded but
  /// not playing" between load and play — both made the button flicker
  /// play → spinner → pause on open.
  bool _playbackStarted = false;
  Timer? _playbackStartFallback;

  /// Keeps a previous session's completed state from opening the end screen.
  final _completionGate = SessionCompletionGate();
  final _analytics = FirebaseAnalyticsService();
  // Guarda el historial previo para detectar una pausa al terminar.
  LocalAllStats? _statsAtSessionStart;

  // Holds the end-screen donation ask alive while the player is open so the
  // fetch happens NOW, while the network is known to be up. When a session
  // ends with the screen off, the end screen is pushed on the next resume and
  // Android often hasn't restored connectivity yet — ~3.7% of those asks failed
  // to load (Sep 2026, GA4). A successful prefetch is kept alive by the
  // provider itself; a failed one is dropped when this subscription closes so
  // the end screen retries fresh.
  ProviderSubscription<AsyncValue<DonationPageModel>>? _donationAskWarmup;
  // Same idea for the localized end_screen ladder, only for installs already
  // in the inline-pay arm (peek, never assign here — the card assigns).
  ProviderSubscription<AsyncValue<PaywallConfigModel>>? _endScreenConfigWarmup;

  @override
  void initState() {
    super.initState();
    _statsAtSessionStart = ref.read(statsProvider).value;
    // Bells are remembered per scope (on by default for a timer, off under
    // tracks); set before _initializePlayer restores them.
    ref
        .read(backgroundSoundsNotifierProvider.notifier)
        .setTimerScope(ref.read(playerProvider)?.isTimer ?? false);
    if (ref.read(playerProvider)?.isTimer ?? false) {
      _timerCloseSubscription = ref
          .read(playerProvider.notifier)
          .timerCloses
          .listen(_onTimerClosed);
    }
    _logScreenView();
    // A listener rather than build(): build only sees the latest value, and a
    // not-completed reading between two completed ones must still arm the gate.
    ref.listenManual(
      audioStateProvider.select((s) => s.isCompleted),
      (_, isCompleted) => _completionGate.completionChanged(isCompleted),
    );
    if (donationsEnabled) {
      _donationAskWarmup = ref.listenManual(
        fetchDonationPageProvider,
        (_, _) {},
      );
      try {
        if (EndScreenDonationExperiment.isInlineVariant(
          ref.read(sharedPreferencesProvider),
        )) {
          _endScreenConfigWarmup = ref.listenManual(
            endScreenPaywallConfigProvider,
            (_, _) {},
          );
          // Also applies Stripe's publishable key, which the inline pay button
          // needs before it can open a sheet (keepAlive provider: no handle).
          unawaited(
            ref
                .read(paymentConfigProvider.future)
                .then(
                  (_) {},
                  onError: (Object e) => AppLogger.w(
                    'PLAYER',
                    'Payment config warm-up failed: $e',
                  ),
                ),
          );
        }
      } catch (e) {
        AppLogger.w('PLAYER', 'End-screen config warm-up skipped: $e');
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startPlayback();
    });
  }

  /// Starts playback for the request the caller prepared. Runs here (rather
  /// than at the call site, awaited before navigation) so the screen opens
  /// instantly and shows a loading state while the audio spins up. A failure
  /// flips [_startFailed] so build() can show a retryable error instead of a
  /// silent, stuck player.
  Future<void> _startPlayback() async {
    if (!mounted || _isClosing || _timerStopped) return;
    final request = ref.read(playerProvider);
    if (request == null) return;
    _completionGate.reset();
    try {
      await ref.read(playerProvider.notifier).play(request);
      if (!mounted || _isClosing || _timerStopped) return;
      _completionGate.trackLoaded(
        isCompleted: ref.read(audioStateProvider).isCompleted,
      );
      // If audio never reports playing (e.g. an interruption right at start),
      // stop waiting and show the play button so the user can start it.
      _playbackStartFallback?.cancel();
      _playbackStartFallback = Timer(const Duration(seconds: 3), () {
        if (mounted && !_playbackStarted) {
          setState(() => _playbackStarted = true);
        }
      });
      // The native service must be ready before restoring background audio.
      if (mounted && !_isClosing && !_timerStopped) {
        unawaited(_initializePlayer());
      }
    } catch (e, st) {
      AppLogger.e('PLAYER', 'Failed to start playback', e, st);
      if (mounted) setState(() => _startFailed = true);
    }
  }

  void _retryPlayback() {
    setState(() {
      _startFailed = false;
      _playbackStarted = false;
    });
    _startPlayback();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheCurrentTrackImage();
  }

  @override
  void dispose() {
    // Analytics: leaving the player (e.g. system back gesture) abandons a
    // paused session. No-op if it's still playing (continues in background) or
    // already completed/stopped.
    unawaited(AudioSessionTracker.instance.onPlayerClosed());
    _playbackStartFallback?.cancel();
    unawaited(_timerCloseSubscription?.cancel());
    _donationAskWarmup?.close();
    _endScreenConfigWarmup?.close();
    super.dispose();
  }

  void _precacheCurrentTrackImage() {
    final currentlyPlayingTrack = ref.read(playerProvider);
    if (currentlyPlayingTrack != null) {
      _precacheImage(currentlyPlayingTrack.coverUrl);
    }
  }

  void _precacheImage(String imageUrl) {
    if (imageUrl.isNotEmpty && Uri.tryParse(imageUrl)?.hasScheme == true) {
      if (!HTTPConstants.isDeadDomain(imageUrl)) {
        try {
          final networkImage = NetworkImage(imageUrl);
          unawaited(
            precacheImage(networkImage, context).catchError((error) {
              AppLogger.d(
                'PlayerView',
                'Failed to precache image: \$imageUrl, error: \$error',
              );
            }),
          );
        } catch (e) {
          AppLogger.d(
            'PlayerView',
            'Failed to create or precache image: \$imageUrl, error: \$e',
          );
        }
      }
    }
  }

  Future<void> _logScreenView() async {
    final currentlyPlayingTrack = ref.read(playerProvider);
    final parameters = currentlyPlayingTrack != null
        ? {'trackid': currentlyPlayingTrack.trackId}
        : null;

    await _analytics.logScreenView(
      screenName: 'PlayerView',
      parameters: parameters,
    );
  }

  Future<void> _initializePlayer() async {
    final request = ref.read(playerProvider);
    final sound = ref.read(backgroundSoundsNotifierProvider.notifier);
    if (request != null && request.isTimer) {
      sound.restoreTimerBackgroundSound(request);
    } else if (request?.hasBackgroundSound ?? false) {
      sound.playBackgroundSoundFromPref();
    } else {
      sound.stopBackgroundSound();
    }

    var healthKitManager = HealthKitManager();
    if (await healthKitManager.isHealthSyncPermitted() != true) {
      // Only auto-prompt once; after that the user can opt in via Settings.
      // Avoids re-asking every session when they've declined.
      await healthKitManager.maybeRequestAuthorization();
    }

    // Only enable DND if permission is already granted and toggle is on
    if (Platform.isAndroid) {
      final dndNotifier = ref.read(dndProvider.notifier);
      final hasAccess = await dndNotifier.hasAccess();
      if (hasAccess) {
        await dndNotifier.setDndMode(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild on completion; the gate decides whether it is this session's.
    ref.watch(audioStateProvider.select((s) => s.isCompleted));
    if (!_timerStopped &&
        _completionGate.isSessionComplete(ref.read(audioStateProvider))) {
      _openEndScreen();
    }

    final currentlyPlayingTrack = ref.watch(playerProvider);

    ref.listen(playerProvider.select((p) => p?.coverUrl), (_, next) {
      if (next != null) {
        _precacheImage(next);
      }
    });

    // Listen for track changes and handle background sounds
    ref.listen(playerProvider.select((p) => p?.hasBackgroundSound), (
      previous,
      next,
    ) {
      if (ref.read(playerProvider)?.isTimer ?? false) return;
      if (next == false) {
        // Stop background sound if track doesn't allow it
        ref
            .read(backgroundSoundsNotifierProvider.notifier)
            .stopBackgroundSound();
      } else if (next == true) {
        // Start background sound if track allows it
        ref
            .read(backgroundSoundsNotifierProvider.notifier)
            .playBackgroundSoundFromPref();
      }
    });

    if (currentlyPlayingTrack == null) {
      return MeditoErrorWidget(
        error: const UnknownError(),
        onTap: () => Navigator.pop(context),
      );
    }

    if (_startFailed) {
      return MeditoErrorWidget(
        error: const UnknownError(),
        onTap: _retryPlayback,
      );
    }

    final isPlaying = ref.watch(audioStateProvider.select((s) => s.isPlaying));
    ref.listen(audioStateProvider.select((s) => s.isPlaying), (_, playing) {
      if (playing && !_playbackStarted) {
        _playbackStartFallback?.cancel();
        setState(() => _playbackStarted = true);
      }
    });

    // The transport (play/pause + progress) is genuinely loading until the
    // native player reports it's playing or knows the duration. Everything
    // else on screen is already final, so only the play button shows a spinner.
    // Buffering (initial spin-up OR a mid-session re-buffer on a slow network)
    // counts as loading too — the spinner in place of the play button is the
    // right signal there, so we don't gate it to the start.
    final audioState = ref.watch(audioStateProvider);
    final isAudioLoading =
        !audioState.isCompleted &&
        (!_playbackStarted || audioState.isBuffering);

    return PopScope<void>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _resetState();
          _stopAudio();
        }
      },
      child: PlayerScreenLayout(
        currentlyPlayingTrack: currentlyPlayingTrack,
        isPlaying: isPlaying,
        isAudioLoading: isAudioLoading,
        isBackgroundSoundSelected: _isBackgroundSoundSelected(),
        onPlayPausePressed: onPlayPausePressed,
        onSpeedChanged: (speed) =>
            ref.read(playerProvider.notifier).setSpeed(speed),
        onClosePressed: () => _handleClose(),
        onEndSession: _endTimerSession,
      ),
    );
  }

  Future<void> _endTimerSession() async {
    if (_endScreenOpened || _isClosing || _timerStopped) return;
    try {
      final result = await ref.read(playerProvider.notifier).closeTimer();
      if (result?.stopped == false) _showTimerStopError();
    } catch (error, stack) {
      AppLogger.e('TIMER', 'No se pudo detener el temporizador', error, stack);
      _showTimerStopError();
    }
  }

  void _showTimerStopError() {
    if (!mounted || _timerStopped) return;
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.timerStopError)));
  }

  void _onTimerClosed(TimerCloseResult result) {
    if (!mounted || _endScreenOpened || _isClosing) return;
    _timerStopped = true;
    if (result.recorded) {
      _openEndScreen();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.timerTooShort)),
      );
      _handleClose();
    }
  }

  void onPlayPausePressed() {
    final isPlaying = ref.read(audioStateProvider).isPlaying;

    // Control primary track
    ref.read(playerProvider.notifier).playPause();

    // For iOS, we need to explicitly toggle background sound too
    // Android will handle it in the native implementation
    if (Platform.isIOS) {
      ref
          .read(backgroundSoundsNotifierProvider.notifier)
          .togglePlayPause(isPlaying);
    }
  }

  bool _isBackgroundSoundSelected() {
    final bgSoundNotifier = ref.watch(backgroundSoundsNotifierProvider);
    final isPlaying = ref.watch(audioStateProvider.select((s) => s.isPlaying));

    return isPlaying && bgSoundNotifier.hasAnySound;
  }

  void _handleClose({bool shouldPop = true}) {
    if (_isClosing) {
      return;
    }
    _isClosing = true;
    final isTimer = ref.read(playerProvider)?.isTimer ?? false;
    if (isTimer) _stopAudio();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _resetState();
      if (!isTimer) _stopAudio();

      await ref.read(dndProvider.notifier).setDndMode(false);
      _endScreenOpened = false;

      if (mounted && shouldPop && Navigator.canPop(context)) {
        if (_timerStopped) {
          final route = ModalRoute.of(context);
          if (route != null && route.isActive) {
            Navigator.of(context).popUntil((current) => current == route);
          }
        }
        Navigator.pop(context);
      }

      _isClosing = false;
    });
    if (_timerStopped) WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _stopAudio() {
    if (_timerStopped) return;
    ref.read(playerProvider.notifier).stop();
    ref.read(backgroundSoundsNotifierProvider.notifier).stopBackgroundSound();
  }

  void _resetState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(audioStateProvider.notifier).resetState();
    });
  }

  void _openEndScreen() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_endScreenOpened && mounted) {
        _resetState();
        _stopAudio();
        final currentlyPlayingTrack = ref.read(playerProvider);
        if (currentlyPlayingTrack == null) return;

        unawaited(ref.read(dndProvider.notifier).setDndMode(false));

        // pushReplacement swaps whatever route is on top. If a sheet (repeat,
        // speed, background sound) is open when the session ends, that would
        // replace the sheet and leave the player underneath, so back from the
        // end screen returned to the player. Close anything above the player
        // first so the end screen always replaces the player itself.
        final navigator = Navigator.of(context);
        final playerRoute = ModalRoute.of(context);
        if (playerRoute != null && playerRoute.isActive) {
          navigator.popUntil((route) => route == playerRoute);
        }

        navigator.pushReplacement(
          MaterialPageRoute(
            builder: (context) => EndScreenView(
              request: currentlyPlayingTrack,
              priorStats: _statsAtSessionStart,
            ),
          ),
        );

        _endScreenOpened = true;
      }
    });
    if (_timerStopped) WidgetsBinding.instance.ensureVisualUpdate();
  }
}

/// The production player surface, separated from playback lifecycle for previews.
/// Existing controls and their callbacks are shared at every window size.
class PlayerScreenLayout extends StatelessWidget {
  const PlayerScreenLayout({
    super.key,
    required this.currentlyPlayingTrack,
    required this.isPlaying,
    required this.isAudioLoading,
    required this.isBackgroundSoundSelected,
    required this.onPlayPausePressed,
    required this.onSpeedChanged,
    required this.onClosePressed,
    this.onEndSession,
  });

  final PlaybackRequest currentlyPlayingTrack;
  final bool isPlaying;
  final bool isAudioLoading;
  final bool isBackgroundSoundSelected;
  final VoidCallback onPlayPausePressed;
  final ValueChanged<double> onSpeedChanged;
  final VoidCallback onClosePressed;

  /// Ends a timer session early and records it. Unused for tracks.
  final VoidCallback? onEndSession;

  @override
  Widget build(BuildContext context) {
    final title = currentlyPlayingTrack.title;
    final artistName = currentlyPlayingTrack.guideName;
    final artistUrl = currentlyPlayingTrack.artist?.path;
    final imageUrl = currentlyPlayingTrack.coverUrl;
    final isTimer = currentlyPlayingTrack.isTimer;
    final isStopwatch =
        isTimer && currentlyPlayingTrack.timerMode == TimerMode.stopwatch;
    // A timer ends with the stop button; tracks keep their repeat control.
    final onStop = isTimer ? onEndSession : null;
    final extraTimeStart = currentlyPlayingTrack.hasExtraTime
        ? currentlyPlayingTrack.plannedDurationMs
        : null;
    return Scaffold(
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final expanded =
              constraints.maxWidth >= 700 && constraints.maxHeight >= 440;
          return Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // No cover (a timer): a dark backdrop so the white
                    // controls read the same as over a blurred cover.
                    if (imageUrl.isEmpty)
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              ColorConstants.onyx,
                              ColorConstants.greyIsTheNewBlack,
                            ],
                          ),
                        ),
                      ),
                    if (imageUrl.isNotEmpty &&
                        !HTTPConstants.isDeadDomain(imageUrl))
                      // ImageFiltered (not BackdropFilter) — blurs only the
                      // cover image itself, never the screen behind. Using
                      // BackdropFilter here leaks the underlying route
                      // during pop animations, blurring the previous screen
                      // for a frame.
                      ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: _FadingNetworkImage(imageUrl: imageUrl),
                      ),
                    Container(
                      color: ColorConstants.black.withOpacityValue(0.3),
                    ),
                  ],
                ),
              ),
              RepaintBoundary(
                child: SafeArea(
                  child: Stack(
                    children: [
                      Center(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 32.0,
                            ),
                            child: constraints.maxHeight >= 440
                                ? _PortraitPlayerLayout(
                                    expanded: expanded,
                                    title: title,
                                    artistName: artistName,
                                    artistUrl: artistUrl,
                                    totalDurationMs:
                                        currentlyPlayingTrack.duration,
                                    isPlaying: isPlaying,
                                    isLoading: isAudioLoading,
                                    onPlayPause: onPlayPausePressed,
                                    isStopwatch: isStopwatch,
                                    extraTimeStart: extraTimeStart,
                                    onStop: onStop,
                                  )
                                : ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 1040,
                                    ),
                                    child: _LandscapePlayerLayout(
                                      title: title,
                                      artistName: artistName,
                                      artistUrl: artistUrl,
                                      totalDurationMs:
                                          currentlyPlayingTrack.duration,
                                      isPlaying: isPlaying,
                                      isLoading: isAudioLoading,
                                      onPlayPause: onPlayPausePressed,
                                      isStopwatch: isStopwatch,
                                      extraTimeStart: extraTimeStart,
                                      onStop: onStop,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endDocked,
      bottomNavigationBar: PlayerActionBar(
        request: currentlyPlayingTrack,
        isBackgroundSoundSelected: isBackgroundSoundSelected,
        onSpeedChanged: onSpeedChanged,
        onClosePressed: onClosePressed,
      ),
    );
  }
}

class _PortraitPlayerLayout extends ConsumerWidget {
  const _PortraitPlayerLayout({
    this.expanded = false,
    required this.title,
    required this.artistName,
    required this.artistUrl,
    required this.totalDurationMs,
    required this.isPlaying,
    required this.isLoading,
    required this.onPlayPause,
    this.isStopwatch = false,
    this.extraTimeStart,
    this.onStop,
  });

  final bool expanded;
  final String title;
  final String? artistName;
  final String? artistUrl;
  final int totalDurationMs;
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback onPlayPause;
  final bool isStopwatch;
  final int? extraTimeStart;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdaptivePlayerLayout(
      expanded: expanded,
      heading: ArtistTitleWidget(
        trackTitle: title,
        artistName: artistName ?? '',
        artistUrlPath: artistUrl,
        isPlayerScreen: true,
      ),
      controls: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isStopwatch || extraTimeStart != null)
            StopwatchElapsedWidget(plannedDurationMs: extraTimeStart)
          else
            DurationIndicatorWidget(
              fallbackDurationMs: totalDurationMs,
              onSeekEnd: (value) {
                ref.read(playerProvider.notifier).seekToPosition(value);
              },
            ),
          const SizedBox(height: 24),
          PlayerButtonsWidget(
            isPlaying: isPlaying,
            isLoading: isLoading,
            onPlayPause: onPlayPause,
            onSkip10SecondsBackward: () =>
                ref.read(playerProvider.notifier).skip10SecondsBackward(),
            onSkip10SecondsForward: () =>
                ref.read(playerProvider.notifier).skip10SecondsForward(),
            isPortrait: true,
            showSkipButtons: !isStopwatch && extraTimeStart == null,
            onStop: onStop,
          ),
        ],
      ),
    );
  }
}

class _LandscapePlayerLayout extends ConsumerWidget {
  const _LandscapePlayerLayout({
    required this.title,
    required this.artistName,
    required this.artistUrl,
    required this.totalDurationMs,
    required this.isPlaying,
    required this.isLoading,
    required this.onPlayPause,
    this.isStopwatch = false,
    this.extraTimeStart,
    this.onStop,
  });

  final String title;
  final String? artistName;
  final String? artistUrl;
  final int totalDurationMs;
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback onPlayPause;
  final bool isStopwatch;
  final int? extraTimeStart;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ArtistTitleWidget(
          trackTitle: title,
          artistName: artistName ?? '',
          artistUrlPath: artistUrl,
          isPlayerScreen: true,
        ),
        if (isStopwatch || extraTimeStart != null)
          StopwatchElapsedWidget(plannedDurationMs: extraTimeStart)
        else
          DurationIndicatorWidget(
            fallbackDurationMs: totalDurationMs,
            onSeekEnd: (value) {
              ref.read(playerProvider.notifier).seekToPosition(value);
            },
          ),
        PlayerButtonsWidget(
          isPlaying: isPlaying,
          isLoading: isLoading,
          onPlayPause: onPlayPause,
          onSkip10SecondsBackward: () =>
              ref.read(playerProvider.notifier).skip10SecondsBackward(),
          onSkip10SecondsForward: () =>
              ref.read(playerProvider.notifier).skip10SecondsForward(),
          isPortrait: false,
          showSkipButtons: !isStopwatch && extraTimeStart == null,
          onStop: onStop,
        ),
      ],
    );
  }
}

class _FadingNetworkImage extends StatefulWidget {
  final String imageUrl;

  const _FadingNetworkImage({required this.imageUrl});

  @override
  State<_FadingNetworkImage> createState() => _FadingNetworkImageState();
}

class _FadingNetworkImageState extends State<_FadingNetworkImage> {
  bool _imageLoaded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark
        ? ColorConstants.greyIsTheNewGrey
        : ColorConstants.lightBackground;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Grey background while loading
        Container(color: backgroundColor),

        // Network image with fade-in effect
        AnimatedOpacity(
          opacity: _imageLoaded ? 1.0 : 0.0,
          duration: const Duration(seconds: 2),
          child: Image.network(
            widget.imageUrl,
            fit: BoxFit.cover,
            cacheWidth: MediaQuery.of(context).size.width.toInt(),
            errorBuilder: (context, error, stackTrace) {
              return Container(color: backgroundColor);
            },
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (frame != null && !_imageLoaded) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    setState(() {
                      _imageLoaded = true;
                    });
                  }
                });
              }
              return child;
            },
          ),
        ),
      ],
    );
  }
}
