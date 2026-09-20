import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/entities/music_service_exceptions.dart';

/// Google's OAuth 2.0 endpoints for the device flow ("TVs and Limited Input
/// devices" clients): https://developers.google.com/identity/protocols/oauth2/limited-input-device
class GoogleOAuthClient {
  GoogleOAuthClient(this._http);

  final http.Client _http;

  static final Uri deviceCodeUri =
      Uri.parse('https://oauth2.googleapis.com/device/code');
  static final Uri tokenUri = Uri.parse('https://oauth2.googleapis.com/token');

  /// `youtube` to rate videos, `openid` for the id_token `sub` that keys the
  /// account.
  static const String scope = 'https://www.googleapis.com/auth/youtube openid';
  static const String deviceCodeGrantType =
      'urn:ietf:params:oauth:grant-type:device_code';

  static const Duration _timeout = Duration(seconds: 10);

  /// Step 1: asks Google for a user code to show.
  Future<GoogleDeviceCode> requestDeviceCode({required String clientId}) async {
    final json = await _post(deviceCodeUri, <String, String>{
      'client_id': clientId,
      'scope': scope,
    });
    return GoogleDeviceCode.fromJson(json);
  }

  /// Step 2: one poll of the token endpoint. Keep-polling answers come back as
  /// [DevicePollPending] / [DevicePollSlowDown]; terminal errors
  /// (`access_denied`, `expired_token`, ...) throw [GoogleOAuthException].
  Future<DevicePollResult> pollDeviceToken({
    required String clientId,
    required String clientSecret,
    required String deviceCode,
  }) async {
    try {
      final json = await _post(tokenUri, <String, String>{
        'client_id': clientId,
        'client_secret': clientSecret,
        'device_code': deviceCode,
        'grant_type': deviceCodeGrantType,
      });
      return DevicePollGranted(GoogleTokenResponse.fromJson(json));
    } on GoogleOAuthException catch (e) {
      switch (e.error) {
        case 'authorization_pending':
          return const DevicePollPending();
        case 'slow_down':
          return const DevicePollSlowDown();
        default:
          rethrow;
      }
    }
  }

  /// Gets a new access token with no user interaction. Google usually does
  /// not return a new refresh token here, so [GoogleTokenResponse.refreshToken]
  /// is often null.
  Future<GoogleTokenResponse> refreshAccessToken({
    required String clientId,
    required String clientSecret,
    required String refreshToken,
  }) async {
    final json = await _post(tokenUri, <String, String>{
      'client_id': clientId,
      'client_secret': clientSecret,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    });
    return GoogleTokenResponse.fromJson(json);
  }

  Future<Map<String, dynamic>> _post(Uri uri, Map<String, String> body) async {
    final response = await _http
        .post(
          uri,
          headers: const <String, String>{
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: body,
        )
        .timeout(_timeout);

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } on FormatException {
      json = null;
    }

    if (response.statusCode >= 200 && response.statusCode < 300 && json != null) {
      return json;
    }

    final error = json?['error'];
    throw GoogleOAuthException(
      statusCode: response.statusCode,
      error: error is String ? error : 'http_${response.statusCode}',
      description: json?['error_description'] as String?,
    );
  }
}

/// Reads the `sub` claim from an id_token without verifying the signature.
///
/// Good enough here: the token came straight from Google's token endpoint
/// over TLS, and `sub` is only used to show and key the account. Returns
/// null for anything that isn't a well-formed JWT with a string `sub`.
String? decodeIdTokenSubject(String? idToken) {
  if (idToken == null) return null;
  final parts = idToken.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final claims = jsonDecode(payload);
    if (claims is! Map<String, dynamic>) return null;
    final sub = claims['sub'];
    return sub is String && sub.isNotEmpty ? sub : null;
  } on FormatException {
    return null;
  }
}

class GoogleDeviceCode {
  const GoogleDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresInSec,
    required this.intervalSec,
  });

  factory GoogleDeviceCode.fromJson(Map<String, dynamic> json) {
    final deviceCode = json['device_code'];
    final userCode = json['user_code'];
    // Google sends `verification_url`; RFC 8628 names it `verification_uri`.
    final url = json['verification_url'] ?? json['verification_uri'];
    if (deviceCode is! String || userCode is! String || url is! String) {
      throw const FormatException('Malformed device code response');
    }
    return GoogleDeviceCode(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUrl: url,
      expiresInSec: (json['expires_in'] as num?)?.toInt() ?? 1800,
      intervalSec: (json['interval'] as num?)?.toInt() ?? 5,
    );
  }

  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final int expiresInSec;
  final int intervalSec;
}

class GoogleTokenResponse {
  const GoogleTokenResponse({
    required this.accessToken,
    required this.expiresInSec,
    this.refreshToken,
    this.idToken,
  });

  factory GoogleTokenResponse.fromJson(Map<String, dynamic> json) {
    final access = json['access_token'];
    if (access is! String || access.isEmpty) {
      throw const FormatException('Token response has no access_token');
    }
    return GoogleTokenResponse(
      accessToken: access,
      expiresInSec: (json['expires_in'] as num?)?.toInt() ?? 3600,
      refreshToken: json['refresh_token'] as String?,
      idToken: json['id_token'] as String?,
    );
  }

  final String accessToken;
  final int expiresInSec;
  final String? refreshToken;
  final String? idToken;
}

/// Outcome of one device-flow poll that doesn't end the flow with an error.
sealed class DevicePollResult {
  const DevicePollResult();
}

class DevicePollGranted extends DevicePollResult {
  const DevicePollGranted(this.tokens);
  final GoogleTokenResponse tokens;
}

/// `authorization_pending`: the user hasn't approved yet.
class DevicePollPending extends DevicePollResult {
  const DevicePollPending();
}

/// `slow_down`: polling too often; add 5 seconds to the interval.
class DevicePollSlowDown extends DevicePollResult {
  const DevicePollSlowDown();
}

/// An OAuth error response (`{"error": "...", "error_description": "..."}`)
/// or any non-2xx answer from Google's OAuth endpoints.
class GoogleOAuthException implements MusicServiceHttpException {
  const GoogleOAuthException({
    required this.statusCode,
    required this.error,
    this.description,
  });

  @override
  final int statusCode;

  /// The OAuth `error` code, e.g. `access_denied`, `invalid_grant`.
  final String error;
  final String? description;

  @override
  String toString() =>
      'Google OAuth error $statusCode: $error${description == null ? '' : ' ($description)'}';
}
