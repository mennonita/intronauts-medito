import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/models/timer/timer_house_content.dart';
import 'package:medito/providers/shared_preference/shared_preference_provider.dart';
import 'package:medito/repositories/timer/timer_content_repository.dart';
import 'package:medito/services/network/http_api_service.dart';

final timerContentRepositoryProvider = Provider<TimerContentRepository>(
  (ref) => TimerContentRepository(
    client: HttpApiService(),
    prefs: ref.watch(sharedPreferencesProvider),
  ),
);

final timerHouseContentProvider =
    NotifierProvider<TimerHouseContentNotifier, TimerHouseContent>(
      TimerHouseContentNotifier.new,
    );

final timerClosingTextProvider = FutureProvider.autoDispose<String?>(
  (ref) => ref.watch(
    timerHouseContentProvider.select((content) => content.closingText),
  ),
);

class TimerHouseContentNotifier extends Notifier<TimerHouseContent> {
  @override
  TimerHouseContent build() {
    final repository = ref.watch(timerContentRepositoryProvider);
    final buildRef = ref;
    final binding = WidgetsBinding.instance;
    var refreshing = false;
    var listenerChange = 0;
    var visibilityCheckScheduled = false;
    var wasVisible = false;
    Timer? poll;

    void stopPolling() {
      poll?.cancel();
      poll = null;
    }

    Future<void> refresh() async {
      if (refreshing) return;
      refreshing = true;
      try {
        final result = await repository.fetchHouseContentWithStatus();
        if (buildRef.mounted) state = result.content;
        // Con respuesta del servidor ya no hace falta reintentar.
        if (result.fresh) stopPolling();
      } finally {
        refreshing = false;
      }
    }

    bool isVisible() {
      final lifecycle = binding.lifecycleState;
      return !buildRef.isPaused &&
          (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    }

    void checkVisibility([int change = 0]) {
      listenerChange += change;
      if (visibilityCheckScheduled) return;
      visibilityCheckScheduled = true;
      final alreadyRefreshing = refreshing;
      // Espera a que Riverpod termine de actualizar sus suscripciones.
      scheduleMicrotask(() {
        visibilityCheckScheduled = false;
        if (!buildRef.mounted) return;
        final visible = isVisible();
        // Al cerrar el contador, otra pantalla puede seguir usando el contenido.
        final shouldRefresh = visible && (!wasVisible || listenerChange < 0);
        listenerChange = 0;
        wasVisible = visible;

        if (!visible) {
          stopPolling();
          return;
        }
        if (shouldRefresh && !alreadyRefreshing) unawaited(refresh());
        if (!shouldRefresh) return;
        // Reintenta cada 30 s solo mientras el servidor no responda.
        poll ??= Timer.periodic(
          const Duration(seconds: 30),
          (_) => unawaited(refresh()),
        );
      });
    }

    final lifecycle = AppLifecycleListener(
      binding: binding,
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) {
          wasVisible = false;
          stopPolling();
        }
        checkVisibility();
      },
    );

    ref.onAddListener(() => checkVisibility(1));
    ref.onRemoveListener(() => checkVisibility(-1));
    ref.onResume(checkVisibility);
    ref.onCancel(checkVisibility);
    ref.onDispose(() {
      stopPolling();
      lifecycle.dispose();
    });

    unawaited(refresh());
    return repository.cachedHouseContent();
  }
}
