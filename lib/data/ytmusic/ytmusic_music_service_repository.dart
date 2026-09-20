import 'package:flutter/foundation.dart';

import '../../domain/entities/device_sign_in.dart';
import '../../domain/entities/like_result.dart';
import '../../domain/entities/music_provider.dart';
import '../../domain/entities/music_service_exceptions.dart';
import '../../domain/entities/pending_like.dart';
import '../../domain/entities/spotify_auth_state.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/repositories/device_sign_in_repository.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../../domain/services/like_counter_user_id.dart';
import '../google/google_device_flow.dart';
import '../google/google_oauth_client.dart';
import 'ytmusic_token_store.dart';

/// A YouTube Music like that did not go through.
class YouTubeMusicLikeException implements Exception {
  const YouTubeMusicLikeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A YouTube Music like the Data API rejected with an HTTP status.
class YouTubeMusicLikeHttpException extends YouTubeMusicLikeException
    implements MusicServiceHttpException {
  const YouTubeMusicLikeHttpException(super.message, this.statusCode);

  @override
  final int statusCode;
}

/// YouTube Music on Android.
///
/// Liking is native (`YouTubeMusicLiker.kt`): a thumbs-up through the YouTube
/// Music app's media session, which needs no sign-in, with the YouTube Data
/// API as fallback when the session rating doesn't take. The same code runs
/// when the trigger fires with no Flutter UI attached, so the screen-off path
/// and this one behave identically.
///
/// Google sign-in uses the OAuth 2.0 device flow with a "TVs and Limited Input
/// devices" client the user creates. Tokens live in their own secure-storage
/// keys ([YouTubeMusicTokenStore]) and are mirrored to the native side
/// (`syncYouTubeMusicTokens`), where the Data API fallback uses them.
class YouTubeMusicServiceRepository
    implements MusicServiceRepository, DeviceSignInRepository {
  YouTubeMusicServiceRepository({
    required GoogleOAuthClient oauthClient,
    required YouTubeMusicTokenStore tokenStore,
    required PlatformServiceRepository platformServiceRepository,
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
  })  : _flow = GoogleDeviceFlow(
          oauthClient: oauthClient,
          scope: GoogleScopes.youTubeMusic,
          label: 'YouTube Music',
          delay: delay,
          clock: clock,
        ),
        _tokenStore = tokenStore,
        _platform = platformServiceRepository,
        _clock = clock ?? DateTime.now;

  static const _provider = MusicProvider.ytmusic;

  /// Refresh this long before the access token expires.
  static const _refreshMargin = Duration(minutes: 5);

  final GoogleDeviceFlow _flow;
  final YouTubeMusicTokenStore _tokenStore;
  final PlatformServiceRepository _platform;
  final DateTime Function() _clock;

  // ── Credentials ────────────────────────────────────────────────────────

  @override
  Future<OAuthClientCredentials?> loadClientCredentials() =>
      _tokenStore.readCredentials();

  @override
  Future<void> saveClientCredentials(OAuthClientCredentials credentials) =>
      _tokenStore.saveCredentials(OAuthClientCredentials(
        clientId: credentials.clientId.trim(),
        clientSecret: credentials.clientSecret.trim(),
      ));

  // ── Auth state + silent refresh ────────────────────────────────────────

  @override
  Future<SpotifyAuthState> getAuthState() async {
    final tokens = await _tokenStore.readTokens();
    if (tokens == null) return const SpotifyAuthState.disconnected();
    if (!_needsRefresh(tokens)) return _toAuthState(tokens);
    try {
      return _toAuthState(await _refresh(tokens));
    } on GoogleSignInRevoked {
      return const SpotifyAuthState.disconnected();
    } catch (error, stackTrace) {
      // Offline or Google hiccup: still signed in, the refresh retries later.
      debugPrint('YouTube Music refresh skipped in getAuthState: $error\n$stackTrace');
      return _toAuthState(tokens);
    }
  }

  @override
  Future<void> refreshIfNeeded() async {
    final tokens = await _tokenStore.readTokens();
    if (tokens == null || !_needsRefresh(tokens)) return;
    try {
      await _refresh(tokens);
    } on GoogleSignInRevoked {
      throw const MusicServiceNotConnectedException(_provider);
    }
  }

  bool _needsRefresh(YouTubeMusicTokens tokens) =>
      tokens.accessToken.isEmpty ||
      !_clock().toUtc().add(_refreshMargin).isBefore(tokens.expiresAt);

  /// Uses the refresh_token grant. A [GoogleSignInRevoked] means the sign-in
  /// is gone for good, so local tokens are dropped and the user sees "not
  /// connected" instead of failing on every like.
  Future<YouTubeMusicTokens> _refresh(YouTubeMusicTokens tokens) async {
    final credentials = await _tokenStore.readCredentials();
    if (credentials == null || !credentials.isComplete) {
      throw StateError('YouTube Music client ID/secret missing; cannot refresh');
    }
    final GoogleTokenResponse response;
    try {
      response = await _flow.refresh(
        credentials: credentials,
        refreshToken: tokens.refreshToken,
      );
    } on GoogleSignInRevoked {
      await disconnect();
      rethrow;
    }
    final refreshed = YouTubeMusicTokens(
      accessToken: response.accessToken,
      refreshToken: response.refreshToken ?? tokens.refreshToken,
      expiresAt: _expiresAt(response.expiresInSec),
      userSub: decodeIdTokenSubject(response.idToken) ?? tokens.userSub,
    );
    await _store(refreshed, credentials);
    return refreshed;
  }

  // ── Device flow ────────────────────────────────────────────────────────

  @override
  Future<DeviceSignInPrompt> startSignIn() async =>
      _flow.start(await _requireCredentials());

  @override
  Future<SpotifyAuthState> waitForApproval(DeviceSignInPrompt prompt) async {
    final credentials = await _requireCredentials();
    return _completeSignIn(
      await _flow.waitForApproval(prompt, credentials),
      credentials,
    );
  }

  @override
  void cancelSignIn() => _flow.cancel();

  Future<SpotifyAuthState> _completeSignIn(
    GoogleTokenResponse response,
    OAuthClientCredentials credentials,
  ) async {
    final refresh = response.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw GoogleDeviceFlow.noRefreshTokenError;
    }
    final tokens = YouTubeMusicTokens(
      accessToken: response.accessToken,
      refreshToken: refresh,
      expiresAt: _expiresAt(response.expiresInSec),
      userSub: decodeIdTokenSubject(response.idToken),
    );
    await _store(tokens, credentials);
    return _toAuthState(tokens);
  }

  Future<OAuthClientCredentials> _requireCredentials() async =>
      GoogleDeviceFlow.require(await _tokenStore.readCredentials());

  // ── Storage ────────────────────────────────────────────────────────────

  DateTime _expiresAt(int expiresInSec) =>
      _clock().toUtc().add(Duration(seconds: expiresInSec));

  Future<void> _store(
    YouTubeMusicTokens tokens,
    OAuthClientCredentials credentials,
  ) async {
    await _tokenStore.saveTokens(tokens);
    await _platform.syncYouTubeMusicTokens(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      expiresAtEpochMs: tokens.expiresAt.millisecondsSinceEpoch,
      clientId: credentials.clientId,
      clientSecret: credentials.clientSecret,
      // The native liker keys the shared like counter with this id (#96).
      userSub: likeCounterUserId(_provider, youTubeMusicSub: tokens.userSub),
    );
  }

  SpotifyAuthState _toAuthState(YouTubeMusicTokens tokens) => SpotifyAuthState(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAt: tokens.expiresAt,
        connected: true,
        accountId: tokens.userSub,
      );

  // ── MusicServiceRepository ─────────────────────────────────────────────

  /// Device sign-in needs the code shown on screen, so it runs through
  /// [startSignIn] / [waitForApproval] from Connected services instead.
  @override
  Future<SpotifyAuthState> connect() async {
    throw UnsupportedError(
      '${_provider.displayName} signs in with a device code: use Connect on '
      'the Connected services screen.',
    );
  }

  @override
  Future<void> disconnect() async {
    cancelSignIn();
    await _tokenStore.clearTokens();
    await _platform.clearYouTubeMusicTokens();
  }

  @override
  Future<bool> handleAuthCallback(Uri uri) async => false;

  @override
  Future<LikeResult> likeCurrentTrack() async {
    final reply = await _platform.likeYouTubeMusicCurrentTrack();
    final trackName = reply['trackName'] as String? ?? _provider.displayName;
    // The shared counter's new value; absent when the like was not counted
    // (not signed in, no shared counter, or the counter did not answer).
    final likeCount = reply['likeCount'];
    final trackLikeCount = likeCount is int ? likeCount : 0;
    switch (reply['outcome']) {
      case 'liked':
        return LikeResult(
          trackId: '',
          trackName: trackName,
          trackLiked: true,
          trackLikeCount: trackLikeCount,
        );
      case 'already_liked':
        return LikeResult(
          trackId: '',
          trackName: trackName,
          trackLiked: true,
          alreadyLiked: true,
          trackLikeCount: trackLikeCount,
        );
      case 'cooldown':
        return LikeResult(
          trackId: '',
          trackName: trackName,
          trackLiked: false,
          skippedCooldown: true,
        );
      default:
        final message = reply['message'] as String? ?? 'like failed';
        final httpCode = reply['httpCode'];
        if (httpCode is int) {
          throw YouTubeMusicLikeHttpException(message, httpCode);
        }
        throw YouTubeMusicLikeException(message);
    }
  }

  /// The session can only like what is playing now, so there is no way to
  /// like an arbitrary track from here.
  @override
  Future<LikeResult> likeTrack(TrackInfo trackInfo) async {
    throw const YouTubeMusicLikeException(
      'YouTube Music can only like the song that is playing',
    );
  }

  /// YouTube Music likes are never queued (see `AppController.queueTrackForLater`):
  /// the like targets whatever is playing, so a replay would hit another song.
  @override
  Future<int> processPendingLikes(List<PendingLike> pending) async => 0;

  @override
  Future<Map<String, Map<String, int>>> loadAllLikeCounts() async =>
      <String, Map<String, int>>{
        'tracks': <String, int>{},
        'artists': <String, int>{},
      };
}
