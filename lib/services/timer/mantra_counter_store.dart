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
/// cuenta, y al cerrar sesión, [clearForAccountChange] borra todo y ningún
/// guardado pendiente de la cuenta anterior vuelve a escribir (R89).
///
/// Lo guardado lleva a su dueño: la identidad persistente de este teléfono
/// (`userId`, la misma que vincula `PlaybackAccount`). Si al leer el dueño es
/// otro, se borra antes de mostrar nada, aunque el cambio de cuenta haya
/// pasado con la app cerrada (MANTRA-01).
class MantraCounterStore extends ChangeNotifier {
  MantraCounterStore({
    int Function()? clock,
    Future<SharedPreferences> Function()? prefs,
    String Function(SharedPreferences prefs)? owner,
    this.saveDelay = const Duration(seconds: 1),
  }) : _clock = clock ?? _monotonicNow,
       _prefs = prefs ?? SharedPreferences.getInstance,
       _ownerOf = owner ?? _storedOwner;

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
  final String Function(SharedPreferences prefs) _ownerOf;

  /// Dueño de las cuentas: la identidad guardada en este teléfono. Cambia al
  /// entrar con otra cuenta y se borra al eliminar la cuenta. Sin identidad
  /// todavía, el dueño es `''`.
  static String _storedOwner(SharedPreferences prefs) =>
      prefs.getString(SharedPreferenceConstants.userId) ?? '';

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

  // Dueño de lo que hay en memoria. `null` = nada leído todavía (o recién
  // borrado): el primer guardado lo toma del dueño actual.
  String? _dataOwner;

  int get count => _count;
  int get rounds => _rounds;
  bool get totalEnabled => _totalEnabled;
  int get total => _total;
  bool get isLoaded => _loaded;

  /// Borra el contador al cambiar o borrar la cuenta y al cerrar sesión
  /// (R89, MANTRA-01). Primero cambia la generación y cancela el guardado
  /// pendiente; después borra la memoria y el dato guardado. Una pantalla
  /// abierta vuelve a cero.
  ///
  /// Lanza [StateError] si el teléfono no confirma el borrado: quien llama no
  /// debe seguir como si las cuentas ya no estuvieran.
  static Future<void> clearForAccountChange() =>
      instance._clearForAccountChange();

  Future<void> _clearForAccountChange() async {
    _generation++;
    _saveTimer?.cancel();
    _saveTimer = null;
    _dirty = false;
    _zeroMemory();
    _dataOwner = null;
    // Una carga que estaba en curso ya no aplica: la memoria queda en cero.
    _loaded = true;
    notifyListeners();
    if (!await _removeSaved()) {
      throw StateError('No se pudo borrar el contador de mantras');
    }
  }

  void _zeroMemory() {
    _count = 0;
    _rounds = 0;
    _totalEnabled = false;
    _total = 0;
    _lastTapMs = null;
  }

  /// Borra lo guardado. `true` solo si el teléfono confirmó el borrado.
  Future<bool> _removeSaved() async {
    try {
      final prefs = await _prefs();
      if (await prefs.remove(SharedPreferenceConstants.mantraCounter)) {
        return true;
      }
      AppLogger.w('MANTRA', 'El teléfono no confirmó el borrado del contador');
    } catch (error) {
      // Sin cuentas en el mensaje: solo el tipo de error.
      AppLogger.w(
        'MANTRA',
        'No se pudo borrar el contador: ${error.runtimeType}',
      );
    }
    return false;
  }

  /// Lee lo guardado. Un dato dañado cuenta como cero. Si la organización
  /// bajó las cuentas por vuelta, la cuenta queda en `beadsPerRound - 1`.
  ///
  /// Cada vez revisa el dueño: lo guardado (o lo que hay en memoria) de otra
  /// identidad se borra antes de mostrarse (MANTRA-01).
  Future<void> load({int beadsPerRound = defaultBeadsPerRound}) {
    return _loading ??= _load(
      beadsPerRound,
    ).whenComplete(() => _loading = null);
  }

  Future<void> _load(int beadsPerRound) async {
    final generation = _generation;
    SharedPreferences? prefs;
    try {
      prefs = await _prefs();
    } catch (error) {
      AppLogger.w(
        'MANTRA',
        'No se pudo leer el contador: ${error.runtimeType}',
      );
    }
    // La cuenta cambió mientras se leía: la memoria ya quedó en cero.
    if (generation != _generation) {
      clampTo(beadsPerRound);
      return;
    }
    if (prefs == null) {
      // Sin preferencias no hay nada que mostrar: se empieza en cero.
      if (!_loaded) {
        _loaded = true;
        notifyListeners();
      }
      clampTo(beadsPerRound);
      return;
    }
    final owner = _ownerOf(prefs);
    if (_loaded) {
      final memoryOwner = _dataOwner;
      if (memoryOwner == null || memoryOwner == owner) {
        _dataOwner = owner;
        clampTo(beadsPerRound);
        return;
      }
      // La identidad cambió sin pasar por el borrado: lo que hay en memoria
      // es del dueño anterior y se borra antes de seguir.
      await _forgetForeign(generation, owner);
      if (generation == _generation) clampTo(beadsPerRound);
      return;
    }
    final saved = _decode(
      prefs.getString(SharedPreferenceConstants.mantraCounter),
      owner,
    );
    if (saved.foreign) {
      // Lo guardado es de otra identidad: se borra sin mostrarlo.
      await _forgetForeign(generation, owner);
      if (generation == _generation) clampTo(beadsPerRound);
      return;
    }
    _count = saved.count;
    _rounds = saved.rounds;
    _totalEnabled = saved.totalEnabled;
    _total = saved.total;
    _dataOwner = owner;
    _loaded = true;
    _clamp(beadsPerRound);
    notifyListeners();
  }

  /// Borra cuentas de otro dueño: la memoria primero (nunca se muestran) y
  /// luego lo guardado. Mientras se borra, los toques no cuentan; así nada
  /// nuevo se guarda antes del borrado.
  Future<void> _forgetForeign(int generation, String owner) async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _dirty = false;
    _zeroMemory();
    _loaded = false;
    notifyListeners();
    final removed = await _removeSaved();
    // Un borrado por cambio de cuenta llegó mientras tanto: ya dejó todo listo.
    if (generation != _generation) return;
    // Si el borrado no se confirmó, el dato viejo sigue con su dueño anterior:
    // la siguiente lectura lo vuelve a borrar y nunca se muestra.
    if (!removed) {
      AppLogger.w('MANTRA', 'Se reintentará borrar el contador de otro dueño');
    }
    _dataOwner = owner;
    _loaded = true;
    notifyListeners();
  }

  /// `foreign` = lo guardado es de otra identidad. Lo que no dice de quién
  /// es también cuenta como ajeno. Un dato dañado cuenta como cero.
  static ({int count, int rounds, bool totalEnabled, int total, bool foreign})
  _decode(String? raw, String owner) {
    const zero = (
      count: 0,
      rounds: 0,
      totalEnabled: false,
      total: 0,
      foreign: false,
    );
    if (raw == null) return zero;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return zero;
      if (json['owner'] != owner) {
        return (
          count: 0,
          rounds: 0,
          totalEnabled: false,
          total: 0,
          foreign: true,
        );
      }
      int read(String key) {
        final value = json[key];
        return value is int && value >= 0 ? value : 0;
      }

      return (
        count: read('count'),
        rounds: read('rounds'),
        totalEnabled: json['totalEnabled'] == true,
        total: read('total'),
        foreign: false,
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
      final owner = _ownerOf(prefs);
      final dataOwner = _dataOwner ??= owner;
      if (dataOwner != owner) {
        // La identidad cambió sin pasar por el borrado: estas cuentas son del
        // dueño anterior y nunca se guardan a nombre del nuevo (MANTRA-01).
        await _forgetForeign(generation, owner);
        return;
      }
      final raw = jsonEncode({
        'owner': owner,
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
