import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What a `--dart-define-from-file=.env` build was compiled with. Only ever a
/// seed for [SpotifyTokenStore.seedClientId]; once the store holds a client
/// ID, that wins.
const _envSpotifyClientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');

class SpotifyTokenStore {
  static const _keyAccess = 'spotify_access';
  static const _keyRefresh = 'spotify_refresh';
  static const _keyExpiryEpoch = 'spotify_expiry_epoch';
  static const _keyClientId = 'spotify_client_id';

  final FlutterSecureStorage _storage;

  SpotifyTokenStore(this._storage);

  Future<void> save({
    required String accessToken,
    required String refreshToken,
    required int expiresAtEpochSec,
  }) async {
    await _storage.write(key: _keyAccess, value: accessToken);
    await _storage.write(key: _keyRefresh, value: refreshToken);
    await _storage.write(key: _keyExpiryEpoch, value: expiresAtEpochSec.toString());
  }

  Future<String?> readAccessToken() => _storage.read(key: _keyAccess);

  Future<String?> readRefreshToken() => _storage.read(key: _keyRefresh);

  Future<int?> readExpiryEpochSec() async {
    final raw = await _storage.read(key: _keyExpiryEpoch);
    return int.tryParse(raw ?? '');
  }

  /// Disconnects; the client ID stays, so reconnecting needs no retyping —
  /// the same bargain `YouTubeMusicTokenStore.clearTokens` makes.
  Future<void> clear() async {
    await _storage.delete(key: _keyAccess);
    await _storage.delete(key: _keyRefresh);
    await _storage.delete(key: _keyExpiryEpoch);
  }

  /// The Spotify app's client ID, typed into *Connected services*. PKCE means
  /// there is no client secret to go with it.
  Future<void> saveClientId(String clientId) =>
      _storage.write(key: _keyClientId, value: clientId);

  Future<String?> readClientId() => _storage.read(key: _keyClientId);

  /// Carries a build-time `--dart-define` client ID into the store, once, so
  /// an install built from `.env` stays connected without retyping it.
  ///
  /// Only a store that has never been written is seeded: after that what the
  /// user typed wins, including a deliberately cleared value.
  Future<void> seedClientId({String clientId = _envSpotifyClientId}) async {
    if (clientId.isEmpty) return;
    if (await _storage.read(key: _keyClientId) != null) return;
    await saveClientId(clientId);
  }
}
