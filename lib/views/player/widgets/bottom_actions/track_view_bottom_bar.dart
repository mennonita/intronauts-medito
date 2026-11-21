import 'package:medito/constants/colors/color_constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io' show Platform;

import 'package:medito/constants/icons/medito_icons.dart';
import 'dart:async';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/providers/providers.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../models/favorites/favorite_item.dart';
import '../../../../models/track/track.dart';
import '../../../../providers/favorites/favorites_provider.dart';
import '../../../../providers/meditation/track_provider.dart';
import '../../../../widgets/add_to_siri_util.dart';
import '../../../../widgets/medito_icon.dart';
import '../../../../scaffold_messenger_key.dart';
import '../../../../widgets/snackbar_widget.dart';
import 'animated_favourite_icon.dart';
import 'bottom_action_bar.dart';

class TrackViewBottomBar extends ConsumerStatefulWidget {
  final String trackId;
  final String trackTitle;
  final String? coverUrl;
  final VoidCallback onBackPressed;

  const TrackViewBottomBar({
    super.key,
    required this.trackId,
    required this.trackTitle,
    this.coverUrl,
    required this.onBackPressed,
  });

  @override
  ConsumerState<TrackViewBottomBar> createState() => _TrackViewBottomBarState();
}

class _TrackViewBottomBarState extends ConsumerState<TrackViewBottomBar> {
  final _favoriteController = FavoriteIconController();

  @override
  void dispose() {
    _favoriteController.dispose();
    super.dispose();
  }

  void _toggleFavorite(bool isFavorite, Track track) {
    final notifier = ref.read(favoritesNotifierProvider.notifier);
    unawaited(
      ref
          .read(analyticsServiceProvider)
          .logEvent(
            name: isFavorite
                ? AnalyticsEventConstants.trackUnfavourited
                : AnalyticsEventConstants.trackFavourited,
            parameters: {AnalyticsEventConstants.paramTrackId: widget.trackId},
          ),
    );
    _favoriteController
        .trigger(
          () => isFavorite
              ? notifier.removeFromFavorites(widget.trackId)
              : notifier.addToFavorites(
                  FavoriteItem(
                    id: widget.trackId,
                    title: widget.trackTitle,
                    coverUrl: widget.coverUrl ?? track.coverUrl,
                    subtitle: track.subtitle,
                    type: FavoriteItemType.track,
                    timestamp: DateTime.now().millisecondsSinceEpoch,
                  ),
                ),
          direction: isFavorite
              ? FavoriteToggleDirection.remove
              : FavoriteToggleDirection.add,
        )
        .then((_) {
          // The star alone is easy to miss; say what happened.
          if (!mounted) return;
          final l10n = AppLocalizations.of(context)!;
          // Replace rather than queue, so a quick re-tap reads the end state.
          scaffoldMessengerKey.currentState?.hideCurrentSnackBar();
          showSnackBar(
            context,
            isFavorite ? l10n.removedFromFavorites : l10n.addedToFavorites,
          );
        });
  }

  @override
  Widget build(BuildContext context) {
    final trackState = ref.watch(tracksProvider(trackId: widget.trackId));
    final favoritesState = ref.watch(favoritesNotifierProvider);

    const dailyMeditationId = 'BmTFAyYt8jVMievZ'; // from back end :(
    final isDailyMeditation = widget.trackId == dailyMeditationId;

    return trackState.when(
      data: (track) {
        return favoritesState.when(
          data: (favorites) {
            final isFavorite = favorites.any(
              (item) => item.id == widget.trackId,
            );
            return _buildBottomBar(
              context,
              track,
              isFavorite,
              isDailyMeditation,
            );
          },
          loading: () =>
              _buildBottomBar(context, track, false, isDailyMeditation),
          error: (error, stack) =>
              _buildBottomBar(context, track, false, isDailyMeditation),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }

  Widget _buildBottomBar(
    BuildContext context,
    Track track,
    bool isFavorite,
    bool isDailyMeditation,
  ) {
    final colour = isFavorite
        ? context.brandAccent
        : Theme.of(context).colorScheme.onSurface;

    final l10n = AppLocalizations.of(context)!;

    return BottomActionBar(
      layout: BottomActionBarLayout.compactRight,
      leftItem: BottomActionBarItem(
        child: MeditoIcon(
          assetName: MeditoIcons.arrowLeft,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        onTap: widget.onBackPressed,
        semanticLabel: l10n.goBack,
      ),
      rightCenterItem: Platform.isIOS
          ? BottomActionBarItem(
              child: MeditoIcon(
                assetName: MeditoIcons.siri,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              onTap: () => addToSiri(
                title: '${l10n.open} ${widget.trackTitle}',
                id: widget.trackId,
                url: 'org.meditofoundation://tracks/${widget.trackId}',
              ),
              semanticLabel: l10n.addToSiri,
            )
          : null,
      rightItem: isDailyMeditation
          ? null
          : BottomActionBarItem(
              child: AnimatedFavouriteIcon(
                isFavorite: isFavorite,
                color: colour,
                controller: _favoriteController,
              ),
              semanticLabel: isFavorite
                  ? l10n.removeFromFavorites
                  : l10n.addToFavorites,
              onTap: () => _toggleFavorite(isFavorite, track),
            ),
    );
  }
}
