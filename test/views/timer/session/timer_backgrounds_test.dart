import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/timer/timer_background.dart';
import 'package:medito/views/timer/session/timer_backgrounds.dart';

void main() {
  const portrait = Size(360, 640);
  const landscape = Size(800, 260);
  const light = {
    TimerBackground.sunrise,
    TimerBackground.mist,
    TimerBackground.cream,
    TimerBackground.ice,
    TimerBackground.rose,
    TimerBackground.lavender,
  };

  test('cada fondo elige texto claro u oscuro según su contraste', () {
    for (final background in TimerBackground.values) {
      expect(
        background.foreground,
        light.contains(background) ? const Color(0xff171717) : Colors.white,
        reason: background.name,
      );
    }
    expect(
      TimerBackground.black.colorAt(
        const Offset(0.5, 0.38),
        size: portrait,
        withScrim: true,
      ),
      Colors.black,
    );
  });

  test('texto y controles mantienen contraste al abrir el fondo', () {
    for (final size in [portrait, landscape]) {
      for (final background in TimerBackground.values) {
        for (final phase in [0.0, 0.25, 0.5, 0.75]) {
          for (final point in const [
            Offset(0.08, 0.05),
            Offset(0.5, 0.32),
            Offset(0.5, timerCountCenter),
            Offset(0.34, 0.46),
            Offset(0.66, 0.46),
            Offset(0.5, 0.65),
            Offset(0.5, 0.78),
            Offset(0.3, 0.88),
            Offset(0.7, 0.88),
          ]) {
            final color = background.colorAt(
              point,
              size: size,
              phase: phase,
              withScrim: true,
            );
            for (final sample in [
              color,
              Color.alphaBlend(timerPickerBarrierColor, color),
            ]) {
              expect(
                timerContrastRatio(background.foreground, sample),
                greaterThanOrEqualTo(4.5),
                reason: '${background.name}, $size, $point, $phase',
              );
            }
          }
        }
      }
    }
    expect(timerPickerBarrierColor, Colors.black.withValues(alpha: 0.2));
  });

  test(
    'respiración y ondas son lentas y cada animación cambia con su fase',
    () {
      expect(
        TimerBackground.breathing.animationPeriod,
        const Duration(seconds: 10),
      );
      expect(
        TimerBackground.waves.animationPeriod!.inSeconds,
        greaterThanOrEqualTo(30),
      );
      for (final background in TimerBackground.values.where(
        (background) => background.kind == TimerBackgroundKind.animation,
      )) {
        List<Color> sample(double phase) => [
          for (var x = 0; x <= 30; x++)
            for (var y = 0; y <= 30; y++)
              background.colorAt(
                Offset(x / 30, y / 30),
                size: portrait,
                phase: phase,
              ),
        ];
        expect(sample(0.5), isNot(equals(sample(0))), reason: background.name);
        expect(sample(1), equals(sample(0)), reason: background.name);
      }
    },
  );
}
