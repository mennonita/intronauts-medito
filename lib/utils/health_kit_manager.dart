import 'dart:io';

import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/audio_pigeon.g.dart';

class HealthKitManager {
  static const _authRequestedKey = 'healthAuthRequested';

  static final HealthKitManager _instance = HealthKitManager._internal();
  final Health health = Health();
  final MeditoHealthConnectManager _androidBridge =
      MeditoHealthConnectManager();
  bool _configured = false;

  factory HealthKitManager() {
    return _instance;
  }

  HealthKitManager._internal();

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    if (Platform.isIOS) {
      await health.configure();
    }
    _configured = true;
  }

  Future<bool> isHealthConnectAvailable() async {
    if (!Platform.isAndroid) return true;
    try {
      final status = await _androidBridge.getStatus();
      return status == HealthConnectStatus.available;
    } catch (_) {
      return false;
    }
  }

  Future<void> installHealthConnect() async {
    if (!Platform.isAndroid) return;
    try {
      await _androidBridge.openHealthConnectInstall();
    } catch (_) {}
  }

  /// Si ya hay permiso de ESCRITURA de minutos de atención plena. La app
  /// solo escribe en Salud; nunca pide ni usa permiso de lectura.
  Future<bool?> isHealthSyncPermitted() async {
    try {
      await _ensureConfigured();
      if (Platform.isAndroid) {
        if (!await isHealthConnectAvailable()) return false;
        return await _androidBridge.hasMindfulnessPermissions();
      }
      return await health.hasPermissions(
        [HealthDataType.MINDFULNESS],
        permissions: [HealthDataAccess.WRITE],
      );
    } catch (e) {
      return false;
    }
  }

  /// `true` solo si hay permiso de escritura confirmado. Nunca muestra la
  /// ventana del sistema.
  Future<bool> hasWriteAccess() async => await isHealthSyncPermitted() == true;

  /// Whether we've already shown the system permission prompt at least once.
  /// Used to avoid nagging the user every session after they decline.
  Future<bool> hasRequestedAuthorization() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_authRequestedKey) ?? false;
  }

  /// Requests authorization only if we've never prompted before. Returns the
  /// resulting permission state (false if we'd already asked and won't re-ask).
  /// Solo para acciones explícitas de la persona (nunca desde una escritura en
  /// segundo plano ni durante la sesión). The Settings switch calls
  /// [requestAuthorization] directly so it can always re-prompt.
  Future<bool> maybeRequestAuthorization() async {
    if (await hasRequestedAuthorization()) return false;
    return requestAuthorization();
  }

  Future<bool> requestAuthorization() async {
    try {
      await _ensureConfigured();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_authRequestedKey, true);
      if (Platform.isAndroid) {
        if (!await isHealthConnectAvailable()) return false;
        return await _androidBridge.requestMindfulnessPermissions();
      }
      return await health.requestAuthorization(
        [HealthDataType.MINDFULNESS],
        permissions: [HealthDataAccess.WRITE],
      );
    } catch (e) {
      return false;
    }
  }

  Future<bool> isSessionSynced(int timestamp) async {
    final prefs = await SharedPreferences.getInstance();
    final syncedSessions = prefs.getStringList('syncedSessions') ?? [];

    return syncedSessions.contains(timestamp.toString());
  }

  Future<void> markSessionAsSynced(int timestamp) async {
    final prefs = await SharedPreferences.getInstance();
    final syncedSessions = prefs.getStringList('syncedSessions') ?? [];
    syncedSessions.add(timestamp.toString());
    await prefs.setStringList('syncedSessions', syncedSessions);
  }

  /// Escribe una sesión en Salud. Nunca pide permiso: sin permiso de
  /// escritura devuelve `false` y la cola lo reintenta después. En Android,
  /// [clientRecordId] hace que un reintento reemplace el registro en vez de
  /// duplicarlo.
  Future<bool> writeMindfulnessData(
    DateTime start,
    DateTime end, {
    String clientRecordId = '',
  }) async {
    try {
      await _ensureConfigured();

      if (Platform.isAndroid) {
        if (!await isHealthConnectAvailable()) return false;
        if (!await _androidBridge.hasMindfulnessPermissions()) return false;
        return await _androidBridge.writeMindfulnessSession(
          start.millisecondsSinceEpoch,
          end.millisecondsSinceEpoch,
          clientRecordId,
        );
      }

      if (!await hasWriteAccess()) return false;

      return await health.writeHealthData(
        value: 0,
        type: HealthDataType.MINDFULNESS,
        startTime: start,
        endTime: end,
        unit: HealthDataUnit.NO_UNIT,
        recordingMethod: RecordingMethod.automatic,
      );
    } catch (error) {
      return false;
    }
  }
}
