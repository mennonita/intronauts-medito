import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/timer/timer_timeline.dart';
import 'package:medito/providers/player/audio_state_provider.dart';
import 'package:medito/providers/timer/timer_background_provider.dart';
import 'package:medito/services/analytics/firebase_analytics_service.dart';
import 'package:medito/views/background_sound/background_sound_view.dart';

import 'timer_background_picker.dart';
import 'timer_backgrounds.dart';
import 'timer_count_text.dart';

class TimerSessionLayout extends ConsumerStatefulWidget {
  const TimerSessionLayout({
    super.key,
    required this.request,
    required this.isPlaying,
    required this.isAudioLoading,
    required this.isBackgroundSoundSelected,
    required this.onPlayPausePressed,
    required this.onClosePressed,
    required this.onEndSession,
    this.isClosing,
  });

  final PlaybackRequest request;
  final bool isPlaying;
  final bool isAudioLoading;
  final bool isBackgroundSoundSelected;
  final VoidCallback onPlayPausePressed;
  final VoidCallback onClosePressed;
  final VoidCallback onEndSession;
  final bool Function()? isClosing;

  @override
  ConsumerState<TimerSessionLayout> createState() => _TimerSessionLayoutState();
}

class _TimerSessionLayoutState extends ConsumerState<TimerSessionLayout> {
  Timer? _fadeTimer;
  bool _controlsVisible = true;
  bool _accessibleNavigation = false;
  bool _sheetOpen = false;
  late SystemUiOverlayStyle _exitOverlayStyle;

  // Preparación o tiempo extra: los controles se quedan a la vista.
  bool _holdControls = false;

  bool get _canHideControls =>
      widget.isPlaying &&
      !widget.isAudioLoading &&
      !_accessibleNavigation &&
      !_holdControls;

  bool _holdsControlsAt(int positionMs) {
    final timeline = TimerTimeline.fromRequest(widget.request);
    return timeline.inPrep(positionMs) || timeline.isExtraTime(positionMs);
  }

  @override
  void initState() {
    super.initState();
    _holdControls = _holdsControlsAt(ref.read(audioStateProvider).position);
  }

  bool get _isClosing => widget.isClosing?.call() ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery avisa si cambia el brillo del sistema durante la sesión.
    MediaQuery.platformBrightnessOf(context);
    final brightness = Theme.brightnessOf(context);
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    _exitOverlayStyle = _overlayStyle(icons);
    final accessibleNavigation = MediaQuery.accessibleNavigationOf(context);
    if (accessibleNavigation != _accessibleNavigation || _fadeTimer == null) {
      _accessibleNavigation = accessibleNavigation;
      _controlsVisible = true;
      _scheduleFade();
    }
  }

  @override
  void didUpdateWidget(covariant TimerSessionLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request != widget.request) {
      _holdControls = _holdsControlsAt(ref.read(audioStateProvider).position);
    }
    if (oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.isAudioLoading != widget.isAudioLoading ||
        oldWidget.request != widget.request) {
      _controlsVisible = true;
      _scheduleFade();
    }
  }

  void _scheduleFade() {
    _fadeTimer?.cancel();
    _fadeTimer = _canHideControls
        ? Timer(const Duration(seconds: 6), () {
            setState(() => _controlsVisible = false);
          })
        : null;
  }

  void _revealControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleFade();
  }

  Future<void> _openSheet(Future<void> Function(BuildContext) show) async {
    if (_isClosing || _sheetOpen) return;
    _sheetOpen = true;
    try {
      await show(context);
    } finally {
      _sheetOpen = false;
      if (mounted && !_isClosing) _revealControls();
    }
  }

  Future<void> _showSounds(BuildContext context) {
    unawaited(
      FirebaseAnalyticsService().logEvent(
        name: AnalyticsEventConstants.playerBackgroundSoundsOpened,
      ),
    );
    return showBackgroundSoundSheet(context);
  }

  static SystemUiOverlayStyle _overlayStyle(Brightness icons) =>
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: icons,
        statusBarBrightness: icons == Brightness.light
            ? Brightness.dark
            : Brightness.light,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: icons,
      );

  @override
  void dispose() {
    _fadeTimer?.cancel();
    SystemChrome.setSystemUIOverlayStyle(_exitOverlayStyle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      audioStateProvider.select((state) => _holdsControlsAt(state.position)),
      (_, hold) {
        if (hold == _holdControls) return;
        setState(() {
          _holdControls = hold;
          _controlsVisible = true;
        });
        _scheduleFade();
      },
    );
    final background = ref.watch(timerBackgroundProvider);
    final foreground = background.foreground;
    final icons = foreground == Colors.white
        ? Brightness.light
        : Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final fadeDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300);

    Widget fadingControls(Widget child) => IgnorePointer(
      ignoring: !_controlsVisible,
      child: ExcludeSemantics(
        excluding: !_controlsVisible,
        child: AnimatedOpacity(
          duration: fadeDuration,
          opacity: _controlsVisible ? 1 : 0,
          child: child,
        ),
      ),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _overlayStyle(icons),
      child: Scaffold(
        body: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _revealControls(),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = constraints.maxHeight;
              final countBottom = 1 - timerPickerHeightFraction;
              final request = widget.request;
              return Stack(
                fit: StackFit.expand,
                children: [
                  TimerBackgroundCanvas(
                    background: background,
                    animate: true,
                    withScrim: true,
                  ),
                  Positioned(
                    top: height * (timerCountCenter * 2 - countBottom),
                    bottom: height * timerPickerHeightFraction,
                    left: 16,
                    right: 16,
                    child: SafeArea(
                      top: false,
                      bottom: false,
                      child: TimerCountText(
                        key: ValueKey((
                          request.trackId,
                          request.fileId,
                          request.timerSeed,
                        )),
                        request: request,
                        foreground: foreground,
                        paused: !widget.isPlaying && !widget.isAudioLoading,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    child: fadingControls(
                      SafeArea(
                        bottom: false,
                        child: IconButton(
                          tooltip: l10n.timerExit,
                          color: foreground,
                          onPressed: _isClosing ? null : widget.onClosePressed,
                          icon: Icon(
                            Icons.close,
                            shadows: timerForegroundShadows(foreground),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: height * countBottom,
                    bottom: 0,
                    left: 8,
                    right: 8,
                    child: fadingControls(
                      SafeArea(
                        top: false,
                        // Sin reducir el tamaño: con letra grande los
                        // controles se acomodan en filas y se desplazan.
                        child: Center(
                          child: SingleChildScrollView(
                            child: _buildControls(
                              l10n,
                              foreground,
                              compact: height < 440,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildControls(
    AppLocalizations l10n,
    Color foreground, {
    required bool compact,
  }) {
    final shadows = timerForegroundShadows(foreground);
    final playPause = IconButton.outlined(
      tooltip: widget.isPlaying ? l10n.pause : l10n.continueText,
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        disabledForegroundColor: foreground,
        side: BorderSide(color: foreground.withValues(alpha: 0.55)),
        fixedSize: const Size.square(64),
        shadowColor: Colors.transparent,
      ),
      onPressed: widget.isAudioLoading || _isClosing
          ? null
          : widget.onPlayPausePressed,
      icon: widget.isAudioLoading
          ? SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
          : Icon(
              widget.isPlaying ? Icons.pause : Icons.play_arrow,
              size: 32,
              shadows: shadows,
            ),
    );
    final end = OutlinedButton(
      onPressed: _isClosing ? null : widget.onEndSession,
      style: OutlinedButton.styleFrom(
        foregroundColor: foreground,
        disabledForegroundColor: foreground.withValues(alpha: 0.55),
        minimumSize: const Size(120, 48),
        side: BorderSide(color: foreground.withValues(alpha: 0.55)),
      ),
      child: Text(
        l10n.timerEndSession,
        textAlign: TextAlign.center,
        style: TextStyle(shadows: shadows),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (compact)
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [playPause, end],
          )
        else ...[
          playPause,
          const SizedBox(height: 8),
          end,
        ],
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            Semantics(
              selected: widget.isBackgroundSoundSelected,
              child: _optionButton(
                l10n.backgroundSounds,
                widget.isBackgroundSoundSelected
                    ? Icons.volume_up
                    : Icons.graphic_eq,
                foreground,
                () => _openSheet(_showSounds),
              ),
            ),
            _optionButton(
              l10n.timerBackgroundTitle,
              Icons.palette_outlined,
              foreground,
              () => _openSheet(showTimerBackgroundPicker),
            ),
          ],
        ),
      ],
    );
  }

  Widget _optionButton(
    String label,
    IconData icon,
    Color foreground,
    VoidCallback onPressed,
  ) {
    final shadows = timerForegroundShadows(foreground);
    return TextButton(
      onPressed: _isClosing ? null : onPressed,
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        minimumSize: const Size(48, 48),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, shadows: shadows),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(shadows: shadows),
          ),
        ],
      ),
    );
  }
}
