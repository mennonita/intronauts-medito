import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart'; // Import for visibleForTesting
import 'package:medito/constants/constants.dart' hide AuthTokens;
import 'package:medito/constants/network_constants.dart';
import 'package:medito/exceptions/app_error.dart';
import 'package:medito/models/auth/auth_tokens.dart';
import 'package:medito/services/secure_storage_service.dart';
import 'package:medito/utils/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:medito/services/analytics/firebase_analytics_service.dart';
import 'package:medito/services/analytics/crashlytics_service.dart';

class HttpClientWrapper {
  HttpClient createClient() => HttpClient();
}

class AuthApiService {
  final SecureStorageService _secureStorage;
  final String _baseUrl;
  final String _apiKey;
  final CrashlyticsService _crashlyticsService;

  final HttpClient _client;
  final _headers = <String, String>{};
  AuthTokens? _tokens;

  // Use named constructors instead of factory+singleton pattern
  AuthApiService({
    SecureStorageService? secureStorage,
    HttpClientWrapper? httpClientWrapper,
    String? baseUrl,
    String? customApiKey,
    CrashlyticsService? crashlyticsService,
  }) : _secureStorage = secureStorage ?? SecureStorageService(),
       _baseUrl = baseUrl ?? authBaseUrl,
       _apiKey =
           customApiKey ?? apiKey, // Use the global apiKey if none provided
       _client = (httpClientWrapper ?? HttpClientWrapper()).createClient(),
       _crashlyticsService = crashlyticsService ?? CrashlyticsService() {
    _client.connectionTimeout = kTimeoutDuration;
    _initializeHeaders();
  }

  void _initializeHeaders() {
    _headers[kContentTypeHeader] = ContentType.json.toString();
    _headers[kAuthorizationHeader] = 'Bearer $_apiKey';
  }

  Future<AuthTokens> signIn({
    String? email,
    String? otp,
    required String clientId,
  }) async {
    AppLogger.i(
      'AUTH',
      'Attempting sign in. Email: ${email != null}, OTP: ${otp != null}, HasClientId: ${clientId.isNotEmpty}',
    );

    final response = await _post(
      HTTPConstants.authSignIn,
      body: {'client_id': clientId, 'email': ?email, 'code': ?otp},
    );

    AppLogger.i(
      'AUTH',
      'Sign in successful. HasClientId: ${response['client_id'] != null}, HasEmail: ${response['email'] != null}',
    );

    final tokens = AuthTokens(
      accessToken: response['access_token'] as String,
      refreshToken: response['refresh_token'] as String,
      expiresIn: response['expires_in'] as int,
      clientId: response['client_id'] as String,
      email: response['email'] as String?,
    );

    await setAuthTokens(tokens);
    return tokens;
  }

  Future<void> requestOtp(String email, String clientId) async {
    AppLogger.i(
      'AUTH',
      'Requesting OTP. HasEmail: ${email.isNotEmpty}, HasClientId: ${clientId.isNotEmpty}',
    );

    await _post(
      HTTPConstants.authOtpRequest,
      body: {'email': email, 'client_id': clientId},
    );

    AppLogger.i('AUTH', 'OTP request successful');
  }

  // The refresh currently in flight, keyed by the refresh token it uses.
  // Static because the auth repository and HttpApiService each own an
  // instance, and both refresh on a cold start. Only an IN-FLIGHT refresh is
  // shared: the server hands back the same refresh token every time (it does
  // not rotate), so a finished result must never be reused — its access token
  // expires after 2h and would be replayed forever.
  static String? _inFlightRefreshKey;
  static Future<AuthTokens>? _inFlightRefresh;

  Future<AuthTokens> refreshToken(String refreshToken) {
    final inFlight = _inFlightRefresh;
    if (inFlight != null && refreshToken == _inFlightRefreshKey) {
      AppLogger.i('AUTH_API', 'Joining refresh already in flight');
      return inFlight;
    }
    final refresh = _refreshToken(refreshToken);
    _inFlightRefreshKey = refreshToken;
    _inFlightRefresh = refresh;
    unawaited(
      refresh.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_inFlightRefresh, refresh)) clearRefreshCache();
      }),
    );
    return refresh;
  }

  /// Forgets any in-flight refresh so callers after a sign-out can't join a
  /// refresh that belongs to the previous session.
  static void clearRefreshCache() {
    _inFlightRefreshKey = null;
    _inFlightRefresh = null;
  }

  Future<AuthTokens> _refreshToken(String refreshToken) async {
    AppLogger.i('AUTH_API', 'Starting token refresh');
    AppLogger.d(
      'AUTH_API',
      'Attempting token refresh. HasRefreshToken: ${refreshToken.isNotEmpty}',
    );

    try {
      // Store a copy of the existing tokens for comparison
      final oldTokens = _tokens;

      // Send refresh token in the body instead of using it as a Bearer token
      final response = await _post(
        HTTPConstants.authTokensRefresh,
        body: {'refresh_token': refreshToken},
      );

      // Check explicitly if email is present in response
      final emailInResponse = response['email'] as String?;
      AppLogger.d(
        'AUTH_API',
        'HasEmail in token refresh response: ${emailInResponse != null}',
      );

      final clientId =
          response['client_id'] as String? ?? oldTokens?.clientId ?? '';

      // Create new tokens object with the refreshed access token
      final tokens = AuthTokens(
        accessToken: response['access_token'] as String,
        refreshToken:
            response['refresh_token']
                as String, // Use refresh token from response
        expiresIn: response['expires_in'] as int,
        clientId: clientId,
        // Only fall back to the previous email for the same client, so an
        // email can never carry over to a different (e.g. new anonymous)
        // account.
        email:
            emailInResponse ??
            (clientId == oldTokens?.clientId ? oldTokens?.email : null),
      );

      // Log differences between old and new tokens
      AuthTokens.logTokenDifferences(oldTokens, tokens);

      // Log what email value we're using
      AppLogger.d(
        'AUTH_API',
        'Refreshed tokens have email: ${tokens.email != null}',
      );
      AppLogger.d(
        'AUTH_API',
        'Email source: ${emailInResponse != null ? 'from response' : 'preserved from old token'}',
      );

      // Store the new tokens
      await setAuthTokens(tokens);

      AppLogger.i(
        'AUTH_API',
        'Token refresh successful. ExpiresIn: ${tokens.expiresIn}, HasEmail: ${tokens.email != null}, HasClientId: ${tokens.clientId.isNotEmpty}',
      );

      return tokens;
    } on UnauthorizedError {
      throw const RefreshTokenError();
    } catch (e, stackTrace) {
      AppLogger.e(
        'AUTH_API',
        'Token refresh failed: ${e.runtimeType}',
        null,
        stackTrace,
      );
      rethrow;
    }
  }

  Future<void> setAuthTokens(AuthTokens tokens) async {
    final previousEmail = _tokens?.email;
    _tokens = tokens;

    AppLogger.d(
      'AUTH_API',
      'setAuthTokens called. HadEmail: ${previousEmail != null}, HasEmail: ${tokens.email != null}',
    );

    if (tokens.refreshToken.isNotEmpty) {
      try {
        // Directly use the secure storage service's storeRefreshToken method
        // which already has its own comprehensive retry mechanism
        await _secureStorage.storeRefreshToken(tokens.refreshToken);
        AppLogger.d('AUTH_API', 'Refresh token saved to secure storage');
      } catch (e, stack) {
        // This error is critical - log it extensively
        AppLogger.e(
          'AUTH_API',
          'CRITICAL: Failed to save refresh token to secure storage. User may experience unexpected logout on next app start.',
          e,
          stack,
        );

        // Track this critical error in Firebase Analytics
        try {
          final packageInfo = await PackageInfo.fromPlatform();
          await FirebaseAnalyticsService().logEvent(
            name: FirebaseAnalyticsService.eventAuthTokenStorageFailed,
            parameters: {
              'error': e.toString(),
              'stack_trace': stack.toString(),
              'version': packageInfo.version,
              'build_number': packageInfo.buildNumber,
            },
          );
          // Also log this critical failure to Crashlytics
          _crashlyticsService.recordError(
            e,
            stack,
            reason: 'CRITICAL: Failed to save refresh token to secure storage',
          );
        } catch (analyticsError) {
          AppLogger.e(
            'AUTH_API',
            'Failed to log token storage failure to analytics',
            analyticsError,
          );
        }
      }
    }

    AppLogger.d(
      'AUTH_API',
      'Tokens updated. HasRefreshToken: ${tokens.refreshToken.isNotEmpty}, HasEmail: ${tokens.email != null}, ExpiresIn: ${tokens.expiresIn}',
    );
  }

  Future<void> clearAuthTokens() async {
    _tokens = null;
    clearRefreshCache();
    await _secureStorage.clearRefreshToken();
  }

  Future<String?> getStoredRefreshToken() async {
    AppLogger.d('AUTH', 'Getting stored refresh token');
    final token = await _secureStorage.getRefreshToken();
    AppLogger.d('AUTH', 'Has stored refresh token: ${token != null}');
    return token;
  }

  Future<Map<String, dynamic>> _post(String path, {dynamic body}) async {
    try {
      // Ensure the path is properly combined with base URL
      final uri = Uri.parse('$_baseUrl$path');

      AppLogger.d('AUTH', 'Has API key: ${_apiKey.isNotEmpty}');

      final request = await _client.postUrl(uri);

      // Add headers
      _headers.forEach(request.headers.set);

      AppLogger.d(
        'AUTH',
        'POST Request: ${uri.toString()}, Body: ${body != null}',
      );

      if (body != null) {
        final encodedBody = jsonEncode(body);
        // add() with explicit UTF-8: write() encodes as Latin-1 unless the
        // content-type carries a charset, and throws on any char > U+00FF.
        request.add(utf8.encode(encodedBody));
      }

      final response = await request.close().timeout(kTimeoutDuration);
      final content = await utf8.decodeStream(response);

      // Add specific logging for email in auth responses
      final parsedContent = content.isNotEmpty ? jsonDecode(content) : null;
      final hasEmail =
          parsedContent != null &&
          parsedContent is Map<String, dynamic> &&
          parsedContent.containsKey('email');

      AppLogger.d('AUTH_API', 'Response contains email: $hasEmail');
      AppLogger.d(
        'AUTH_API',
        'Response Status: ${response.statusCode}, Content Length: ${content.length}',
      );

      if (response.statusCode >= HttpStatus.badRequest) {
        AppLogger.w('AUTH', 'Request failed. Status: ${response.statusCode}');
        handleErrorResponse(response.statusCode, content);
        throw Exception('handleErrorResponse did not throw');
      }

      return content.isEmpty ? {} : jsonDecode(content) as Map<String, dynamic>;
    } on SocketException catch (e, stackTrace) {
      AppLogger.e('AUTH', 'Network error (SocketException)', e, stackTrace);
      final error = NetworkConnectionError.fromSocketException(e);
      _crashlyticsService.recordNetworkFailure(
        error,
        stackTrace,
        host: Uri.tryParse(_baseUrl)?.host,
        source: 'AuthApi',
      );
      throw error;
    } on TimeoutException catch (e, stackTrace) {
      AppLogger.e('AUTH', 'Request timeout', e, stackTrace);
      throw const TimeoutError();
    } catch (e, stackTrace) {
      AppLogger.e(
        'AUTH',
        'Unexpected error in _post: ${e.runtimeType}',
        null,
        stackTrace,
      );
      if (e is FormatException) throw const ServerError();
      rethrow;
    }
  }

  @visibleForTesting
  void handleErrorResponse(int statusCode, [String? content]) {
    AppLogger.w('AUTH', 'HTTP Error $statusCode');

    if (statusCode == HttpStatus.unprocessableEntity ||
        statusCode == HttpStatus.notAcceptable) {
      throw const InactiveEmailError();
    }

    if (content != null && content.isNotEmpty) {
      try {
        final Map<String, dynamic> errorData =
            jsonDecode(content) as Map<String, dynamic>;
        final String? errorMessage =
            errorData['message'] as String? ?? errorData['error'] as String?;
        final String? errorCode = errorData['code'] as String?;
        final bool? rateLimited =
            errorData['rate_limited'] as bool?; // Check for rate limit flag
        final int? retryAfter =
            errorData['retry_after'] as int?; // Check for retry after seconds
        final String? emailFromError =
            errorData['email']
                as String?; // Attempt to get email from error response

        // Handle Rate Limit specifically
        if (statusCode == HttpStatus.tooManyRequests &&
            rateLimited == true &&
            retryAfter != null) {
          throw RateLimitError(
            tryAfterSeconds: retryAfter,
            message: errorMessage ?? 'Too many requests. Please wait.',
          );
        }

        if (statusCode == HttpStatus.forbidden &&
            errorCode == 'ACCOUNT_DELETED') {
          throw const AccountDeletedError();
        }

        // Handle Email Exists specifically using the new AppError type
        if (errorCode == 'EMAIL_ASSOCIATED' &&
            statusCode == HttpStatus.forbidden) {
          throw EmailExistsError(
            email: emailFromError, // Pass the email if available
            message:
                errorMessage ??
                'This device is already associated with an email account.',
          );
        }

        // Handle Email Mismatch - client ID exists but is associated with different email
        if (errorCode == 'EMAIL_MISMATCH' &&
            statusCode == HttpStatus.forbidden) {
          throw EmailMismatchError(
            message:
                errorMessage ??
                'This account is already linked to a different email address. Please use the original email.',
          );
        }

        if (errorMessage != null) {
          if (errorMessage.contains('Invalid refresh token') ||
              errorMessage.contains('Expired refresh token') ||
              errorMessage.contains('Token has been revoked')) {
            _crashlyticsService.recordError(
              const RefreshTokenError(),
              StackTrace.current,
              reason: 'AuthAPI: Refresh token invalid, expired, or revoked',
            );
            throw const RefreshTokenError();
          }
        }
      } catch (e) {
        if (e is RateLimitError ||
            e is AccountDeletedError ||
            e is EmailExistsError ||
            e is EmailMismatchError ||
            e is RefreshTokenError ||
            e is InactiveEmailError) {
          rethrow; // Rethrow specific exceptions
        }
        AppLogger.e(
          'AUTH',
          'Error parsing auth error response: ${e.runtimeType}',
        );
        // Fall through to default handling if parsing failed
      }
    }

    // Default handling - Always throw an AppError
    switch (statusCode) {
      case HttpStatus.notFound:
        throw const NotFoundError();
      case HttpStatus.unauthorized:
        throw const UnauthorizedError();
      default:
        if (statusCode >= 500) {
          throw const ServerError();
        } else {
          throw const UnknownError();
        }
    }
  }
}
