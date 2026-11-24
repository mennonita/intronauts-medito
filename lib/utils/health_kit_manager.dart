import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/audio_pigeon.g.dart';

class HealthKitManager {
  static const _authRequestedKey = 'healthAuthRequested';

  static final HealthKitManager _instance = HealthKitManager._internal();
  final Health health;
  final MeditoHealthConnectManager _androidBridge;
  final bool _isAndroid;
  final bool _isIOS;
  bool _configured = false;

  // Sube con [invalidatePendingWrites]: una escritura que todavía espera al
  // puente (configuración, disponibilidad o permisos) ya no sale (TMR-01).
  int _writeEpoch = 0;

  factory HealthKitManager() {
    return _instance;
  }

  HealthKitManager._internal()
    : health = Health(),
      _androidBridge = MeditoHealthConnectManager(),
      _isAndroid = Platform.isAndroid,
      _isIOS = Platform.isIOS;

  /// Gestor con puente y plataforma falsos, para las pruebas.
  @visibleForTesting
  HealthKitManager.forTesting({
    required MeditoHealthConnectManager androidBridge,
    Health? health,
    bool isAndroid = true,
  }) : health = health ?? Health(),
       _androidBridge = androidBridge,
       _isAndroid = isAndroid,
       _isIOS = !isAndroid;

  /// Ninguna escritura que ya empezó y aún no llega a Salud se envía. Se
  /// llama al apagar Salud y al cambiar o borrar la cuenta.
  void invalidatePendingWrites() => _writeEpoch++;

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    if (_isIOS) {
      await health.configure();
    }
    _configured = true;
  }

  Future<bool> isHealthConnectAvailable() async {
    if (!_isAndroid) return true;
    try {
      final status = await _androidBridge.getStatus();
      return status == HealthConnectStatus.available;
    } catch (_) {
      return false;
    }
  }

  Future<void> installHealthConnect() async {
    if (!_isAndroid) return;
    try {
      await _androidBridge.openHealthConnectInstall();
    } catch (_) {}
  }

  /// Si ya hay permiso de ESCRITURA de minutos de atención plena. La app
  /// solo escribe en Salud; nunca pide ni usa permiso de lectura.
  Future<bool?> isHealthSyncPermitted() async {
    try {
      await _ensureConfigured();
      if (_isAndroid) {
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
      if (_isAndroid) {
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
  ///
  /// [stillAllowed] lo da la cola: dice si la sesión sigue siendo de la
  /// cuenta actual, con su permiso y en la misma generación. Se revisa
  /// después de cada consulta al sistema y justo antes de enviar; si ya no
  /// vale, o si [invalidatePendingWrites] llegó mientras tanto, no se envía
  /// nada y devuelve `false` (TMR-01).
  Future<bool> writeMindfulnessData(
    DateTime start,
    DateTime end, {
    String clientRecordId = '',
    bool Function()? stillAllowed,
  }) async {
    final epoch = _writeEpoch;
    bool allowed() => epoch == _writeEpoch && (stillAllowed?.call() ?? true);
    try {
      if (!allowed()) return false;
      await _ensureConfigured();
      if (!allowed()) return false;

      if (_isAndroid) {
        if (!await isHealthConnectAvailable()) return false;
        if (!allowed()) return false;
        if (!await _androidBridge.hasMindfulnessPermissions()) return false;
        // Sin ninguna espera entre esta revisión y el envío.
        if (!allowed()) return false;
        return await _androidBridge.writeMindfulnessSession(
          start.millisecondsSinceEpoch,
          end.millisecondsSinceEpoch,
          clientRecordId,
        );
      }

      if (!await hasWriteAccess()) return false;
      // Sin ninguna espera entre esta revisión y el envío.
      if (!allowed()) return false;

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
