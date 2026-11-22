import 'package:flutter_test/flutter_test.dart';
import 'package:medito/views/home/widgets/stats/streak_circle_constants.dart';
import 'package:medito/views/home/widgets/stats/streak_circle_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreakCircleController controller;

  setUp(() {
    controller = StreakCircleController(vsync: const TestVSync());
  });

  tearDown(() {
    controller.dispose();
  });

  group('StreakCircleController', () {
    test('initialises with animation controller', () {
      expect(controller.animationController, isNotNull);
      expect(
        controller.animationController.duration,
        StreakCircleConstants.animationDuration,
      );
      expect(controller.isAnimating, false);
    });

    test('updateAnimation starts animation when shouldAnimate is true', () {
      controller.updateAnimation(true);
      expect(controller.isAnimating, true);
      expect(controller.animationController.isAnimating, true);
    });

    test('updateAnimation stops animation when shouldAnimate is false', () {
      controller.updateAnimation(true);
      controller.updateAnimation(false);
      expect(controller.isAnimating, false);
      expect(controller.animationController.isAnimating, false);
    });

    test('updateAnimation never starts the ring under reduced motion', () {
      controller.reduceMotion = true;
      controller.updateAnimation(true);
      expect(controller.isAnimating, false);
      expect(controller.animationController.isAnimating, false);
    });

    test('reduced motion turning on stops a ring that is already running', () {
      controller.updateAnimation(true);
      expect(controller.isAnimating, true);
      controller.reduceMotion = true;
      controller.updateAnimation(true);
      expect(controller.isAnimating, false);
      expect(controller.animationController.isAnimating, false);
    });
  });
}
