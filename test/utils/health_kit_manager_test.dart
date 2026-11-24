import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/src/audio_pigeon.g.dart';
import 'package:medito/utils/health_kit_manager.dart';

/// Puente de Health Connect falso: cada consulta puede quedarse esperando.
class _FakeBridge extends MeditoHealthConnectManager {
  Completer<HealthConnectStatus>? status;
  Completer<bool>? permissions;
  final writes = <String>[];

  @override
  Future<HealthConnectStatus> getStatus() =>
      status?.future ?? Future.value(HealthConnectStatus.available);

  @override
  Future<bool> hasMindfulnessPermissions() =>
      permissions?.future ?? Future.value(true);

  @override
  Future<bool> writeMindfulnessSession(
    int startEpochMs,
    int endEpochMs,
    String clientRecordId,
  ) async {
    writes.add(clientRecordId);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeBridge bridge;
  late HealthKitManager manager;
  late bool allowed;

  final start = DateTime.fromMillisecondsSinceEpoch(1000);
  final end = DateTime.fromMillisecondsSinceEpoch(61000);

  Future<bool> write() => manager.writeMindfulnessData(
    start,
    end,
    clientRecordId: 'run-1',
    stillAllowed: () => allowed,
  );

  setUp(() {
    bridge = _FakeBridge();
    manager = HealthKitManager.forTesting(androidBridge: bridge);
    allowed = true;
  });

  group('revalidar dentro de la escritura a Salud (TMR-01)', () {
    test('sin cambios, la sesión se envía con su clave', () async {
      expect(await write(), isTrue);
      expect(bridge.writes, ['run-1']);
    });

    test('apagar Salud o cambiar de cuenta mientras se consultan los '
        'permisos no envía', () async {
      bridge.permissions = Completer<bool>();
      final writing = write();
      await pumpEventQueue();
      allowed = false;
      bridge.permissions!.complete(true);

      expect(await writing, isFalse);
      expect(bridge.writes, isEmpty);
    });

    test('un cambio mientras se consulta si Health Connect está disponible '
        'no envía', () async {
      bridge.status = Completer<HealthConnectStatus>();
      final writing = write();
      await pumpEventQueue();
      allowed = false;
      bridge.status!.complete(HealthConnectStatus.available);

      expect(await writing, isFalse);
      expect(bridge.writes, isEmpty);
    });

    test('invalidar suelta la escritura que esperaba en el puente', () async {
      bridge.permissions = Completer<bool>();
      final writing = write();
      await pumpEventQueue();
      manager.invalidatePendingWrites();
      bridge.permissions!.complete(true);

      expect(await writing, isFalse);
      expect(bridge.writes, isEmpty);

      // Una escritura nueva, después de invalidar, sí sale.
      expect(await write(), isTrue);
      expect(bridge.writes, ['run-1']);
    });

    test('si ya no vale desde el principio, ni consulta el puente', () async {
      allowed = false;
      bridge.status = Completer<HealthConnectStatus>();

      expect(await write(), isFalse);
      expect(bridge.writes, isEmpty);
    });
  });
}
