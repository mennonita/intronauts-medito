import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/models/background_sounds/background_sounds_model.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/repositories/background_sounds/background_sounds_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<BackgroundSoundsRepository> repoWith(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final instance = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(instance)],
    );
    addTearDown(container.dispose);
    // Auto-disposed provider: keep it alive across the awaits below.
    container.listen(backgroundSoundsRepositoryProvider, (_, _) {});
    return container.read(backgroundSoundsRepositoryProvider);
  }

  test('bells default on for the timer and off under tracks', () async {
    final repo = await repoWith({});
    expect(repo.getSessionBellsEnabled(forTimer: true), isTrue);
    expect(repo.getSessionBellsEnabled(), isFalse);
    expect(repo.getSelectedBgSoundFromSharedPreferences(), isNull);
  });

  test('bells picked as the background sound migrate to the switch', () async {
    final repo = await repoWith({
      SharedPreferenceConstants.bgSound: jsonEncode(
        kSessionBellsSound.toJson(),
      ),
    });
    expect(repo.getSessionBellsEnabled(), isTrue);
    expect(repo.getSelectedBgSoundFromSharedPreferences(), isNull);
  });

  test(
    'timer bells ignore a saved false and timer writes are ignored',
    () async {
      final repo = await repoWith({
        SharedPreferenceConstants.timerSessionBellsEnabled: false,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(repo.getSessionBellsEnabled(forTimer: true), isTrue);
      repo.saveSessionBellsEnabled(true, forTimer: true);
      expect(
        prefs.getBool(SharedPreferenceConstants.timerSessionBellsEnabled),
        isFalse,
      );
      expect(repo.getSessionBellsEnabled(), isFalse);
    },
  );

  test('guided sessions still save both switch values', () async {
    final repo = await repoWith({});
    repo.saveSessionBellsEnabled(true);
    expect(repo.getSessionBellsEnabled(), isTrue);
    repo.saveSessionBellsEnabled(false);
    expect(repo.getSessionBellsEnabled(), isFalse);
    expect(repo.getSessionBellsEnabled(forTimer: true), isTrue);
  });
}
