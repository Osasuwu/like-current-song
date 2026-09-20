import 'package:flutter/foundation.dart';

import '../../domain/entities/device_sign_in.dart';
import '../../domain/entities/like_counter_config.dart';
import '../../domain/entities/spotify_auth_state.dart';
import '../../domain/repositories/device_sign_in_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../google/google_device_flow.dart';
import '../google/google_oauth_client.dart';
import 'like_counter_store.dart';

/// The Google account the shared like counter writes its spreadsheet with.
///
/// Its own sign-in, with its own OAuth client, token set and scope
/// ([GoogleScopes.spreadsheets]) — separate from YouTube Music's, so the
/// counter works whichever music service is picked. The device flow itself is
/// the shared [GoogleDeviceFlow]; this class only owns the storage and the
/// mirror to the native side, where `LikeCounter.kt` counts the likes that
/// happen with no Flutter UI attached.
class LikeCounterAccount implements DeviceSignInRepository {
  LikeCounterAccount({
    required GoogleOAuthClient oauthClient,
    required LikeCounterStore store,
    required PlatformServiceRepository platformServiceRepository,
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
  })  : _flow = GoogleDeviceFlow(
          oauthClient: oauthClient,
          scope: GoogleScopes.spreadsheets,
          label: 'Shared like counter',
          delay: delay,
          clock: clock,
        ),
        _store = store,
        _platform = platformServiceRepository,
        _clock = clock ?? DateTime.now;

  /// Refresh this long before the access token expires.
  static const _refreshMargin = Duration(minutes: 5);

  final GoogleDeviceFlow _flow;
  final LikeCounterStore _store;
  final PlatformServiceRepository _platform;
  final DateTime Function() _clock;

  // ── Credentials ────────────────────────────────────────────────────────

  @override
  Future<OAuthClientCredentials?> loadClientCredentials() =>
      _store.readCredentials();

  @override
  Future<void> saveClientCredentials(OAuthClientCredentials credentials) async {
    await _store.saveCredentials(OAuthClientCredentials(
      clientId: credentials.clientId.trim(),
      clientSecret: credentials.clientSecret.trim(),
    ));
    await syncToNative();
  }

  // ── Device flow ────────────────────────────────────────────────────────

  @override
  Future<DeviceSignInPrompt> startSignIn() async =>
      _flow.start(GoogleDeviceFlow.require(await _store.readCredentials()));

  @override
  Future<SpotifyAuthState> waitForApproval(DeviceSignInPrompt prompt) async {
    final credentials = GoogleDeviceFlow.require(await _store.readCredentials());
    final tokens = await _flow.waitForApproval(prompt, credentials);
    final refresh = tokens.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw GoogleDeviceFlow.noRefreshTokenError;
    }
    final expiresAt = _flow.expiresAt(tokens.expiresInSec);
    await _store.saveTokens(
      accessToken: tokens.accessToken,
      refreshToken: refresh,
      expiresAt: expiresAt,
    );
    await syncToNative();
    return SpotifyAuthState(
      accessToken: tokens.accessToken,
      refreshToken: refresh,
      expiresAt: expiresAt,
      connected: true,
    );
  }

  @override
  void cancelSignIn() => _flow.cancel();

  /// Forgets the sign-in; the client credentials and the spreadsheet id stay.
  Future<void> signOut() async {
    cancelSignIn();
    await _store.clearTokens();
    await syncToNative();
  }

  // ── Tokens ─────────────────────────────────────────────────────────────

  /// An access token that is good right now, or null when the counter cannot
  /// speak for the user — not signed in, or Google would not say yes. Callers
  /// count locally instead of failing the like.
  Future<String?> freshAccessToken() async {
    final config = await _store.read();
    if (!config.isSignedIn || !config.hasCredentials) return null;
    final expiresAt = config.expiresAt;
    final stale = config.accessToken.isEmpty ||
        expiresAt == null ||
        !_clock().toUtc().add(_refreshMargin).isBefore(expiresAt);
    if (!stale) return config.accessToken;

    try {
      final response = await _flow.refresh(
        credentials: OAuthClientCredentials(
          clientId: config.clientId,
          clientSecret: config.clientSecret,
        ),
        refreshToken: config.refreshToken,
      );
      final refreshed = _flow.expiresAt(response.expiresInSec);
      await _store.saveTokens(
        accessToken: response.accessToken,
        refreshToken: response.refreshToken ?? config.refreshToken,
        expiresAt: refreshed,
      );
      await syncToNative();
      return response.accessToken;
    } on GoogleSignInRevoked {
      // The sign-in is gone for good: drop it so the user is told to sign in
      // again rather than every like failing silently.
      debugPrint('Shared like counter sign-in revoked; signing out');
      await signOut();
      return null;
    } catch (error) {
      debugPrint('Shared like counter token refresh failed: $error');
      return null;
    }
  }

  // ── Native mirror ──────────────────────────────────────────────────────

  /// Pushes the whole counter config to the native side, which counts likes
  /// that happen while no Flutter UI is running.
  Future<void> syncToNative() async {
    final config = await _store.read();
    await pushToNative(_platform, config);
  }

  /// The one place that knows how a [LikeCounterConfig] reaches the native
  /// side, so start-up, sign-in and *Connected services* all send the same
  /// thing.
  static Future<void> pushToNative(
    PlatformServiceRepository platform,
    LikeCounterConfig config,
  ) =>
      platform.syncLikeCounterConfig(
        spreadsheetId: config.spreadsheetId,
        clientId: config.clientId,
        clientSecret: config.clientSecret,
        accessToken: config.accessToken,
        refreshToken: config.refreshToken,
        expiresAtEpochMs: config.expiresAt?.millisecondsSinceEpoch ?? 0,
      );
}
