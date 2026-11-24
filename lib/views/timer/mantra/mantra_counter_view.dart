import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/icons/medito_icons.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/models/timer/timer_house_content.dart';
import 'package:medito/providers/timer/timer_content_provider.dart';
import 'package:medito/services/timer/mantra_counter_store.dart';
import 'package:medito/services/timer/timer_device_channel.dart';
import 'package:medito/widgets/medito_icon.dart';

import 'mantra_total_sheet.dart';

/// «Contador de mantras» (F2): toda la pantalla es un solo botón que cuenta
/// una cuenta por toque. Solo hay toques sencillos: aquí no existe el doble
/// toque ni el toque largo (regla del dueño).
///
/// Privacidad: las cuentas se quedan en el teléfono. Esta pantalla no manda
/// analítica, no toca Salud, las estadísticas ni el servidor, y no escribe
/// cuentas en el registro.
class MantraCounterView extends ConsumerStatefulWidget {
  const MantraCounterView({super.key});

  @override
  ConsumerState<MantraCounterView> createState() => _MantraCounterViewState();
}

class _MantraCounterViewState extends ConsumerState<MantraCounterView> {
  late final MantraCounterStore _store;
  late final AppLifecycleListener _lifecycle;
  bool _hasTapped = false;

  @override
  void initState() {
    super.initState();
    _store = MantraCounterStore.instance;
    _store.addListener(_onStoreChanged);
    // Al ir a segundo plano se guarda de inmediato.
    _lifecycle = AppLifecycleListener(
      onHide: _flush,
      onPause: _flush,
      onDetach: _flush,
    );
    unawaited(TimerDeviceChannel.keepScreenOn(true));
    unawaited(
      _store.load(
        beadsPerRound: ref.read(timerHouseContentProvider).beadsPerRound,
      ),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _store.removeListener(_onStoreChanged);
    _flush();
    unawaited(TimerDeviceChannel.keepScreenOn(false));
    super.dispose();
  }

  void _flush() => unawaited(_store.flush());

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _count(int beadsPerRound) {
    final result = _store.bead(beadsPerRound);
    if (result == BeadResult.ignored) return;
    if (!_hasTapped) setState(() => _hasTapped = true);
    if (result == BeadResult.round) {
      // Vuelta completa: vibración fuerte.
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        unawaited(HapticFeedback.heavyImpact());
      } else {
        unawaited(TimerDeviceChannel.vibrateBell(1));
      }
      final l10n = AppLocalizations.of(context)!;
      unawaited(
        SemanticsService.sendAnnouncement(
          View.of(context),
          l10n.mantraCounterRounds(_store.rounds),
          Directionality.of(context),
        ),
      );
    } else {
      unawaited(HapticFeedback.lightImpact());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final content = ref.watch(timerHouseContentProvider);
    final beadsPerRound = content.beadsPerRound;
    // Si la organización bajó las cuentas por vuelta, la cuenta se ajusta.
    ref.listen<int>(
      timerHouseContentProvider.select((content) => content.beadsPerRound),
      (_, beads) => _store.clampTo(beads),
    );
    final count = _store.count < beadsPerRound
        ? _store.count
        : beadsPerRound - 1;
    final beadsText = l10n.mantraCounterBeads(count, beadsPerRound);
    final mutedColor = theme.colorScheme.onSurface.withValues(alpha: 0.7);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        leading: IconButton(
          tooltip: l10n.goBack,
          icon: MeditoIcon(
            assetName: MeditoIcons.arrowLeft,
            color: theme.colorScheme.onSurface,
          ),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(
          houseWord(content, HouseWord.counter, l10n.mantraCounterTitle),
        ),
        actions: [
          IconButton(
            tooltip: l10n.mantraCounterMenu,
            icon: const Icon(Icons.more_vert),
            onPressed: () => showMantraTotalSheet(context, _store),
          ),
        ],
      ),
      body: Semantics(
        container: true,
        value: beadsText,
        onTap: () => _count(beadsPerRound),
        onTapHint: l10n.mantraCounterTapAction,
        child: GestureDetector(
          key: const ValueKey('mantra-tap-area'),
          behavior: HitTestBehavior.opaque,
          // La acción de lectores de pantalla la da el Semantics de arriba.
          excludeFromSemantics: true,
          onTap: () => _count(beadsPerRound),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ExcludeSemantics(
                            child: Text(
                              beadsText,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.displayMedium,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.mantraCounterRounds(_store.rounds),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium,
                          ),
                          if (_store.totalEnabled) ...[
                            const SizedBox(height: 8),
                            Text(
                              l10n.mantraTotalValue(_store.total),
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: mutedColor,
                              ),
                            ),
                          ],
                          if (!_hasTapped) ...[
                            const SizedBox(height: 24),
                            Text(
                              l10n.mantraCounterHint,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: mutedColor,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Text(
                    l10n.mantraPrivacyNote,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: mutedColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
