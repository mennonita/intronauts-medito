import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:medito/models/timer/timer_background.dart';

const _nearBlack = Color(0xff171717);
const timerCountCenter = 0.38;
const timerPickerHeightFraction = 0.45;
final timerPickerBarrierColor = Colors.black.withValues(alpha: 0.2);

List<Shadow>? timerForegroundShadows(Color foreground) =>
    foreground == Colors.white
    ? const [Shadow(color: Colors.black54, blurRadius: 6)]
    : null;

double timerContrastRatio(Color first, Color second) {
  final a = first.computeLuminance();
  final b = second.computeLuminance();
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

extension TimerBackgroundAppearance on TimerBackground {
  (Color, Color) get _baseColors => switch (this) {
    TimerBackground.breathing => (
      const Color(0xff101a22),
      const Color(0xff101a22),
    ),
    TimerBackground.waves => (const Color(0xff141723), const Color(0xff141723)),
    TimerBackground.particles => (
      const Color(0xff131f24),
      const Color(0xff131f24),
    ),
    TimerBackground.sunrise => (
      const Color(0xffffe0bd),
      const Color(0xfffff4e6),
    ),
    TimerBackground.mist => (const Color(0xffe4edf3), const Color(0xffd1dce6)),
    TimerBackground.night => (const Color(0xff253551), const Color(0xff090e19)),
    TimerBackground.slate => (const Color(0xff343e48), const Color(0xff343e48)),
    TimerBackground.forest => (
      const Color(0xff293c32),
      const Color(0xff293c32),
    ),
    TimerBackground.plum => (const Color(0xff493346), const Color(0xff493346)),
    TimerBackground.ocean => (const Color(0xff20424e), const Color(0xff20424e)),
    TimerBackground.cream => (const Color(0xfffff5df), const Color(0xfffff5df)),
    TimerBackground.ice => (const Color(0xffe3f4f6), const Color(0xffe3f4f6)),
    TimerBackground.rose => (const Color(0xfff7e0e5), const Color(0xfff7e0e5)),
    TimerBackground.lavender => (
      const Color(0xffece6fc),
      const Color(0xffece6fc),
    ),
    TimerBackground.black => (Colors.black, Colors.black),
  };

  Duration? get animationPeriod => switch (this) {
    TimerBackground.breathing => const Duration(seconds: 10),
    TimerBackground.waves => const Duration(seconds: 40),
    TimerBackground.particles => const Duration(seconds: 80),
    _ => null,
  };

  Color get foreground => _foregrounds[this]!;

  /// Muestra el color pintado en un punto relativo al tamaño de la vista.
  Color colorAt(
    Offset point, {
    required Size size,
    double phase = 0,
    bool withScrim = false,
  }) {
    final (top, bottom) = _baseColors;
    var color = Color.lerp(top, bottom, point.dy)!;
    final pixel = Offset(point.dx * size.width, point.dy * size.height);
    for (final glow in _glows(phase)) {
      color = Color.alphaBlend(glow.colorAt(pixel, size), color);
    }
    if (withScrim) {
      for (final scrim in _scrims(foreground)) {
        color = Color.alphaBlend(scrim.colorAt(point), color);
      }
    }
    return color;
  }

  Iterable<_Glow> _glows(double phase) {
    final progress = phase % 1;
    final angle = progress * math.pi * 2;
    return switch (this) {
      TimerBackground.breathing => [
        _Glow(
          const Offset(0.5, 0.44),
          0.22 + 0.12 * (1 - math.cos(angle)),
          const Color(0x60527a82),
        ),
      ],
      TimerBackground.waves => [
        _Glow(
          Offset(0.25 + 0.17 * math.cos(angle), 0.28 + 0.1 * math.sin(angle)),
          0.68,
          const Color(0x66596691),
        ),
        _Glow(
          Offset(0.73 + 0.12 * math.sin(angle), 0.52 + 0.19 * math.cos(angle)),
          0.55,
          const Color(0x5044877f),
        ),
        _Glow(
          Offset(0.45 - 0.2 * math.sin(angle), 0.85 - 0.13 * math.cos(angle)),
          0.6,
          const Color(0x40505c91),
        ),
      ],
      TimerBackground.particles => _particles.map(
        (particle) => _Glow(
          Offset(particle.x, (particle.y - progress) % 1),
          particle.radius,
          const Color(0x528da5ad),
        ),
      ),
      _ => const [],
    };
  }
}

const _contrastSampleSize = Size(360, 640);
final _foregrounds = {
  for (final background in TimerBackground.values)
    background: _contrastingForeground(background),
};

Color _contrastingForeground(TimerBackground background) {
  var red = 0.0;
  var green = 0.0;
  var blue = 0.0;
  var samples = 0;
  final phases = background.animationPeriod == null
      ? const [0.0]
      : const [0.0, 0.25, 0.5, 0.75];
  for (final phase in phases) {
    for (var x = 1; x < 10; x += 2) {
      for (var y = 1; y < 10; y += 2) {
        final color = background.colorAt(
          Offset(x / 10, y / 10),
          size: _contrastSampleSize,
          phase: phase,
        );
        red += color.r;
        green += color.g;
        blue += color.b;
        samples++;
      }
    }
  }
  final average = Color.from(
    alpha: 1,
    red: red / samples,
    green: green / samples,
    blue: blue / samples,
  );
  return timerContrastRatio(Colors.white, average) >=
          timerContrastRatio(_nearBlack, average)
      ? Colors.white
      : _nearBlack;
}

final _particles = _makeParticles();

List<({double x, double y, double radius})> _makeParticles() {
  final random = math.Random(23);
  return List.generate(
    24,
    (_) => (
      x: random.nextDouble(),
      y: random.nextDouble(),
      radius: 0.002 + random.nextDouble() * 0.004,
    ),
  );
}

class _Glow {
  const _Glow(this.center, this.radius, this.color);

  final Offset center;
  final double radius;
  final Color color;

  Offset _centerIn(Size size) =>
      Offset(center.dx * size.width, center.dy * size.height);

  Color colorAt(Offset point, Size size) {
    final distance =
        (point - _centerIn(size)).distance / (radius * size.shortestSide);
    return color.withValues(alpha: color.a * (1 - distance).clamp(0.0, 1.0));
  }

  void paint(Canvas canvas, Size size) {
    final center = _centerIn(size);
    final radius = this.radius * size.shortestSide;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = ui.Gradient.radial(center, radius, [
          color,
          color.withValues(alpha: 0),
        ]),
    );
  }
}

List<_Scrim> _scrims(Color foreground) {
  final color = foreground == Colors.white ? Colors.black : Colors.white;
  return [
    _Scrim(timerCountCenter, 0.24, color.withValues(alpha: 0.28)),
    _Scrim(0.8, 0.23, color.withValues(alpha: 0.26)),
  ];
}

class _Scrim {
  const _Scrim(this.centerY, this.radiusY, this.color);

  final double centerY;
  final double radiusY;
  final Color color;
  static const _radiusX = 0.82;

  Color colorAt(Offset point) {
    final distance = Offset(
      (point.dx - 0.5) / _radiusX,
      (point.dy - centerY) / radiusY,
    ).distance;
    return color.withValues(alpha: color.a * (1 - distance).clamp(0.0, 1.0));
  }

  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, centerY * size.height);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(_radiusX * size.width, radiusY * size.height);
    canvas.drawCircle(
      Offset.zero,
      1,
      Paint()
        ..shader = ui.Gradient.radial(Offset.zero, 1, [
          color,
          color.withValues(alpha: 0),
        ]),
    );
    canvas.restore();
  }
}

class TimerBackgroundCanvas extends StatelessWidget {
  const TimerBackgroundCanvas({
    super.key,
    required this.background,
    this.animate = false,
    this.withScrim = false,
  });

  final TimerBackground background;
  final bool animate;
  final bool withScrim;

  @override
  Widget build(BuildContext context) {
    final period = background.animationPeriod;
    return RepaintBoundary(
      child:
          animate && period != null && !MediaQuery.disableAnimationsOf(context)
          ? _AnimatedBackground(
              key: ValueKey(background),
              background: background,
              period: period,
              withScrim: withScrim,
            )
          : CustomPaint(
              painter: _BackgroundPainter(background, withScrim: withScrim),
            ),
    );
  }
}

class _AnimatedBackground extends StatefulWidget {
  const _AnimatedBackground({
    super.key,
    required this.background,
    required this.period,
    required this.withScrim,
  });

  final TimerBackground background;
  final Duration period;
  final bool withScrim;

  @override
  State<_AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<_AnimatedBackground>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _BackgroundPainter(
      widget.background,
      withScrim: widget.withScrim,
      phase: _controller,
    ),
  );
}

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter(this.background, {required this.withScrim, this.phase})
    : super(repaint: phase);

  final TimerBackground background;
  final bool withScrim;
  final Animation<double>? phase;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final (top, bottom) = background._baseColors;
    final base = Paint()..color = top;
    if (top != bottom) {
      base.shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
        top,
        bottom,
      ]);
    }
    canvas.drawRect(Offset.zero & size, base);
    for (final glow in background._glows(phase?.value ?? 0)) {
      glow.paint(canvas, size);
    }
    if (withScrim) {
      for (final scrim in _scrims(background.foreground)) {
        scrim.paint(canvas, size);
      }
    }
  }

  @override
  bool shouldRepaint(_BackgroundPainter oldDelegate) =>
      background != oldDelegate.background ||
      withScrim != oldDelegate.withScrim ||
      phase != oldDelegate.phase;
}
