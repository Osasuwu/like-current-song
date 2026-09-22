import '../google/google_oauth_client.dart';

/// Google would not renew the counter's access token, in words a user can
/// read.
///
/// The counter's token is short-lived, so the refresh grant runs on most
/// likes and is where sign-in trouble surfaces. A refusal used to reach the
/// Logs screen as nothing at all — the reason went to `debugPrint`, invisible
/// in a release build, and the like was reported as "not signed in" whatever
/// had actually happened (#200). This carries the reason instead, so the log
/// line can name it and the user can act on it.
///
/// A *revoked* sign-in is not one of these: that one really is fixed by
/// signing in again, so [LikeCounterAccount.freshAccessToken] keeps answering
/// null for it and the "sign in again" message stays correct.
class LikeCounterTokenRefused implements Exception {
  const LikeCounterTokenRefused(this.message, {this.statusCode});

  /// Turns whatever the refresh threw into a sentence and, when Google
  /// answered at all, the status it answered with.
  factory LikeCounterTokenRefused.from(Object error) => LikeCounterTokenRefused(
        likeCounterRefreshFailureMessage(error),
        statusCode: error is GoogleOAuthException ? error.statusCode : null,
      );

  /// Reads on the Logs screen; names the reason and, where there is one, the
  /// fix.
  final String message;

  /// Google's HTTP status, null when the request never got an answer.
  final int? statusCode;

  @override
  String toString() => message;
}

/// What went wrong renewing the counter's token, as one sentence.
///
/// Pure on purpose: the wording is the whole point of #200, so it is testable
/// without a token, a network or a store. It mirrors
/// `GoogleTokens.refreshFailureMessage` on the native side, which says the
/// same things about the same OAuth errors.
String likeCounterRefreshFailureMessage(Object error) {
  if (error is! GoogleOAuthException) {
    return "The counter's Google token could not be renewed: $error";
  }
  final detail = error.description == null
      ? error.error
      : '${error.error}: ${error.description}';
  switch (error.error) {
    case 'invalid_client':
    case 'unauthorized_client':
      return "Google rejected the counter's client ID or secret ($detail). "
          'Check both under Connected services → Shared like counter.';
    case 'invalid_scope':
      return 'Google refused the spreadsheet scope the counter needs '
          '($detail). Sign the counter in again under Connected services.';
    default:
      return "Google would not renew the counter's token ($detail).";
  }
}
