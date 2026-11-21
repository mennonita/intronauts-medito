import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:medito/constants/constants.dart';
import 'package:medito/constants/network_constants.dart';
import 'package:medito/exceptions/app_error.dart';
import 'package:medito/services/analytics/crashlytics_service.dart';
import 'package:medito/services/network/auth_api_service.dart';
import 'package:medito/utils/logger.dart';
import 'package:medito/utils/stats_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:medito/services/secure_storage_service.dart';
import 'package:medito/mock/mock_http_api_service.dart';

// Event bus or callback type for auth events
typedef AuthStateCallback = void Function(AuthEvent event);

// Auth events that can be emitted
enum AuthEvent { forceLogout, recoverSession }

class HttpApiService {
  static HttpApiService? _instance;
  final _client = HttpClient();
  final _headers = <String, String>{};

  // NOTE on `_retryCount` (audit P0-1):
  //
  // This is intentionally a singleton-scoped counter, NOT per-request. It
  // tracks "successful refreshes followed by a failed retry, since the last
  // successful retry" — the "be extra forgiving when the user might be
  // coming back from background with expired tokens" behaviour referenced
  // by [_handleUnauthorizedResponse]. The counter increments only after a
  // refresh succeeded but the retried request itself failed, and resets on
  // a successful retry.
  //
  // Because Dart is single-threaded and [_refreshInFlight] serializes the
  // actual refresh work, there's no classic data race here. The "shared
  // state across requests" smell is real but the behaviour is intentional.
  // If you want to change this, also revisit the comment at line ~258
  // ("Much higher retry limit (up to 5) to be extra forgiving…") — that
  // intent goes hand-in-hand with the cross-request accumulation.
  //
  // Production data (Firebase Analytics `unexpected_logout_refresh_token_missing`)
  // shows ~15 users / 14 days hit the force-logout path. Tread carefully
  // — a "fix" here could regress these users in unexpected ways.
  var _retryCount = 0;

  final AuthApiService _authService;
  static var _instanceCount = 0;
  final _instanceId = ++_instanceCount;

  // Add a lock to prevent concurrent token refresh attempts
  Future<void>? _refreshInFlight;

  // List of callbacks to notify on auth events
  final List<AuthStateCallback> _authCallbacks = [];

  // Supplies an access token (setting the auth header as a side effect) when
  // a request is about to go out without one. Registered by the auth
  // repository. On a cold start the header stays empty until the first
  // getToken(), so without this, early requests (stats, packs, home) went out
  // with no token, got a 401, and triggered a second, parallel refresh.
  Future<void> Function()? _tokenSupplier;

  // One supplier call is shared by every request waiting on it, and after a
  // failure (offline, auth host down) requests stop waiting for a while
  // instead of each re-running the full refresh-with-retries.
  Future<void>? _pendingTokenSupply;
  DateTime? _tokenSupplyFailedAt;
  static const _tokenSupplyTimeout = Duration(seconds: 10);
  static const _tokenSupplyCooldown = Duration(seconds: 30);

  // Bumped whenever local auth is cleared, so a refresh that was in flight
  // when the user signed out (or deleted their account) can't put the old
  // session's access token back on the header.
  int _authEpoch = 0;
  int get authEpoch => _authEpoch;

  // NOTE: The dependency on `package:medito/mock/...` above is INTENTIONAL.
  // `lib/mock/` is not test code — it's a shipped demo environment that lets
  // contributors run the app without real API keys (see lib/mock/README.md
  // and the doc comment on `isMockMode`). The mock service extends this one
  // and is swapped in here at construction time, so production code does
  // import from `lib/mock/` by design. Do not "fix" this by deleting the
  // import or moving the mock folder out of lib/ without first replacing
  // the wiring (e.g. with a flavor or a Riverpod override).
  factory HttpApiService() {
    if (isMockMode) {
      _instance ??= MockHttpApiService();
    } else {
      _instance ??= HttpApiService._internal();
    }
    AppLogger.d(
      'HTTP',
      'Returning singleton instance #${_instance!._instanceId}',
    );
    return _instance!;
  }

  /// Public constructor intended for subclasses (e.g. MockHttpApiService)
  /// and tests. Delegates to the private `_internal` constructor to ensure
  /// consistent initialization logic. The optional [authService] parameter
  /// lets tests inject a fake [AuthApiService] without going through the
  /// singleton factory.
  HttpApiService.internal({AuthApiService? authService})
    : this._internal(authService: authService);

  HttpApiService._internal({AuthApiService? authService})
    : _authService = authService ?? AuthApiService() {
    AppLogger.d('HTTP', 'Creating new HttpApiService instance #$_instanceId');
    _client.connectionTimeout = kTimeoutDuration;
    _initializeHeaders();
  }

  // Register for auth events
  void addAuthCallback(AuthStateCallback callback) {
    _authCallbacks.add(callback);
  }

  // Remove auth callback
  void removeAuthCallback(AuthStateCallback callback) {
    _authCallbacks.remove(callback);
  }

  // Notify listeners of auth events
  void _notifyAuthEvent(AuthEvent event) {
    for (final callback in _authCallbacks) {
      callback(event);
    }
  }

  Future<void> recoverRejectedSession(int epoch) async {
    if (epoch != _authEpoch) return;
    // El primer rechazo invalida la sesión antes de esperar el almacenamiento.
    _authEpoch++;
    clearAuthHeader();
    _retryCount = 0;
    AuthApiService.clearRefreshCache();

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(SharedPreferenceConstants.isLoggedIn) != true) return;

    await prefs.setBool(SharedPreferenceConstants.isLoggedIn, false);
    await StatsManager().clearAllStats(preservePending: true);
    await _authService.clearAuthTokens();
    await SecureStorageService().clearUserEmail();
    final hasSavedClient =
        prefs.getString(SharedPreferenceConstants.userId) != null;
    _notifyAuthEvent(
      hasSavedClient ? AuthEvent.recoverSession : AuthEvent.forceLogout,
    );
  }

  void _initializeHeaders() {
    AppLogger.d('HTTP', 'Initializing headers for instance #$_instanceId');
    _headers[kContentTypeHeader] = ContentType.json.toString();
  }

  void setAuthHeader(String accessToken) {
    AppLogger.d(
      'HTTP',
      'Setting auth header on instance #$_instanceId. HasAccessToken: ${accessToken.isNotEmpty}',
    );
    _headers[kAuthorizationHeader] = 'Bearer $accessToken';
    _tokenSupplyFailedAt = null;
  }

  void setTokenSupplier(Future<void> Function() supplier) {
    _tokenSupplier = supplier;
  }

  /// Waits for an access token if the request would otherwise be sent
  /// without one. Failures are swallowed: the request then goes out as
  /// before and the 401 handling takes over.
  Future<void> _awaitAuthHeader() async {
    final supplier = _tokenSupplier;
    if (supplier == null || _headers.containsKey(kAuthorizationHeader)) return;
    final failedAt = _tokenSupplyFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _tokenSupplyCooldown) {
      return;
    }
    final pending = _pendingTokenSupply ??= supplier()
        .timeout(_tokenSupplyTimeout)
        .whenComplete(() => _pendingTokenSupply = null);
    try {
      await pending;
    } catch (e) {
      _tokenSupplyFailedAt = DateTime.now();
      AppLogger.w('HTTP', 'No access token before request: $e');
    }
  }

  void clearAuthHeader() {
    AppLogger.d('HTTP', 'Clearing auth header on instance #$_instanceId');
    _headers.remove(kAuthorizationHeader);
  }

  /// Drops this service's whole view of the session: the header, its own
  /// [AuthApiService]'s tokens and any shared in-flight refresh. The
  /// synchronous part runs before the first await, so no request that starts
  /// afterwards can pick the old session back up.
  Future<void> clearLocalAuth() async {
    _authEpoch++;
    clearAuthHeader();
    _tokenSupplyFailedAt = null;
    await _authService.clearAuthTokens();
  }

  /// Test-only accessor for the singleton-scoped retry counter. See the
  /// comment on [_retryCount] for design notes.
  @visibleForTesting
  int get retryCountForTesting => _retryCount;

  /// Test-only setter to seed the retry counter so tests can exercise the
  /// "max retries reached → force logout" branch without setting up the full
  /// refresh + retry flow.
  @visibleForTesting
  set retryCountForTesting(int value) => _retryCount = value;

  @visibleForTesting
  Future<void> awaitAuthHeaderForTesting() => _awaitAuthHeader();

  /// Test-only accessor for the in-progress refresh flag.
  @visibleForTesting
  bool get isRefreshingTokenForTesting => _refreshInFlight != null;

  /// Test-only wrapper for the private refresh implementation. The token
  /// refresh logic is exercised by [_handleUnauthorizedResponse] in
  /// production; this wrapper lets tests verify the underlying lock and
  /// auth-service interactions in isolation, without standing up a full
  /// HTTP transport mock.
  @visibleForTesting
  Future<void> refreshTokenForTesting() => _refreshTokenThroughAuthService();

  Future<Map<String, dynamic>> getRequest(
    String path, {
    Map<String, dynamic>? queryParams,
  }) async =>
      _handleRequest(() async => _client.getUrl(_buildUri(path, queryParams)));

  Future<Map<String, dynamic>> postRequest(String path, {dynamic body}) async =>
      _handleRequest(() async => _client.postUrl(_buildUri(path)), body: body);

  Future<Map<String, dynamic>> deleteRequest(
    String path, {
    dynamic body,
  }) async => _handleRequest(
    () async => _client.deleteUrl(_buildUri(path)),
    body: body,
  );

  Uri _buildUri(String path, [Map<String, dynamic>? queryParams]) {
    return Uri.parse(
      '$contentBaseUrl$path',
    ).replace(queryParameters: queryParams);
  }

  Uri _buildAuthUri(String path) {
    return Uri.parse('$authBaseUrl$path');
  }

  /// The access token requests currently go out with, if any.
  String? get accessToken {
    final header = _headers[kAuthorizationHeader];
    const prefix = 'Bearer ';
    return header != null && header.startsWith(prefix)
        ? header.substring(prefix.length)
        : null;
  }

  /// Asks the server to end the session [accessToken] belongs to (the server
  /// deletes the session named by the token's `jti`). Local auth state is not
  /// touched: the auth repository clears it first, so sign-out never waits on
  /// the network — which is why the token has to be passed in.
  Future<void> signOut(String accessToken) async {
    AppLogger.i('HTTP', 'Ending server session');

    try {
      final request = await _client.postUrl(
        _buildAuthUri(HTTPConstants.authTokensSignout),
      );
      request.headers.set(kContentTypeHeader, ContentType.json.toString());
      request.headers.set(kAuthorizationHeader, 'Bearer $accessToken');

      final response = await request.close().timeout(kTimeoutDuration);
      await response.drain<void>();

      if (response.statusCode >= HttpStatus.multipleChoices) {
        AppLogger.w(
          'HTTP',
          'Signout request failed. Status: ${response.statusCode}',
        );
      } else {
        AppLogger.i('HTTP', 'Server session ended');
      }
    } catch (e, stackTrace) {
      AppLogger.e('HTTP', 'Signout request error', e, stackTrace);
    }
  }

  Future<Map<String, dynamic>> _handleRequest(
    Future<HttpClientRequest> Function() requestBuilder, {
    dynamic body,
  }) async {
    final epoch = _authEpoch;
    try {
      await _awaitAuthHeader();
      if (epoch != _authEpoch) throw const UnauthorizedError();
      final request = await requestBuilder();
      if (epoch != _authEpoch) {
        request.abort();
        throw const UnauthorizedError();
      }
      _headers.forEach(request.headers.set);

      AppLogger.d(
        'HTTP',
        'Request headers set. Instance: $_instanceId, HasAuth: ${request.headers.value(kAuthorizationHeader) != null}',
      );

      if (body != null) {
        final encodedBody = jsonEncode(body);
        // add() with explicit UTF-8: write() encodes as Latin-1 unless the
        // content-type carries a charset, and throws on any char > U+00FF.
        request.add(utf8.encode(encodedBody));
      }

      final response = await request.close().timeout(kTimeoutDuration);
      final content = await utf8.decodeStream(response);

      AppLogger.d(
        'HTTP',
        'Response received. Instance: $_instanceId, Status: ${response.statusCode}, Length: ${content.length}',
      );

      if (epoch != _authEpoch) throw const UnauthorizedError();
      if (response.statusCode == HttpStatus.unauthorized) {
        return await _handleUnauthorizedResponse(
          response.statusCode,
          requestBuilder,
          body,
          epoch,
        );
      }

      if (response.statusCode >= HttpStatus.multipleChoices) {
        throw _handleErrorResponse(response.statusCode);
      }

      _retryCount = 0;
      return content.isEmpty ? {} : _parseResponseContent(content);
    } on SocketException catch (e, stackTrace) {
      AppLogger.e('HTTP', 'Network Error (SocketException)', e, stackTrace);
      final error = NetworkConnectionError.fromSocketException(e);
      CrashlyticsService().recordNetworkFailure(
        error,
        stackTrace,
        host: Uri.tryParse(contentBaseUrl)?.host,
        source: 'HttpApi',
      );
      throw error;
    } on NetworkConnectionError catch (e, stackTrace) {
      AppLogger.e(
        'HTTP',
        'Network Error (NetworkConnectionError)',
        e,
        stackTrace,
      );
      throw NetworkConnectionError(originalException: e);
    } on TimeoutException catch (e, stackTrace) {
      AppLogger.e('HTTP', 'Request Timeout', e, stackTrace);
      throw const TimeoutError();
    } on HttpException catch (e, stackTrace) {
      AppLogger.e('HTTP', 'HTTP exception', e, stackTrace);
      throw Exception('HTTP exception');
    } catch (e, stackTrace) {
      AppLogger.e('HTTP', 'Unexpected error in _handleRequest', e, stackTrace);
      throw const UnknownError();
    }
  }

  AppError _handleErrorResponse(int statusCode) {
    AppLogger.w('HTTP', 'HTTP Error $statusCode');

    return switch (statusCode) {
      HttpStatus.notFound => const NotFoundError(),
      HttpStatus.unauthorized => const UnauthorizedError(),
      >= 500 => const ServerError(),
      _ => const UnknownError(),
    };
  }

  Map<String, dynamic> _parseResponseContent(String content) {
    final decoded = jsonDecode(content);
    return decoded is Map<String, dynamic> ? decoded : {'results': decoded};
  }

  Future<Map<String, dynamic>> _handleUnauthorizedResponse(
    int statusCode,
    Future<HttpClientRequest> Function() requestBuilder,
    dynamic body,
    int epoch,
  ) async {
    AppLogger.w(
      'HTTP',
      'Unauthorized response (401) - retry count: $_retryCount',
    );
    await _addHttpDebugLog(
      'Unauthorized response (401) - retry count: $_retryCount',
    );

    // Much higher retry limit (up to 5) to be extra forgiving
    // when user might be coming back from background with expired tokens
    const maxBackgroundRetries = 5;
    if (_retryCount >= maxBackgroundRetries) {
      AppLogger.w(
        'HTTP',
        'Max retries ($maxBackgroundRetries) reached for request after auth error',
      );
      await _addHttpDebugLog(
        'Max retries ($maxBackgroundRetries) reached - FORCING LOGOUT (removed)',
      );
      throw const UnauthorizedError();
    }

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(SharedPreferenceConstants.isLoggedIn) != true) {
      throw const UnauthorizedError();
    }

    try {
      AppLogger.i('HTTP', 'Refreshing token through auth service...');

      // Add a slight delay between retries to avoid hammering the server
      if (_retryCount > 0) {
        await Future.delayed(Duration(milliseconds: 500 * _retryCount));
      }

      // Use the refreshTokenThroughAuthService method
      if (epoch != _authEpoch) throw const UnauthorizedError();
      await _refreshTokenThroughAuthService();
      if (epoch != _authEpoch) throw const UnauthorizedError();

      await _addHttpDebugLog(
        'Token refresh successful - attempt ${_retryCount + 1}',
      );

      // Increment retry count and retry the original request with new token
      _retryCount++;

      // Create a new request with updated headers
      if (epoch != _authEpoch) throw const UnauthorizedError();
      final request = await requestBuilder();
      if (epoch != _authEpoch) {
        request.abort();
        throw const UnauthorizedError();
      }
      _headers.forEach(request.headers.set);

      if (body != null) {
        final encodedBody = jsonEncode(body);
        // add() with explicit UTF-8: write() encodes as Latin-1 unless the
        // content-type carries a charset, and throws on any char > U+00FF.
        request.add(utf8.encode(encodedBody));
      }

      final response = await request.close().timeout(kTimeoutDuration);
      final content = await utf8.decodeStream(response);

      if (response.statusCode >= HttpStatus.multipleChoices) {
        var errorMsg =
            'Request still failing after token refresh: ${response.statusCode}';
        AppLogger.w('HTTP', errorMsg);
        await _addHttpDebugLog(errorMsg);
        throw _handleErrorResponse(response.statusCode);
      }

      // Successfully completed the request after token refresh, reset retry counter
      _retryCount = 0;
      AppLogger.i('HTTP', 'Request successful after token refresh');
      await _addHttpDebugLog('Request successful after token refresh');
      return content.isEmpty ? {} : _parseResponseContent(content);
    } on NetworkConnectionError {
      // Don't log out on connection issues - let the user retry when connection is available
      AppLogger.w(
        'HTTP',
        'No internet connection during token refresh attempt',
      );
      await _addHttpDebugLog('No internet connection during token refresh');
      rethrow;
    } catch (e, stackTrace) {
      AppLogger.e('HTTP', 'Token refresh process failed', e, stackTrace);

      if (epoch != _authEpoch) rethrow;
      await _addHttpDebugLog('Token refresh error: ${e.runtimeType}');

      rethrow;
    }
  }

  // Store debug logs in shared preferences for debugging auth issues
  Future<void> _addHttpDebugLog(String logEntry) async {
    // Only log in debug mode
    if (!kDebugMode) return;

    try {
      var prefs = await SharedPreferences.getInstance();
      var logs = prefs.getStringList('auth_debug_logs') ?? [];

      // Keep last 50 logs
      if (logs.length > 50) {
        logs = logs.sublist(logs.length - 50);
      }

      var timestamp = DateTime.now().toIso8601String();
      logs.add('$timestamp: [HTTP] $logEntry');
      await prefs.setStringList('auth_debug_logs', logs);

      // We don't need to log that we added a log entry using the same mechanism
    } catch (e, stackTrace) {
      AppLogger.e('HTTP', 'Error saving debug log', e, stackTrace);
    }
  }

  void addDeviceHeaders(Map<String, String> headers) {
    var authHeader = _headers[kAuthorizationHeader];
    _headers.addAll(headers);
    if (authHeader != null) {
      _headers[kAuthorizationHeader] = authHeader;
    }
  }

  // Expose a diagnostic method to validate token refresh flow
  Future<Map<String, dynamic>> diagnoseSecurity() async {
    var diagnosticInfo = <String, dynamic>{
      'timestamp': DateTime.now().toString(),
      'has_auth_header': _headers.containsKey(kAuthorizationHeader),
    };

    try {
      // Check shared preferences for login state
      final prefs = await SharedPreferences.getInstance();
      final isLoggedIn =
          prefs.getBool(SharedPreferenceConstants.isLoggedIn) ?? false;
      diagnosticInfo['is_logged_in'] = isLoggedIn;

      // Check if refresh token exists by trying to get it
      final refreshToken = await _authService.getStoredRefreshToken();
      diagnosticInfo['refresh_token_exists'] = refreshToken != null;
      // Log comprehensive diagnostic info
      AppLogger.i('HTTP', 'Security diagnosis: ${jsonEncode(diagnosticInfo)}');
    } catch (e, stackTrace) {
      diagnosticInfo['error'] = e.toString();
      AppLogger.e('HTTP', 'Error during security diagnosis', e, stackTrace);
    }

    return diagnosticInfo;
  }

  Future<void> _refreshTokenThroughAuthService() {
    return _refreshInFlight ??= _refreshToken(_authEpoch).whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<void> _refreshToken(int epoch) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(SharedPreferenceConstants.isLoggedIn) != true) {
      throw const UnauthorizedError();
    }
    try {
      final refreshToken = await _authService.getStoredRefreshToken();
      if (epoch != _authEpoch) throw const UnauthorizedError();
      if (refreshToken == null) throw const RefreshTokenError();

      final tokens = await _authService.refreshToken(refreshToken);
      if (epoch != _authEpoch) throw const UnauthorizedError();
      setAuthHeader(tokens.accessToken);
    } on RefreshTokenError {
      await recoverRejectedSession(epoch);
      rethrow;
    }
  }
}
