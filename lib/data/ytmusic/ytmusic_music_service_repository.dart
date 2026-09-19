import 'dart:async';

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
import 'google_oauth_client.dart';
import 'ytmusic_token_store.dart';

/// YouTube Music: Google sign-in via the OAuth 2.0 device flow with a
/// "TVs and Limited Input devices" client the user creates.
///
/// Tokens live in their own secure-storage keys ([YouTubeMusicTokenStore]) and
/// are mirrored to the native side (`syncYouTubeMusicTokens`), which does the
/// like itself in the background. The Dart side never likes: a like request
/// here throws, so nothing is sent to another service by mistake.
class YouTubeMusicServiceRepository
    implements MusicServiceRepository, DeviceSignInRepository {
  YouTubeMusicServiceRepository({
    required GoogleOAuthClient oauthClient,
    required YouTubeMusicTokenStore tokenStore,
    required PlatformServiceRepository platformServiceRepository,
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
  })  : _oauth = oauthClient,
        _tokenStore = tokenStore,
        _platform = platformServiceRepository,
        _delay = delay ?? Future<void>.delayed,
        _clock = clock ?? DateTime.now;

  static const _provider = MusicProvider.ytmusic;

  /// Refresh this long before the access token expires.
  static const _refreshMargin = Duration(minutes: 5);

  /// Added to the poll interval on each `slow_down` (RFC 8628 §3.5).
  static const _slowDownStep = Duration(seconds: 5);

  final GoogleOAuthClient _oauth;
  final YouTubeMusicTokenStore _tokenStore;
  final PlatformServiceRepository _platform;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _clock;

  Completer<void>? _cancelSignal;

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
    } on _SignInRevoked {
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
    } on _SignInRevoked {
      throw const MusicServiceNotConnectedException(_provider);
    }
  }

  bool _needsRefresh(YouTubeMusicTokens tokens) =>
      tokens.accessToken.isEmpty ||
      !_clock().toUtc().add(_refreshMargin).isBefore(tokens.expiresAt);

  /// Uses the refresh_token grant. `invalid_grant` means the sign-in is gone
  /// (revoked, password changed, 6 months unused, or a Testing-mode consent
  /// screen's 7-day limit), so local tokens are dropped and the user sees
  /// "not connected" instead of failing on every like.
  Future<YouTubeMusicTokens> _refresh(YouTubeMusicTokens tokens) async {
    final credentials = await _tokenStore.readCredentials();
    if (credentials == null || !credentials.isComplete) {
      throw StateError('YouTube Music client ID/secret missing; cannot refresh');
    }
    final GoogleTokenResponse response;
    try {
      response = await _oauth.refreshAccessToken(
        clientId: credentials.clientId,
        clientSecret: credentials.clientSecret,
        refreshToken: tokens.refreshToken,
      );
    } on GoogleOAuthException catch (e) {
      if (e.error == 'invalid_grant') {
        await disconnect();
        throw const _SignInRevoked();
      }
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
  Future<DeviceSignInPrompt> startSignIn() async {
    final credentials = await _requireCredentials();
    try {
      final code = await _oauth.requestDeviceCode(clientId: credentials.clientId);
      return DeviceSignInPrompt(
        deviceCode: code.deviceCode,
        userCode: code.userCode,
        verificationUrl: code.verificationUrl,
        expiresAt: _clock().toUtc().add(Duration(seconds: code.expiresInSec)),
        pollInterval: Duration(seconds: code.intervalSec),
      );
    } on GoogleOAuthException catch (e) {
      throw _mapOAuthError(e);
    } on FormatException {
      throw const DeviceSignInException(
        DeviceSignInFailure.other,
        'Google sent an unexpected answer. Try again in a moment.',
      );
    } catch (_) {
      throw _networkError;
    }
  }

  @override
  Future<SpotifyAuthState> waitForApproval(DeviceSignInPrompt prompt) async {
    final credentials = await _requireCredentials();
    _cancelSignal?.complete();
    final cancel = Completer<void>();
    _cancelSignal = cancel;
    var interval = prompt.pollInterval;

    try {
      while (true) {
        await Future.any(<Future<void>>[_delay(interval), cancel.future]);
        if (cancel.isCompleted) throw _cancelled;
        if (!_clock().toUtc().isBefore(prompt.expiresAt)) throw _expired;

        final DevicePollResult result;
        try {
          result = await _oauth.pollDeviceToken(
            clientId: credentials.clientId,
            clientSecret: credentials.clientSecret,
            deviceCode: prompt.deviceCode,
          );
        } on GoogleOAuthException catch (e) {
          if (cancel.isCompleted) throw _cancelled;
          throw _mapOAuthError(e);
        } on FormatException {
          throw const DeviceSignInException(
            DeviceSignInFailure.other,
            'Google sent an unexpected answer. Tap Connect to try again.',
          );
        } catch (error) {
          // A dropped connection shouldn't lose a code the user may be
          // approving right now: keep polling until the code expires.
          debugPrint('YouTube Music device poll failed, retrying: $error');
          continue;
        }
        if (cancel.isCompleted) throw _cancelled;

        switch (result) {
          case DevicePollPending():
            continue;
          case DevicePollSlowDown():
            interval += _slowDownStep;
            continue;
          case DevicePollGranted(:final tokens):
            return _completeSignIn(tokens, credentials);
        }
      }
    } finally {
      if (identical(_cancelSignal, cancel)) _cancelSignal = null;
    }
  }

  @override
  void cancelSignIn() {
    final cancel = _cancelSignal;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  Future<SpotifyAuthState> _completeSignIn(
    GoogleTokenResponse response,
    OAuthClientCredentials credentials,
  ) async {
    final refresh = response.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const DeviceSignInException(
        DeviceSignInFailure.other,
        'Google did not return a refresh token. Tap Connect to try again.',
      );
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

  Future<OAuthClientCredentials> _requireCredentials() async {
    final credentials = await _tokenStore.readCredentials();
    if (credentials == null || !credentials.isComplete) {
      throw const DeviceSignInException(
        DeviceSignInFailure.missingCredentials,
        'Enter your Google client ID and client secret first.',
      );
    }
    return credentials;
  }

  static DeviceSignInException _mapOAuthError(GoogleOAuthException e) {
    switch (e.error) {
      case 'access_denied':
        return const DeviceSignInException(
          DeviceSignInFailure.denied,
          'Sign-in was declined on the Google page. Tap Connect to try again.',
        );
      case 'expired_token':
        return _expired;
      case 'invalid_client':
      case 'unauthorized_client':
        return const DeviceSignInException(
          DeviceSignInFailure.invalidClient,
          'Google rejected the client ID or secret. Check that both come from '
          'a "TVs and Limited Input devices" OAuth client.',
        );
      case 'invalid_scope':
        return const DeviceSignInException(
          DeviceSignInFailure.other,
          'Google refused the YouTube scope for this client. Use a '
          '"TVs and Limited Input devices" OAuth client.',
        );
      default:
        final detail = e.description ?? e.error;
        return DeviceSignInException(
          DeviceSignInFailure.other,
          'Google sign-in failed: $detail',
        );
    }
  }

  static const _expired = DeviceSignInException(
    DeviceSignInFailure.expired,
    'The code expired before it was approved. Tap Connect to get a new one.',
  );
  static const _cancelled = DeviceSignInException(
    DeviceSignInFailure.cancelled,
    'Sign-in cancelled.',
  );
  static const _networkError = DeviceSignInException(
    DeviceSignInFailure.network,
    "Couldn't reach Google. Check your connection and try again.",
  );

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
      userSub: tokens.userSub,
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
  Future<LikeResult> likeCurrentTrack() => _likeUnavailable();

  @override
  Future<LikeResult> likeTrack(TrackInfo trackInfo) => _likeUnavailable();

  Future<LikeResult> _likeUnavailable() async {
    if (!(await getAuthState()).connected) {
      throw const MusicServiceNotConnectedException(_provider);
    }
    throw UnsupportedError(
      'Liking on ${_provider.displayName} from the app is not available yet.',
    );
  }

  /// Queued likes are left in place; nothing is processed for YouTube Music.
  @override
  Future<int> processPendingLikes(List<PendingLike> pending) async => 0;

  @override
  Future<Map<String, Map<String, int>>> loadAllLikeCounts() async =>
      <String, Map<String, int>>{
        'tracks': <String, int>{},
        'artists': <String, int>{},
      };
}

/// The refresh token no longer works; local tokens were cleared.
class _SignInRevoked implements Exception {
  const _SignInRevoked();
}
