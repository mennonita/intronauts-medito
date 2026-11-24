import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medito/constants/strings/analytics_event_constants.dart';
import 'package:medito/constants/strings/shared_preference_constants.dart';
import 'package:medito/constants/types/type_constants.dart';
import 'package:medito/l10n/app_localizations.dart';
import 'package:medito/app_globals.dart' show appReadyCompleter;
import 'package:medito/models/timer/timer_launch.dart';
import 'package:medito/providers/providers.dart';
import 'package:medito/routes/routes.dart';
import 'package:medito/routes/routes.dart' as routes show openTimerLaunch;
import 'package:medito/services/shop/fourthwall_service.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/widgets/snackbar_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeepLinkService {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  final WidgetRef ref;
  final BuildContext context;

  // Guards against the same URI being delivered twice in quick succession —
  // happens on Android when both `getInitialLink()` and `uriLinkStream` fire
  // for a cold-start intent, or on rapid double-taps of a home-screen widget.
  Uri? _lastHandledUri;
  DateTime? _lastHandledAt;
  // Si ese enlace abre una pantalla: el duplicado responde lo mismo.
  Future<bool> _lastHandledResult = Future.value(false);
  static const _dedupeWindow = Duration(milliseconds: 1500);

  // Completes once the initial link check finishes (hit or miss).
  // SplashView awaits this before applying stored UTM parameters to ensure
  // deferred deep links from Apple Search Ads are stored first.
  static Completer<void> _initialLinkCompleter = Completer<void>();
  static Future<void> get initialLinkProcessed => _initialLinkCompleter.future;

  /// El enlace con que se abrió la app lleva a una pantalla. Solo entonces
  /// gana sobre «Abrir la app en el temporizador»; un enlace que solo trae
  /// datos de campaña (UTM) o que no se reconoce no cuenta.
  static bool hadInitialLink = false;

  /// Vuelve al estado de un arranque nuevo (el completer queda atado a la
  /// zona de la prueba que lo creó).
  @visibleForTesting
  static void resetInitialLinkForTesting() {
    _initialLinkCompleter = Completer<void>();
    hadInitialLink = false;
  }

  DeepLinkService({required this.ref, required this.context});

  void initialize() {
    AppLogger.d('DEEPLINK', 'Setting up deep link handlers');

    _checkInitialLink();

    _linkSubscription = _appLinks.uriLinkStream.listen(
      (uri) {
        handleDeepLink(uri);
      },
      onError: (err) {
        AppLogger.e('DEEPLINK', 'Error from link stream', err);
      },
    );
  }

  Future<void> _checkInitialLink() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        hadInitialLink = await handleDeepLink(initialUri);
      }
    } catch (e) {
      AppLogger.e('DEEPLINK', 'Error checking initial link', e);
    } finally {
      if (!_initialLinkCompleter.isCompleted) {
        _initialLinkCompleter.complete();
      }
    }
  }

  // Espera a que termine la inicialización antes de abrir la pantalla.
  Future<void> _navigateWhenReady(Future<void> Function() navigate) async {
    await _waitUntilAppReady();

    if (!context.mounted) return;

    await navigate();
  }

  static Future<void> _waitUntilAppReady() async {
    try {
      await appReadyCompleter.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      AppLogger.w('DEEPLINK', 'App not ready after 15s, proceeding anyway');
    }
  }

  /// Abre el temporizador desde fuera de un enlace (botón de un aviso). Espera
  /// a la app igual que los enlaces y solo abre `TimerView`; la pantalla
  /// revisa si ya hay una sesión antes de empezar. Nunca reproduce aquí.
  static Future<void> openTimerLaunch(
    TimerLaunch launch, {
    required String source,
  }) async {
    await _waitUntilAppReady();
    await routes.openTimerLaunch(launch, source: source);
  }

  void dispose() {
    _linkSubscription?.cancel();
  }

  /// Devuelve true solo si el enlace abre una pantalla.
  Future<bool> handleDeepLink(Uri uri) async {
    final now = DateTime.now();
    if (_lastHandledUri == uri &&
        _lastHandledAt != null &&
        now.difference(_lastHandledAt!) < _dedupeWindow) {
      AppLogger.d(
        'DEEPLINK',
        'Ignoring duplicate deep link within dedupe window',
      );
      return _lastHandledResult;
    }
    _lastHandledUri = uri;
    _lastHandledAt = now;
    return _lastHandledResult = _handleNewDeepLink(uri);
  }

  Future<bool> _handleNewDeepLink(Uri uri) async {
    try {
      // Detect home-screen widget taps via the `source` query param so we can
      // attribute opens. Both iOS and Android widgets append
      // `?source=home_widget&widget=<type>` to their tap URIs.
      _logIfHomeWidgetTap(uri);

      // Extract and store UTM parameters before navigation
      await _storeUtmParameters(uri);

      final timerLaunch = TimerLaunch.fromUri(uri);
      if (timerLaunch != null) {
        unawaited(
          _navigateWhenReady(() => routes.openTimerLaunch(timerLaunch)),
        );
        return true;
      }

      var pathSegments = <String>[];

      if (uri.scheme == 'org.meditofoundation') {
        // For custom scheme, if host is "medito", use pathSegments directly
        // Otherwise, treat host as first path segment (e.g., org.meditofoundation://tracks/123)
        if (uri.host == 'medito') {
          pathSegments = uri.pathSegments;
        } else {
          pathSegments = [uri.host, ...uri.pathSegments];
        }
      } else if (uri.scheme == 'https' &&
          uri.host == FourthwallService.shopDomain) {
        unawaited(
          _navigateWhenReady(
            () => handleNavigation(
              TypeConstants.url,
              [uri.toString()],
              context,
              ref: ref,
            ),
          ),
        );
        return true;
      } else if (uri.scheme == 'https' && uri.host == 'medito.app') {
        pathSegments = uri.pathSegments;
      } else {
        if (context.mounted) {
          final localizations = AppLocalizations.of(context);
          if (localizations != null) {
            showSnackBar(context, localizations.invalidDeepLink);
          }
        }
        return false;
      }

      // If no path segments, just open the app (e.g., for UTM-only links from Apple Ads)
      if (pathSegments.isEmpty) {
        AppLogger.d(
          'DEEPLINK',
          'No path segments, opening app (UTM parameters already processed)',
        );
        return false;
      }

      // Handle OTP links
      if (pathSegments[0] == 'otp' ||
          (pathSegments.length > 1 && pathSegments[1] == 'otp')) {
        return false;
      }

      // Handle other navigation links
      final path = pathSegments[0];
      final id = pathSegments.length > 1 ? pathSegments[1] : '';
      unawaited(
        _navigateWhenReady(
          () => handleNavigation(path, [id], context, ref: ref),
        ),
      );
      return true;
    } catch (e) {
      AppLogger.e('DEEPLINK', 'Error handling deep link', e);
      if (context.mounted) {
        final localizations = AppLocalizations.of(context);
        if (localizations != null) {
          showSnackBar(context, localizations.deepLinkError);
        }
      }
      return false;
    }
  }

  void _logIfHomeWidgetTap(Uri uri) {
    try {
      final source = uri.queryParameters['source'];
      if (source != AnalyticsEventConstants.widgetDeepLinkSource) return;

      final widgetType = uri.queryParameters['widget'] ?? 'unknown';
      final params = <String, Object>{
        AnalyticsEventConstants.paramWidgetType: widgetType,
        'platform': Platform.isIOS ? 'ios' : 'android',
      };

      // Include the track id when present so we can correlate widget taps
      // with content (Up Next widget only). Normalise across the two URI
      // forms used by the widgets:
      //   Android: org.meditofoundation://medito/tracks/{id}?…
      //   iOS:     org.meditofoundation://tracks/{id}?…
      final normalised = uri.host == 'medito'
          ? uri.pathSegments
          : <String>[uri.host, ...uri.pathSegments];
      final tracksIdx = normalised.indexOf('tracks');
      if (tracksIdx != -1 && tracksIdx + 1 < normalised.length) {
        params[AnalyticsEventConstants.paramSessionId] =
            normalised[tracksIdx + 1];
      }

      unawaited(
        ref
            .read(analyticsServiceProvider)
            .logEvent(
              name: AnalyticsEventConstants.homeWidgetTapped,
              parameters: params,
            ),
      );
      AppLogger.d('DEEPLINK', 'Home widget tap logged: $widgetType');
    } catch (e) {
      AppLogger.w('DEEPLINK', 'Failed to log home widget tap: $e');
    }
  }

  Future<void> _storeUtmParameters(Uri uri) async {
    try {
      final queryParameters = uri.queryParameters;

      if (queryParameters.isEmpty) {
        AppLogger.d('DEEPLINK', 'No query parameters found in deep link');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      var storedCount = 0;

      final utmParams = [
        SharedPreferenceConstants.utmSource,
        SharedPreferenceConstants.utmMedium,
        SharedPreferenceConstants.utmCampaign,
        SharedPreferenceConstants.utmTerm,
        SharedPreferenceConstants.utmContent,
      ];

      for (final paramKey in utmParams) {
        final value = queryParameters[paramKey];
        if (value != null && value.isNotEmpty) {
          await prefs.setString(paramKey, value);
          storedCount++;
        }
      }

      if (storedCount > 0) {
        AppLogger.d(
          'DEEPLINK',
          'Stored $storedCount UTM parameter(s) for later application',
        );
      } else {
        AppLogger.d('DEEPLINK', 'No UTM parameters found in query string');
      }
    } catch (e) {
      AppLogger.e('DEEPLINK', 'Error storing UTM parameters', e);
    }
  }
}
