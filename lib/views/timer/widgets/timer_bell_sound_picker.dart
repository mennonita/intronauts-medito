import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/bell_sound.dart';
import 'package:medito/providers/background_sounds/background_sounds_notifier.dart';
import 'package:medito/services/account/playback_account.dart';
import 'package:medito/services/audio/session_bell_preview.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/widgets/radio_option_card.dart';

Future<void> showTimerBellSoundPicker(
  BuildContext context, {
  required BellSoundId selected,
  required ValueChanged<BellSoundId> onSelected,
}) async {
  final container = ProviderScope.containerOf(context);
  final preview = container.read(sessionBellPreviewProvider);
  final account = PlaybackAccount.generation;
  var open = true;
  Future<void> audition(BellSound sound) async {
    if (!open || !PlaybackAccount.isCurrent(account)) return;
    final volume = container.read(backgroundSoundsNotifierProvider).volume;
    final notifier = container.read(backgroundSoundsNotifierProvider.notifier);
    try {
      await preview.play(
        notifier.scaledVolume(volume),
        assetKey: sound.assetKey,
      );
    } catch (error, stack) {
      AppLogger.e('BELLS', 'No se pudo tocar la muestra', error, stack);
    }
  }

  try {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 1,
        builder: (context, scrollController) => StatefulBuilder(
          builder: (context, setState) {
            final theme = Theme.of(context);
            final l10n = AppLocalizations.of(context)!;
            return ListView.builder(
              controller: scrollController,
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom + 16,
              ),
              itemCount: bellSounds.length,
              itemBuilder: (context, index) {
                final sound = bellSounds[index];
                final name = sound.name(l10n);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      if (!open || !PlaybackAccount.isCurrent(account)) return;
                      setState(() => selected = sound.id);
                      onSelected(sound.id);
                      unawaited(audition(sound));
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          RadioDot(
                            selected: sound.id == selected,
                            accent: context.brandAccent,
                          ),
                          const SizedBox(width: padding12),
                          Expanded(
                            child: Text(
                              name,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.bellSoundPreview(name),
                            icon: const Icon(Icons.play_arrow_rounded),
                            onPressed: () => unawaited(audition(sound)),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  } finally {
    open = false;
    try {
      await preview.stop();
    } catch (error, stack) {
      AppLogger.e('BELLS', 'No se pudo detener la muestra', error, stack);
    }
  }
}
