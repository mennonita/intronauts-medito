import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_session.dart';
import 'package:medito/views/home/widgets/home_gradient_border.dart';

/// Ruedas de horas y minutos. Al deslizar, los minutos vuelven de 59 a 0.
/// Reporta la duración total en minutos.
class TimerDurationWheels extends StatefulWidget {
  const TimerDurationWheels({
    super.key,
    required this.minutes,
    required this.onChanged,
  });

  static const height = 168.0;
  static const radius = 28.0;
  static const _itemExtent = 80.0;
  static const _digitFontSize = 64.0;
  static const _maxDigitScale = 1.3;

  final int minutes;
  final ValueChanged<int> onChanged;

  static TextStyle digitStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.displayLarge!.copyWith(
      fontSize: _digitFontSize,
      height: 1,
      fontWeight: FontWeight.w400,
      letterSpacing: -2,
      color: theme.colorScheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  @override
  State<TimerDurationWheels> createState() => TimerDurationWheelsState();
}

class TimerDurationWheelsState extends State<TimerDurationWheels> {
  late FixedExtentScrollController _hours;
  late FixedExtentScrollController _minutes;
  late int _selection;
  double? _digitScale;

  // Los movimientos dirigidos no reportan los pasos intermedios.
  ({Object token, int minutes})? _pendingMove;

  @override
  void initState() {
    super.initState();
    _selection = widget.minutes;
    _createControllers();
  }

  void _createControllers() {
    _hours = FixedExtentScrollController(initialItem: _selection ~/ 60);
    // La rueda de minutos empieza lejos del cero para girar en ambos sentidos.
    _minutes = FixedExtentScrollController(
      initialItem: 60 * 100 + _selection % 60,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    const fontSize = TimerDurationWheels._digitFontSize;
    final digitScale = _digitTextScaler(context).scale(fontSize) / fontSize;
    if (_digitScale != null && _digitScale != digitScale) {
      // Conserva la selección al cambiar la altura de los números.
      final previousHours = _hours;
      final previousMinutes = _minutes;
      _selection = _pendingMove?.minutes ?? _selection;
      _pendingMove = null;
      _createControllers();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        previousHours.dispose();
        previousMinutes.dispose();
      });
    }
    _digitScale = digitScale;
  }

  @override
  void dispose() {
    _hours.dispose();
    _minutes.dispose();
    super.dispose();
  }

  /// Mueve las ruedas al elegir una duración guardada.
  Future<void> animateTo(int minutes) => _moveTo(
    minutes,
    animate: !MediaQuery.disableAnimationsOf(context),
    reportChange: false,
  );

  Future<void> _moveTo(
    int minutes, {
    required bool animate,
    required bool reportChange,
  }) async {
    if (!_hours.hasClients || !_minutes.hasClients) return;
    final current = _minutes.selectedItem;
    var delta = (minutes % 60 - current % 60) % 60;
    if (delta > 30) delta -= 60;
    final move = (token: Object(), minutes: minutes);
    _pendingMove = move;
    try {
      if (animate) {
        const duration = Duration(milliseconds: 450);
        const curve = Curves.easeOutCubic;
        await Future.wait([
          _hours.animateToItem(minutes ~/ 60, duration: duration, curve: curve),
          _minutes.animateToItem(
            current + delta,
            duration: duration,
            curve: curve,
          ),
        ]);
      } else {
        _hours.jumpToItem(minutes ~/ 60);
        _minutes.jumpToItem(current + delta);
      }
    } finally {
      if (mounted && _pendingMove?.token == move.token) {
        _pendingMove = null;
        _updateSelection(reportChange: reportChange);
      }
    }
  }

  void _onWheelChanged() {
    if (_pendingMove == null) _updateSelection(reportChange: true);
  }

  void _updateSelection({required bool reportChange}) {
    final selected = _hours.selectedItem * 60 + _minutes.selectedItem % 60;
    if (_selection == selected) return;
    setState(() => _selection = selected);
    if (reportChange) {
      unawaited(HapticFeedback.selectionClick());
      widget.onChanged(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hours = _selection ~/ 60;
    final minutes = _selection % 60;
    final digitScale = _digitScale!;
    return Row(
      children: [
        Expanded(
          child: _Wheel(
            controller: _hours,
            label: l10n.timerHoursLabel,
            semanticsLabel: l10n.timerHoursWheelLabel(hours),
            value: hours,
            maxValue: kMaxTimerHours,
            digitScale: digitScale,
            onAdjusted: (value) => unawaited(
              _moveTo(value * 60 + minutes, animate: false, reportChange: true),
            ),
            onSelectedItemChanged: (_) => _onWheelChanged(),
            delegate: ListWheelChildBuilderDelegate(
              childCount: kMaxTimerHours + 1,
              builder: (context, index) => _Digits(index),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _Wheel(
            controller: _minutes,
            label: l10n.timerMinutesLabel,
            semanticsLabel: l10n.timerMinutesWheelLabel(minutes),
            value: minutes,
            maxValue: 59,
            digitScale: digitScale,
            onAdjusted: (value) => unawaited(
              _moveTo(hours * 60 + value, animate: false, reportChange: true),
            ),
            onSelectedItemChanged: (_) => _onWheelChanged(),
            delegate: ListWheelChildLoopingListDelegate(
              children: [for (var i = 0; i < 60; i++) _Digits(i)],
            ),
          ),
        ),
      ],
    );
  }
}

class _Wheel extends StatelessWidget {
  const _Wheel({
    required this.controller,
    required this.label,
    required this.semanticsLabel,
    required this.value,
    required this.maxValue,
    required this.digitScale,
    required this.onAdjusted,
    required this.onSelectedItemChanged,
    required this.delegate,
  });

  final FixedExtentScrollController controller;
  final String label;
  final String semanticsLabel;
  final int value;
  final int maxValue;
  final double digitScale;
  final ValueChanged<int> onAdjusted;
  final ValueChanged<int> onSelectedItemChanged;
  final ListWheelChildDelegate delegate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: semanticsLabel,
      value: '$value',
      increasedValue: value < maxValue ? '${value + 1}' : null,
      decreasedValue: value > 0 ? '${value - 1}' : null,
      onIncrease: value < maxValue ? () => onAdjusted(value + 1) : null,
      onDecrease: value > 0 ? () => onAdjusted(value - 1) : null,
      child: Column(
        children: [
          HomeGradientBorder(
            backgroundColor: theme.cardColor,
            borderRadius: TimerDurationWheels.radius,
            borderWidth: 0.5,
            child: SizedBox(
              height: TimerDurationWheels.height * digitScale,
              // Desvanece los números vecinos hacia los bordes.
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black,
                    Colors.black,
                    Colors.transparent,
                  ],
                  stops: [0, 0.3, 0.7, 1],
                ).createShader(rect),
                child: ListWheelScrollView.useDelegate(
                  key: ValueKey(digitScale),
                  controller: controller,
                  itemExtent: TimerDurationWheels._itemExtent * digitScale,
                  physics: const FixedExtentScrollPhysics(),
                  diameterRatio: 1.8,
                  overAndUnderCenterOpacity: 0.35,
                  onSelectedItemChanged: onSelectedItemChanged,
                  childDelegate: delegate,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _Digits extends StatelessWidget {
  const _Digits(this.value);

  final int value;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        value.toString().padLeft(2, '0'),
        textScaler: _digitTextScaler(context),
        style: TimerDurationWheels.digitStyle(context),
      ),
    );
  }
}

TextScaler _digitTextScaler(BuildContext context) => MediaQuery.textScalerOf(
  context,
).clamp(maxScaleFactor: TimerDurationWheels._maxDigitScale);
