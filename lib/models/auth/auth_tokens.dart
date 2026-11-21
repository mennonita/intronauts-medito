// Business logic model for auth tokens
import 'package:medito/utils/logger.dart';

final dev = const AppLoggerAdapter('AUTH_TOKENS');

class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final String clientId;
  final String? email;

  // Calculate expiry time when created
  final DateTime createdAt;

  AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.clientId,
    this.email,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  // Convert from API response
  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      expiresIn: json['expires_in'] as int,
      clientId: json['client_id'] as String,
      email: json['email'] as String?,
    );
  }

  // Convert to JSON for API requests or storage
  Map<String, dynamic> toJson() {
    return {
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_in': expiresIn,
      'client_id': clientId,
      if (email != null) 'email': email,
    };
  }

  // Check if token is expired or about to expire (with 30s buffer)
  bool get isExpired {
    final expiration = createdAt.add(Duration(seconds: expiresIn));
    final isExpired = DateTime.now().isAfter(expiration);
    dev.log(
      '[AUTH_TOKENS] Token expired check: $isExpired (expiration: $expiration)',
      level: 1000,
    );
    return isExpired;
  }

  // Create a new instance with refreshed access token
  AuthTokens refreshedWith({
    required String accessToken,
    required int expiresIn,
  }) {
    return AuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresIn: expiresIn,
      clientId: clientId,
      email: email,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthTokens &&
          runtimeType == other.runtimeType &&
          accessToken == other.accessToken &&
          refreshToken == other.refreshToken &&
          expiresIn == other.expiresIn &&
          clientId == other.clientId &&
          email == other.email;

  @override
  int get hashCode =>
      accessToken.hashCode ^
      refreshToken.hashCode ^
      expiresIn.hashCode ^
      clientId.hashCode ^
      (email?.hashCode ?? 0);

  @override
  String toString() =>
      'AuthTokens(hasAccessToken: ${accessToken.isNotEmpty}, '
      'hasRefreshToken: ${refreshToken.isNotEmpty}, '
      'hasClientId: ${clientId.isNotEmpty}, hasEmail: ${email != null})';

  static void logTokenDifferences(AuthTokens? oldTokens, AuthTokens newTokens) {
    dev.log(
      'Refreshed tokens. HadOldTokens: ${oldTokens != null}, '
      'EmailChanged: ${oldTokens?.email != newTokens.email}, '
      'ClientIdChanged: ${oldTokens?.clientId != newTokens.clientId}',
      level: 1000,
    );
  }
}
