import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/entities/device_sign_in.dart';

/// YouTube Music's Google tokens, stored under their own keys so they live
/// next to Spotify's (`SpotifyTokenStore`) without touching them: switching
/// services keeps both signed in.
class YouTubeMusicTokens {
  const YouTubeMusicTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.userSub,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  /// The Google account's id_token `sub`: the provider user id.
  final String? userSub;
}

class YouTubeMusicTokenStore {
  YouTubeMusicTokenStore(this._storage);

  static const _keyAccess = 'ytmusic_access';
  static const _keyRefresh = 'ytmusic_refresh';
  static const _keyExpiryEpochMs = 'ytmusic_expiry_epoch_ms';
  static const _keyUserSub = 'ytmusic_user_sub';
  static const _keyClientId = 'ytmusic_client_id';
  static const _keyClientSecret = 'ytmusic_client_secret';

  final FlutterSecureStorage _storage;

  Future<void> saveTokens(YouTubeMusicTokens tokens) async {
    await _storage.write(key: _keyAccess, value: tokens.accessToken);
    await _storage.write(key: _keyRefresh, value: tokens.refreshToken);
    await _storage.write(
      key: _keyExpiryEpochMs,
      value: tokens.expiresAt.millisecondsSinceEpoch.toString(),
    );
    if (tokens.userSub == null) {
      await _storage.delete(key: _keyUserSub);
    } else {
      await _storage.write(key: _keyUserSub, value: tokens.userSub);
    }
  }

  /// Null unless a refresh token is stored: without one there is no sign-in.
  Future<YouTubeMusicTokens?> readTokens() async {
    final refresh = await _storage.read(key: _keyRefresh);
    if (refresh == null || refresh.isEmpty) return null;
    final expiryMs =
        int.tryParse(await _storage.read(key: _keyExpiryEpochMs) ?? '') ?? 0;
    return YouTubeMusicTokens(
      accessToken: await _storage.read(key: _keyAccess) ?? '',
      refreshToken: refresh,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiryMs, isUtc: true),
      userSub: await _storage.read(key: _keyUserSub),
    );
  }

  /// Signs out; the client credentials stay so reconnecting needs no retyping.
  Future<void> clearTokens() async {
    await _storage.delete(key: _keyAccess);
    await _storage.delete(key: _keyRefresh);
    await _storage.delete(key: _keyExpiryEpochMs);
    await _storage.delete(key: _keyUserSub);
  }

  Future<void> saveCredentials(OAuthClientCredentials credentials) async {
    await _storage.write(key: _keyClientId, value: credentials.clientId);
    await _storage.write(key: _keyClientSecret, value: credentials.clientSecret);
  }

  Future<OAuthClientCredentials?> readCredentials() async {
    final id = await _storage.read(key: _keyClientId);
    final secret = await _storage.read(key: _keyClientSecret);
    if (id == null && secret == null) return null;
    return OAuthClientCredentials(clientId: id ?? '', clientSecret: secret ?? '');
  }
}
