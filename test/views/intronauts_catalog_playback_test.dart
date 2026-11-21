import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/http/http_constants.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/models/track/track.dart';
import 'package:medito/models/pack/pack_model.dart';
import 'package:medito/models/player/playback_request.dart';
import 'package:medito/providers/meditation/track_provider.dart';
import 'package:medito/providers/pack/pack_provider.dart';
import 'package:medito/providers/player/player_provider.dart';
import 'package:medito/utils/track_variant_selector.dart';
import 'package:medito/views/onboarding/onboarding_result_screen.dart';
import 'package:medito/views/previews/preview_support.dart';
import 'package:medito/views/track/track_view.dart';

const _track = Track(
  id: 'catalog-track',
  title: 'Track from catalog',
  description: 'Keep this description',
  coverUrl: '',
  isPublished: true,
  hasBackgroundSound: false,
);

const _playable = TrackVoice(
  guideName: 'Guía',
  audioFiles: [
    TrackAudioFile(
      id: 'file',
      path: 'https://example.invalid/audio.mp3',
      duration: 60000,
    ),
  ],
);

const _pack = PackModel(
  id: 'catalog-pack',
  title: 'Catalog pack',
  items: [
    PackItemsModel(
      type: 'url',
      id: 'ignored',
      title: 'Not a track',
      path: '/ignored',
    ),
    PackItemsModel(
      type: 'track',
      id: 'catalog-track',
      title: 'Catalog track',
      path: '/tracks/catalog-track',
    ),
    PackItemsModel(
      type: 'track',
      id: 'later-track',
      title: 'Later track',
      path: '/tracks/later-track',
    ),
  ],
);

class _CatalogTrack extends Tracks {
  _CatalogTrack(this.track);
  final Track track;

  @override
  Future<Track> build({required String trackId}) async => track;
}

class _RecordingPlayer extends PlayerProvider {
  PlaybackRequest? request;

  @override
  Future<void> play(PlaybackRequest request) async => this.request = request;
}

void main() {
  test('selector skips empty voices and returns null for empty audio', () {
    expect(TrackVariantSelector.resolve(_track), isNull);
    final result = TrackVariantSelector.resolve(
      _track.copyWith(
        voices: [
          const TrackVoice(guideName: 'missing'),
          _playable,
        ],
      ),
      guideName: 'missing',
    );
    expect(result?.file.id, 'file');
    expect(result?.voice.guideName, 'Guía');
  });

  test('onboarding pins the first pack in catalog order', () async {
    final container = ProviderContainer(
      overrides: [
        packCatalogProvider.overrideWith(
          (ref) async => [
            _pack,
            const PackModel(id: 'another-pack', title: 'Another pack'),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      (await container.read(onboardingPackProvider.future))?.id,
      'catalog-pack',
    );
  });

  test('mock mode provides a starter pack and playable first track', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final pack = await container.read(onboardingPackProvider.future);
    final item = pack!.items.firstWhere((item) => item.type == 'track');
    final track = await container.read(tracksProvider(trackId: item.id).future);
    expect(TrackVariantSelector.resolve(track), isNotNull);
  }, skip: !isMockMode);

  testWidgets(
    'Spanish track page keeps details and hides playback for empty audio',
    (tester) async {
      await tester.pumpWidget(
        PreviewShell(
          locale: const Locale('es'),
          prefs: prefsDark,
          overrides: [
            tracksProvider(
              trackId: _track.id,
            ).overrideWith(() => _CatalogTrack(_track)),
          ],
          child: TrackView(trackId: _track.id),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text(_track.title), findsOneWidget);
      expect(
        find.text('Esta meditación todavía no está disponible.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final hasPack in [true, false]) {
    testWidgets('onboarding uses the first catalog track (pack: $hasPack)', (
      tester,
    ) async {
      final player = _RecordingPlayer();
      await tester.pumpWidget(
        PreviewShell(
          prefs: prefsDark,
          overrides: [
            packCatalogProvider.overrideWith(
              (ref) async => hasPack ? [_pack] : [],
            ),
            tracksProvider(trackId: 'catalog-track').overrideWith(
              () => _CatalogTrack(_track.copyWith(voices: [_playable])),
            ),
            playerProvider.overrideWith(() => player),
          ],
          child: const Scaffold(
            body: OnboardingResultScreen(
              state: OnboardingResultState.stateA,
              showMeditation: true,
              onGetStarted: _getStarted,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final start = find.text('Start');
      expect(start, hasPack ? findsOneWidget : findsNothing);
      if (hasPack) {
        await tester.ensureVisible(start);
        await tester.tap(start);
        await tester.pump();
        expect(player.request?.trackId, 'catalog-track');
      } else {
        expect(find.text('Get started'), findsOneWidget);
      }
    });
  }
}

void _getStarted() {}
