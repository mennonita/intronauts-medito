// Revisa que los textos de los avisos inviten sin culpa (F3 «Avisos sin culpa»):
// sin emoji, sin contar el tiempo fuera, sin palabras de racha o presión,
// sin género para quien lee y sin promesas de salud.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:medito/l10n/app_localizations_es.dart';

const _locales = ['es', 'en', 'de'];

const _variantDays = [1, 2, 3];
const _variantCount = 5;
const _singleDays = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 30];

const _maxTitleLength = 40;
const _maxBodyLength = 90;

// Subcadenas prohibidas por idioma (se comparan en minúsculas).
const _bannedByLocale = <String, List<String>>{
  'es': [
    // Contar el tiempo fuera.
    'días', 'semana', 'mes', 'han pasado', 'ha pasado', 'desde que', 'hace ',
    'llevas', 'casi',
    // Racha o presión.
    'racha', 'impulso', 'hábito', 'construye', 'constancia', 'seguido',
    'revisión', 'reinici', 'camino', 'progreso', 'meta', 'logro', 'tú puedes',
    'no pierdas',
    // Género de quien lee.
    'listo', 'lista', 'preparado', 'preparada', 'cansado', 'cansada',
    'bienvenido', 'bienvenida',
    // Promesas de salud o resultado.
    'te ayuda', 'mejor', 'estrés', 'ansiedad',
  ],
  'en': [
    'day', 'week', 'month', 'since', "it's been", ' ago',
    'streak', 'momentum', 'habit', 'check-in', 'restart', 'reset', 'progress',
    'goal', 'you can', 'back on track',
    'help you', 'better', 'stress', 'anxiety',
  ],
  'de': [
    'tag', 'woche', 'monat', 'seit',
    'serie', 'gewohnheit', 'schwung', 'fortschritt', 'ziel', 'neustart',
    'du schaffst',
    'hilft', 'besser', 'stress', 'angst',
  ],
};

// «solo» y «sola» se revisan como palabra completa en español.
final _spanishAloneWord = RegExp(r'\b(solo|sola)\b', caseSensitive: false);

final _digit = RegExp(r'[0-9]');

List<String> _reminderKeys() {
  final keys = <String>[];
  for (final day in _variantDays) {
    for (var variant = 1; variant <= _variantCount; variant++) {
      keys.add('reminderDay${day}TitleVar$variant');
      keys.add('reminderDay${day}BodyVar$variant');
    }
  }
  for (final day in _singleDays) {
    keys.add('reminderDay${day}Title');
    keys.add('reminderDay${day}Body');
  }
  keys.addAll(const [
    'reminderNotificationTitle',
    'reminderNotificationBody',
    'notificationPreviewTitleB',
    'notificationPreviewBodyB',
  ]);
  return keys;
}

Map<String, dynamic> _loadArb(String locale) {
  final file = File('lib/l10n/app_$locale.arb');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

bool _isPictograph(int rune) {
  return (rune >= 0x1F000 && rune <= 0x1FAFF) ||
      (rune >= 0x2600 && rune <= 0x27BF) ||
      (rune >= 0x2B00 && rune <= 0x2BFF) ||
      rune == 0xFE0F;
}

bool _isTitleKey(String key) => key.contains('Title');

void main() {
  final keys = _reminderKeys();

  test('el botón de permiso dice Ahora no', () {
    expect(AppLocalizationsEs().notNow, 'Ahora no');
  });

  test('la lista cubre las 60 claves de avisos', () {
    expect(keys.length, 60);
    expect(keys.toSet().length, 60);
  });

  for (final locale in _locales) {
    group('avisos en $locale', () {
      final arb = _loadArb(locale);
      final banned = _bannedByLocale[locale]!;

      test('existen todas las claves', () {
        final missing = keys.where((key) => arb[key] is! String).toList();
        expect(missing, isEmpty, reason: 'faltan claves en app_$locale.arb');
      });

      test('cada texto cumple las reglas', () {
        final problems = <String>[];
        for (final key in keys) {
          final value = arb[key];
          if (value is! String) continue;
          final lower = value.toLowerCase();

          if (value.trim() != value) {
            problems.add('$key: espacios al inicio o al final');
          }
          if (value.runes.any(_isPictograph)) {
            problems.add('$key: trae emoji o pictograma');
          }
          if (_digit.hasMatch(value)) {
            problems.add('$key: trae un número');
          }
          for (final word in banned) {
            if (lower.contains(word)) {
              problems.add('$key: trae «$word»');
            }
          }
          if (locale == 'es' && _spanishAloneWord.hasMatch(value)) {
            problems.add('$key: usa «solo» o «sola»');
          }
          final limit = _isTitleKey(key) ? _maxTitleLength : _maxBodyLength;
          if (value.runes.length > limit) {
            problems.add('$key: mide ${value.runes.length}, máximo $limit');
          }
        }
        expect(problems, isEmpty, reason: problems.join('\n'));
      });

      test('los días con variantes no repiten textos', () {
        for (final day in _variantDays) {
          final titles = <String>[];
          final bodies = <String>[];
          for (var variant = 1; variant <= _variantCount; variant++) {
            titles.add(arb['reminderDay${day}TitleVar$variant'] as String);
            bodies.add(arb['reminderDay${day}BodyVar$variant'] as String);
          }
          expect(titles.toSet().length, _variantCount,
              reason: 'títulos repetidos en el día $day');
          expect(bodies.toSet().length, _variantCount,
              reason: 'cuerpos repetidos en el día $day');
        }
      });
    });
  }
}
