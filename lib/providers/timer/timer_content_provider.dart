import 'dart:async';

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
    final cached = repository.cachedHouseContent();
    unawaited(_refresh(repository, ref));
    return cached;
  }

  Future<void> _refresh(TimerContentRepository repository, Ref buildRef) async {
    final content = await repository.fetchHouseContent();
    if (buildRef.mounted) state = content;
  }
}
