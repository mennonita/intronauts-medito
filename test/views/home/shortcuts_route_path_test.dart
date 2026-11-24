import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/models/home/shortcuts/shortcuts_model.dart';
import 'package:medito/models/local_all_stats.dart';
import 'package:medito/providers/stats_provider.dart';
import 'package:medito/routes/routes.dart';
import 'package:medito/views/home/widgets/shortcuts/shortcuts_items_widget.dart';
import 'package:medito/views/timer/timer_view.dart';
import 'package:medito/views/track/track_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Stats extends StatsNotifier {
  @override
  Future<LocalAllStats> build() async => LocalAllStats.empty();

  @override
  Future<void> refresh() async {}
}

class _RouteObserver extends NavigatorObserver {
  MaterialPageRoute<bool>? lastPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is MaterialPageRoute<bool>) lastPush = route;
  }
}

void main() {
  testWidgets('Repetir envía la ruta completa con la consulta', (tester) async {
    final timer =
        await _tapShortcut(
              tester,
              type: TypeConstants.route,
              path: 'timer/start?last=1',
            )
            as TimerView;

    expect(timer.launch?.last, isTrue);
    expect(timer.source, AnalyticsEventConstants.sourceShortcut);
  });

  testWidgets('un atajo de pista envía solo el identificador', (tester) async {
    final track =
        await _tapShortcut(
              tester,
              type: TypeConstants.track,
              path: 'tracks/meditacion',
            )
            as TrackView;

    expect(track.trackId, 'meditacion');
  });
}

Future<Widget> _tapShortcut(
  WidgetTester tester, {
  required String type,
  required String path,
}) async {
  SharedPreferences.setMockInitialValues({});
  final observer = _RouteObserver();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [statsProvider.overrideWith(_Stats.new)],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [observer],
        home: Scaffold(
          body: ShortcutsItemsWidget(
            data: [
              ShortcutsModel(
                id: 'atajo',
                type: type,
                title: 'Atajo',
                path: path,
                icon: null,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.byType(InkWell));
  final route = observer.lastPush!;
  final destination = route.builder(navigatorKey.currentContext!);
  navigatorKey.currentState!.removeRoute(route);
  return destination;
}
