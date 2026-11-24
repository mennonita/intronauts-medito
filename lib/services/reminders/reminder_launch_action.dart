import 'package:medito/models/timer/timer_launch.dart';

class ReminderLaunchAction {
  // En la siguiente fase se leerá la acción del aviso que abrió la app.
  static Future<TimerLaunch?> take() async => null;
}

class ReminderSeriesMigration {
  // En la siguiente fase se actualizarán los avisos pendientes.
  static Future<void> runOnce() async {}
}
