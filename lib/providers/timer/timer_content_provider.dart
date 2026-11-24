import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/repositories/timer/timer_content_repository.dart';
import 'package:medito/services/network/http_api_service.dart';

final timerContentRepositoryProvider = Provider<TimerContentRepository>(
  (ref) => TimerContentRepository(client: HttpApiService()),
);

final timerClosingTextProvider = FutureProvider.autoDispose<String?>(
  (ref) => ref.watch(timerContentRepositoryProvider).fetchClosingText(),
);
