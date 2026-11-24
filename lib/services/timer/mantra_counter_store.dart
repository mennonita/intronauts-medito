import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lo que pasó con un toque del contador.
enum BeadResult { bead, round, ignored }

/// Contador de mantras (F2). Las cuentas son datos religiosos sensibles: se
/// guardan SOLO en este teléfono (pref `mantra_counter_v1`). Nunca van a
/// Salud, a las estadísticas, al servidor, a la analítica ni a la
/// exportación, y nunca se escriben en el registro.
///
/// Hay un solo contador por proceso ([instance]). Al cambiar o borrar la
/// cuenta, [clearForAccountChange] borra todo y ningún guardado pendiente de
/// la cuenta anterior vuelve a escribir (R89).
class MantraCounterStore extends ChangeNotifier {
  MantraCounterStore({
    int Function()? clock,
    Future<SharedPreferences> Function()? prefs,
    this.saveDelay = const Duration(seconds: 1),
  }) : _clock = clock ?? _monotonicNow,
       _prefs = prefs ?? SharedPreferences.getInstance;

  /// El contador del proceso. Las pruebas pueden cambiarlo.
  static MantraCounterStore instance = MantraCounterStore();

  /// Cuentas por vuelta si la organización no dice otra cosa.
  static const defaultBeadsPerRound = 108;

  /// Toques más juntos que esto se ignoran (dos toques accidentales).
  static const minTapGap = Duration(milliseconds: 150);

  /// Límite de «Sumar cuentas» en una sola vez.
  static const maxManualAdd = 1000000;

  // Cambia con cada cambio de cuenta: un guardado programado antes ya no
  // escribe. Es de todo el proceso, así que vale para cualquier instancia.
  static int _generation = 0;

  // Reloj que solo avanza: un cambio de hora del teléfono no lo mueve.
  static final _monotonic = Stopwatch()..start();
  static int _monotonicNow() => _monotonic.elapsedMilliseconds;

  final int Function() _clock;
  final Future<SharedPreferences> Function() _prefs;

  /// Espera entre el último cambio y el guardado.
  final Duration saveDelay;

  int _count = 0;
  int _rounds = 0;
  bool _totalEnabled = false;
  int _total = 0;
  int? _lastTapMs;
  bool _loaded = false;
  bool _dirty = false;
  Timer? _saveTimer;
  Future<void>? _loading;

  int get count => _count;
  int get rounds => _rounds;
  bool get totalEnabled => _totalEnabled;
  int get total => _total;
  bool get isLoaded => _loaded;

  /// Borra el contador al cambiar o borrar la cuenta (R89). Primero cambia la
  /// generación y cancela el guardado pendiente; después borra la memoria y el
  /// dato guardado. Una pantalla abierta vuelve a cero.
  static Future<void> clearForAccountChange() =>
      instance._clearForAccountChange();

  Future<void> _clearForAccountChange() async {
    _generation++;
    _saveTimer?.cancel();
    _saveTimer = null;
    _dirty = false;
    _count = 0;
    _rounds = 0;
    _totalEnabled = false;
    _total = 0;
    _lastTapMs = null;
    // Una carga que estaba en curso ya no aplica: la memoria queda en cero.
    _loaded = true;
    notifyListeners();
    try {
      final prefs = await _prefs();
      await prefs.remove(SharedPreferenceConstants.mantraCounter);
    } catch (error) {
      // Sin cuentas en el mensaje: solo el tipo de error.
      AppLogger.w(
        'MANTRA',
        'No se pudo borrar el contador: ${error.runtimeType}',
      );
    }
  }

  /// Lee lo guardado. Un dato dañado cuenta como cero. Si la organización
  /// bajó las cuentas por vuelta, la cuenta queda en `beadsPerRound - 1`.
  Future<void> load({int beadsPerRound = defaultBeadsPerRound}) {
    if (_loaded) {
      clampTo(beadsPerRound);
      return Future.value();
    }
    return _loading ??= _load(
      beadsPerRound,
    ).whenComplete(() => _loading = null);
  }

  Future<void> _load(int beadsPerRound) async {
    final generation = _generation;
    String? raw;
    try {
      raw = (await _prefs()).getString(SharedPreferenceConstants.mantraCounter);
    } catch (error) {
      AppLogger.w(
        'MANTRA',
        'No se pudo leer el contador: ${error.runtimeType}',
      );
    }
    // La cuenta cambió mientras se leía: la memoria ya quedó en cero.
    if (generation != _generation || _loaded) {
      clampTo(beadsPerRound);
      return;
    }
    final saved = _decode(raw);
    _count = saved.count;
    _rounds = saved.rounds;
    _totalEnabled = saved.totalEnabled;
    _total = saved.total;
    _loaded = true;
    _clamp(beadsPerRound);
    notifyListeners();
  }

  static ({int count, int rounds, bool totalEnabled, int total}) _decode(
    String? raw,
  ) {
    const zero = (count: 0, rounds: 0, totalEnabled: false, total: 0);
    if (raw == null) return zero;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return zero;
      int read(String key) {
        final value = json[key];
        return value is int && value >= 0 ? value : 0;
      }

      return (
        count: read('count'),
        rounds: read('rounds'),
        totalEnabled: json['totalEnabled'] == true,
        total: read('total'),
      );
    } catch (_) {
      return zero;
    }
  }

  /// Ajusta la cuenta si la organización cambió las cuentas por vuelta.
  void clampTo(int beadsPerRound) {
    if (_clamp(beadsPerRound)) {
      _scheduleSave();
      notifyListeners();
    }
  }

  bool _clamp(int beadsPerRound) {
    final limit = _validBeads(beadsPerRound) - 1;
    if (_count <= limit) return false;
    _count = limit;
    return true;
  }

  static int _validBeads(int beadsPerRound) =>
      beadsPerRound < 1 ? defaultBeadsPerRound : beadsPerRound;

  /// Una cuenta. Al llegar a [beadsPerRound] suma una vuelta y la cuenta
  /// vuelve a cero. Un toque a menos de 150 ms del anterior no cuenta.
  BeadResult bead(int beadsPerRound) {
    // Antes de leer lo guardado no se cuenta: se perdería lo anterior.
    if (!_loaded) return BeadResult.ignored;
    final now = _clock();
    final last = _lastTapMs;
    if (last != null && now - last < minTapGap.inMilliseconds) {
      return BeadResult.ignored;
    }
    _lastTapMs = now;
    final beads = _validBeads(beadsPerRound);
    _clamp(beads);
    _count++;
    if (_totalEnabled) _total++;
    var result = BeadResult.bead;
    if (_count >= beads) {
      _count = 0;
      _rounds++;
      result = BeadResult.round;
    }
    _scheduleSave();
    notifyListeners();
    return result;
  }

  /// «Empezar de cero»: cuenta y vueltas en cero; el total no cambia.
  void reset() {
    if (!_loaded) return;
    _count = 0;
    _rounds = 0;
    _lastTapMs = null;
    _changed();
  }

  /// «Llevar mi total». Apagarlo conserva el total por si se vuelve a
  /// encender; «Borrar mi total» lo borra.
  void setTotalEnabled(bool enabled) {
    if (!_loaded || _totalEnabled == enabled) return;
    _totalEnabled = enabled;
    _changed();
  }

  /// «Sumar cuentas» hechas fuera de la app (por ejemplo con una mala).
  /// Solo con el total encendido y de 1 a 1 000 000 por vez.
  bool addToTotal(int n) {
    if (!_totalEnabled || n < 1 || n > maxManualAdd) return false;
    _total += n;
    _changed();
    return true;
  }

  /// «Borrar mi total»: total en cero y apagado.
  void clearTotal() {
    if (!_loaded) return;
    _total = 0;
    _totalEnabled = false;
    _changed();
  }

  void _changed() {
    _scheduleSave();
    notifyListeners();
  }

  void _scheduleSave() {
    _dirty = true;
    _saveTimer?.cancel();
    final generation = _generation;
    _saveTimer = Timer(saveDelay, () {
      _saveTimer = null;
      unawaited(_save(generation));
    });
  }

  /// Guarda ya lo pendiente (al salir de la pantalla o al ir a segundo
  /// plano).
  Future<void> flush() {
    final pending = _saveTimer;
    if (pending == null && !_dirty) return Future.value();
    pending?.cancel();
    _saveTimer = null;
    return _save(_generation);
  }

  Future<void> _save(int generation) async {
    if (generation != _generation || !_dirty) return;
    try {
      final prefs = await _prefs();
      // La cuenta cambió mientras se esperaba: este guardado ya no es suyo.
      if (generation != _generation || !_dirty) return;
      final raw = jsonEncode({
        'count': _count,
        'rounds': _rounds,
        'totalEnabled': _totalEnabled,
        'total': _total,
      });
      _dirty = false;
      final saved = await prefs.setString(
        SharedPreferenceConstants.mantraCounter,
        raw,
      );
      if (!saved && generation == _generation) _dirty = true;
    } catch (error) {
      if (generation == _generation) _dirty = true;
      AppLogger.w(
        'MANTRA',
        'No se pudo guardar el contador: ${error.runtimeType}',
      );
    }
  }

  /// Estado inicial para las pruebas (no toca la generación).
  @visibleForTesting
  static void resetForTesting() {
    instance._saveTimer?.cancel();
    instance = MantraCounterStore();
  }
}
