import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/entities/device_sign_in.dart';
import '../../domain/entities/like_counter_config.dart';

/// What a `--dart-define-from-file=.env` build was compiled with. Only ever a
/// seed for [LikeCounterStore.seed]; once the store holds a value, that wins.
const _envSpreadsheetId = String.fromEnvironment('COUNTER_SPREADSHEET_ID');
const _envClientId = String.fromEnvironment('COUNTER_GOOGLE_CLIENT_ID');
const _envClientSecret = String.fromEnvironment('COUNTER_GOOGLE_CLIENT_SECRET');

/// The shared like counter's spreadsheet and Google sign-in, kept next to the
/// music services' tokens under their own `counter_*` keys.
class LikeCounterStore {
  LikeCounterStore(this._storage);

  static const _keySpreadsheetId = 'counter_spreadsheet_id';
  static const _keyClientId = 'counter_google_client_id';
  static const _keyClientSecret = 'counter_google_client_secret';
  static const _keyAccess = 'counter_google_access';
  static const _keyRefresh = 'counter_google_refresh';
  static const _keyExpiryEpochMs = 'counter_google_expiry_epoch_ms';

  final FlutterSecureStorage _storage;

  /// [LikeCounterConfig.empty] until something is stored: no counter set up is
  /// the normal state, not an error.
  Future<LikeCounterConfig> read() async {
    final expiryMs =
        int.tryParse(await _storage.read(key: _keyExpiryEpochMs) ?? '');
    return LikeCounterConfig(
      spreadsheetId: await _storage.read(key: _keySpreadsheetId) ?? '',
      clientId: await _storage.read(key: _keyClientId) ?? '',
      clientSecret: await _storage.read(key: _keyClientSecret) ?? '',
      accessToken: await _storage.read(key: _keyAccess) ?? '',
      refreshToken: await _storage.read(key: _keyRefresh) ?? '',
      expiresAt: expiryMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiryMs, isUtc: true),
    );
  }

  /// The sheet to count in, typed into *Connected services*. An empty string
  /// turns the shared counter off without disturbing the sign-in.
  Future<void> saveSpreadsheetId(String spreadsheetId) =>
      _storage.write(key: _keySpreadsheetId, value: spreadsheetId);

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

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
  }) async {
    await _storage.write(key: _keyAccess, value: accessToken);
    await _storage.write(key: _keyRefresh, value: refreshToken);
    await _storage.write(
      key: _keyExpiryEpochMs,
      value: expiresAt.millisecondsSinceEpoch.toString(),
    );
  }

  /// Signs out; the client credentials and the spreadsheet id stay, so
  /// reconnecting needs no retyping.
  Future<void> clearTokens() async {
    await _storage.delete(key: _keyAccess);
    await _storage.delete(key: _keyRefresh);
    await _storage.delete(key: _keyExpiryEpochMs);
  }

  /// Carries a build-time `--dart-define` setup into the store, once, so an
  /// install built from `.env` keeps counting without retyping anything. The
  /// sign-in itself is never seeded — only the user can approve that.
  ///
  /// Only a key that has never been written is seeded: after that what the
  /// user typed wins, including a deliberately cleared value. Half a
  /// credential pair is no credential, so both halves have to be there.
  Future<void> seed({
    String spreadsheetId = _envSpreadsheetId,
    String clientId = _envClientId,
    String clientSecret = _envClientSecret,
  }) async {
    if (spreadsheetId.isNotEmpty &&
        await _storage.read(key: _keySpreadsheetId) == null) {
      await saveSpreadsheetId(spreadsheetId);
    }
    if (clientId.isEmpty || clientSecret.isEmpty) return;
    if (await _storage.read(key: _keyClientId) != null) return;
    if (await _storage.read(key: _keyClientSecret) != null) return;
    await saveCredentials(
      OAuthClientCredentials(clientId: clientId, clientSecret: clientSecret),
    );
  }
}
