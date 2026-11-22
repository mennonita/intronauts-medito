import 'package:flutter/material.dart';
import 'package:medito/views/home/widgets/stats/streak_circle_constants.dart';

class StreakCircleController extends ChangeNotifier {
  final TickerProvider vsync;
  late final AnimationController animationController;
  bool _isAnimating = false;

  StreakCircleController({required this.vsync}) {
    animationController = AnimationController(
      vsync: vsync,
      duration: StreakCircleConstants.animationDuration,
    );
  }

  bool get isAnimating => _isAnimating;

  /// Respeta la preferencia del sistema de reducir el movimiento.
  bool reduceMotion = false;

  void updateAnimation(bool shouldAnimate) {
    if (reduceMotion) shouldAnimate = false;
    if (shouldAnimate && !_isAnimating) {
      animationController.repeat();
      _isAnimating = true;
    } else if (!shouldAnimate && _isAnimating) {
      animationController.stop();
      _isAnimating = false;
    }
  }

  @override
  void dispose() {
    animationController.dispose();
    super.dispose();
  }
}
