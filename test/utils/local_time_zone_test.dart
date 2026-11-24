import 'package:flutter_test/flutter_test.dart';
import 'package:medito/services/timer/timer_device_channel.dart';
import 'package:medito/utils/local_time_zone.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TimerDeviceChannel.debugIsAndroid = null;
    tz.setLocalLocation(tz.UTC);
  });

  test(
    'cambia a la zona del dispositivo cuando el identificador existe',
    () async {
      await ensureLocalTimeZone(timeZoneId: () async => 'America/Mexico_City');
      expect(tz.local.name, 'America/Mexico_City');
    },
  );

  test(
    'conserva la zona local con un identificador desconocido o nulo',
    () async {
      await ensureLocalTimeZone(timeZoneId: () async => 'America/Mexico_City');
      final original = tz.local;
      await ensureLocalTimeZone(timeZoneId: () async => 'Invalid/Zone');
      expect(tz.local, same(original));
      await ensureLocalTimeZone(timeZoneId: () async => null);
      expect(tz.local, same(original));
    },
  );

  test('conserva la zona local si falta el canal nativo', () async {
    await ensureLocalTimeZone(timeZoneId: () async => 'America/Mexico_City');
    final original = tz.local;
    TimerDeviceChannel.debugIsAndroid = true;
    await ensureLocalTimeZone();
    expect(tz.local, same(original));
  });

  test('conserva la zona local fuera de Android', () async {
    await ensureLocalTimeZone(timeZoneId: () async => 'America/Mexico_City');
    final original = tz.local;
    TimerDeviceChannel.debugIsAndroid = false;
    await ensureLocalTimeZone();
    expect(tz.local, same(original));
  });
}
