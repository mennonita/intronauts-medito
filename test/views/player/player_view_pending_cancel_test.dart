import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/events/donation/donation_page_model.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/models/me/me_model.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/models/stripe/paywall_config_model.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/providers/donation/donation_page_provider.dart';
import 'package:medito/providers/providers.dart';
import 'package:medito/providers/review_service_provider.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/providers/stripe/payment_service_provider.dart';
import 'package:medito/services/review_service.dart';
import 'package:medito/views/home/previews/home_previews.dart';
import 'package:medito/views/player/player_view.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/firebase_analytics_test_helper.dart';
import '../../helpers/firebase_test_helper.dart';

const _welcome = PlaybackRequest(
  trackId: 'welcome',
  fileId: 'welcome-file',
  title: 'Welcome',
  description: '',
  coverUrl: '',
  remoteUrl: 'https://example.test/welcome.mp3',
  duration: 48024,
  hasBackgroundSound: false,
  guideName: 'Will',
);

const _otherSession = PlaybackRequest(
  trackId: 'other',
  fileId: 'other-file',
  title: 'Other',
  description: '',
  coverUrl: '',
  remoteUrl: 'https://example.test/other.mp3',
  duration: 60000,
  hasBackgroundSound: false,
);

/// Un inicio que espera el guardado del temporizador anterior; durante la
/// espera se cancela y el reproductor vuelve a la sesión viva (REV-01).
class _CancelledStartPlayer extends PlayerProvider {
  final loaded = Completer<void>();

  @override
  PlaybackRequest? build() => _welcome;

  @override
  Future<void> play(PlaybackRequest request) => loaded.future;

  @override
  void stop() {}

  @override
  void setSpeed(double speed) {}

  void cancelPendingStart() => state = _otherSession;
}

class _CountingBackgroundSounds extends BackgroundSoundsNotifier {
  int stops = 0;
  int restores = 0;

  @override
  void stopBackgroundSound() => stops++;

  @override
  void playBackgroundSoundFromPref() => restores++;
}

class _Stats extends StatsNotifier {
  @override
  Future<LocalAllStats> build() async => previewStats;
}

class _Review implements ReviewService {
  @override
  Future<void> checkAndRequestReview() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async => 0,
    );
    await FirebaseTestHelper.initializeFirebaseForTest();
    FirebaseAnalyticsTestHelper.setupFirebaseAnalyticsMocks();
  });

  testWidgets(
    'un inicio cancelado en la espera no toca el sonido de fondo de la sesión '
    'viva (REV-01)',
    (tester) async {
      final player = _CancelledStartPlayer();
      final sounds = _CountingBackgroundSounds();
      await tester.pumpWidget(
        PreviewShell(
          prefs: prefsDark,
          overrides: [
            playerProvider.overrideWith(() => player),
            audioStateProvider.overrideWith(AudioStateNotifier.new),
            backgroundSoundsNotifierProvider.overrideWith(() => sounds),
            statsProvider.overrideWith(_Stats.new),
            endScreenPaywallConfigProvider.overrideWith(
              (ref) => Completer<PaywallConfigModel>().future,
            ),
            reviewServiceProvider.overrideWithValue(_Review()),
            meProvider.overrideWith(
              (ref) async => const MeModel(id: 'test-user'),
            ),
            fetchDonationPageProvider.overrideWith(
              (ref) async => const DonationPageModel(
                title: 'Keep meditation free',
                text: 'Your support keeps Medito free.',
                buttons: [],
              ),
            ),
          ],
          child: const PlayerView(),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(sounds.stops, 0);

      // La espera termina después de que el inicio se canceló.
      player.cancelPendingStart();
      player.loaded.complete();
      await tester.pump();
      await tester.pump();

      expect(sounds.stops, 0);
      expect(sounds.restores, 0);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
