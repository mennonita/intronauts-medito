import 'package:medito/services/timer/timer_device_channel.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Usa la zona del dispositivo cuando existe en la base de zonas horarias.
Future<void> ensureLocalTimeZone({
  Future<String?> Function() timeZoneId = TimerDeviceChannel.timeZoneId,
}) async {
  if (!tz.timeZoneDatabase.isInitialized) tzdata.initializeTimeZones();
  final id = await timeZoneId();
  if (id == null) return;
  try {
    tz.setLocalLocation(tz.getLocation(id));
  } on tz.LocationNotFoundException {
    // Conserva la zona local si el identificador no existe en la base.
  }
}
