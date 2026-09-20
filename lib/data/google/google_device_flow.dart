import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/entities/device_sign_in.dart';
import 'google_oauth_client.dart';

/// A refresh token Google no longer accepts; the caller has dropped its copy.
class GoogleSignInRevoked implements Exception {
  const GoogleSignInRevoked();
}

/// The OAuth 2.0 device flow against Google, without the storage.
///
/// One instance per sign-in the app owns — YouTube Music and the shared like
/// counter — each with its own [scope] and its own OAuth client credentials.
/// Everything here is about *getting* tokens; where they are kept and what
/// they are used for is the caller's business, which is why nothing in this
/// class knows about secure storage or the native side.
class GoogleDeviceFlow {
  GoogleDeviceFlow({
    required GoogleOAuthClient oauthClient,
    required this.scope,
    required this.label,
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
  })  : _oauth = oauthClient,
        _delay = delay ?? Future<void>.delayed,
        _clock = clock ?? DateTime.now;

  /// Added to the poll interval on each `slow_down` (RFC 8628 §3.5).
  static const _slowDownStep = Duration(seconds: 5);

  /// What this sign-in asks Google for; see [GoogleScopes].
  final String scope;

  /// Names this sign-in in debug logs, e.g. "YouTube Music".
  final String label;

  final GoogleOAuthClient _oauth;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _clock;

  Completer<void>? _cancelSignal;

  DateTime nowUtc() => _clock().toUtc();

  DateTime expiresAt(int expiresInSec) =>
      nowUtc().add(Duration(seconds: expiresInSec));

  /// Step 1: a code for the user to type on another device.
  Future<DeviceSignInPrompt> start(OAuthClientCredentials credentials) async {
    try {
      final code = await _oauth.requestDeviceCode(
        clientId: credentials.clientId,
        scope: scope,
      );
      return DeviceSignInPrompt(
        deviceCode: code.deviceCode,
        userCode: code.userCode,
        verificationUrl: code.verificationUrl,
        expiresAt: expiresAt(code.expiresInSec),
        pollInterval: Duration(seconds: code.intervalSec),
      );
    } on GoogleOAuthException catch (e) {
      throw mapOAuthError(e);
    } on FormatException {
      throw const DeviceSignInException(
        DeviceSignInFailure.other,
        'Google sent an unexpected answer. Try again in a moment.',
      );
    } catch (_) {
      throw networkError;
    }
  }

  /// Step 2: polls until [prompt] is approved and returns the granted tokens.
  /// Storing them is the caller's job. Throws [DeviceSignInException] for
  /// every failure, including [DeviceSignInFailure.cancelled] after [cancel].
  Future<GoogleTokenResponse> waitForApproval(
    DeviceSignInPrompt prompt,
    OAuthClientCredentials credentials,
  ) async {
    _cancelSignal?.complete();
    final cancel = Completer<void>();
    _cancelSignal = cancel;
    var interval = prompt.pollInterval;

    try {
      while (true) {
        await Future.any(<Future<void>>[_delay(interval), cancel.future]);
        if (cancel.isCompleted) throw cancelledError;
        if (!nowUtc().isBefore(prompt.expiresAt)) throw expiredError;

        final DevicePollResult result;
        try {
          result = await _oauth.pollDeviceToken(
            clientId: credentials.clientId,
            clientSecret: credentials.clientSecret,
            deviceCode: prompt.deviceCode,
          );
        } on GoogleOAuthException catch (e) {
          if (cancel.isCompleted) throw cancelledError;
          throw mapOAuthError(e);
        } on FormatException {
          throw const DeviceSignInException(
            DeviceSignInFailure.other,
            'Google sent an unexpected answer. Tap Connect to try again.',
          );
        } catch (error) {
          // A dropped connection shouldn't lose a code the user may be
          // approving right now: keep polling until the code expires.
          debugPrint('$label device poll failed, retrying: $error');
          continue;
        }
        if (cancel.isCompleted) throw cancelledError;

        switch (result) {
          case DevicePollPending():
            continue;
          case DevicePollSlowDown():
            interval += _slowDownStep;
            continue;
          case DevicePollGranted(:final tokens):
            return tokens;
        }
      }
    } finally {
      if (identical(_cancelSignal, cancel)) _cancelSignal = null;
    }
  }

  /// Stops a running [waitForApproval]. No-op when none is running.
  void cancel() {
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// The refresh_token grant. `invalid_grant` means the sign-in is gone
  /// (revoked, password changed, 6 months unused, or a Testing-mode consent
  /// screen's 7-day limit) and comes back as [GoogleSignInRevoked] so the
  /// caller can drop its tokens instead of failing on every like.
  Future<GoogleTokenResponse> refresh({
    required OAuthClientCredentials credentials,
    required String refreshToken,
  }) async {
    try {
      return await _oauth.refreshAccessToken(
        clientId: credentials.clientId,
        clientSecret: credentials.clientSecret,
        refreshToken: refreshToken,
      );
    } on GoogleOAuthException catch (e) {
      if (e.error == 'invalid_grant') throw const GoogleSignInRevoked();
      rethrow;
    }
  }

  /// [credentials] as something usable, or the "type them in first" error.
  static OAuthClientCredentials require(OAuthClientCredentials? credentials) {
    if (credentials == null || !credentials.isComplete) {
      throw const DeviceSignInException(
        DeviceSignInFailure.missingCredentials,
        'Enter your Google client ID and client secret first.',
      );
    }
    return credentials;
  }

  static DeviceSignInException mapOAuthError(GoogleOAuthException e) {
    switch (e.error) {
      case 'access_denied':
        return const DeviceSignInException(
          DeviceSignInFailure.denied,
          'Sign-in was declined on the Google page. Tap Connect to try again.',
        );
      case 'expired_token':
        return expiredError;
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
          'Google refused the scope this sign-in needs. Use a '
          '"TVs and Limited Input devices" OAuth client with the right API '
          'enabled in the same project.',
        );
      default:
        final detail = e.description ?? e.error;
        return DeviceSignInException(
          DeviceSignInFailure.other,
          'Google sign-in failed: $detail',
        );
    }
  }

  static const expiredError = DeviceSignInException(
    DeviceSignInFailure.expired,
    'The code expired before it was approved. Tap Connect to get a new one.',
  );
  static const cancelledError = DeviceSignInException(
    DeviceSignInFailure.cancelled,
    'Sign-in cancelled.',
  );
  static const networkError = DeviceSignInException(
    DeviceSignInFailure.network,
    "Couldn't reach Google. Check your connection and try again.",
  );
  static const noRefreshTokenError = DeviceSignInException(
    DeviceSignInFailure.other,
    'Google did not return a refresh token. Tap Connect to try again.',
  );
}
