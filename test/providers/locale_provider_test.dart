import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/providers/locale_provider.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _container(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('sin idioma guardado, la app queda en español', () async {
    final c = await _container({});
    expect(c.read(localeProvider), const Locale('es'));
  });

  test('con «sistema» guardado, la app queda en español', () async {
    final c = await _container(
      {SharedPreferenceConstants.localePreference: 'system'},
    );
    expect(c.read(localeProvider), const Locale('es'));
  });

  test('un idioma elegido a mano se respeta', () async {
    final c = await _container(
      {SharedPreferenceConstants.localePreference: 'en'},
    );
    expect(c.read(localeProvider), const Locale('en'));
    await c.read(localeProvider.notifier).setLocale('de');
    expect(c.read(localeProvider), const Locale('de'));
  });
}
