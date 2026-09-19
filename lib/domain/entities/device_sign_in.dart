/// An OAuth client the user created in their own Google Cloud project.
///
/// For the "TVs and Limited Input devices" client type the secret is not
/// confidential (Google documents it as such), but it is still kept in
/// secure storage.
class OAuthClientCredentials {
  const OAuthClientCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  final String clientId;
  final String clientSecret;

  bool get isComplete =>
      clientId.trim().isNotEmpty && clientSecret.trim().isNotEmpty;
}

/// What the user needs to approve a device sign-in on another screen: enter
/// [userCode] at [verificationUrl] before [expiresAt].
class DeviceSignInPrompt {
  const DeviceSignInPrompt({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresAt,
    required this.pollInterval,
  });

  /// Opaque handle the app polls with; never shown to the user.
  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final DateTime expiresAt;

  /// How often the token endpoint may be polled, as issued by the server.
  final Duration pollInterval;
}

/// Why a device sign-in did not complete.
enum DeviceSignInFailure {
  /// No client ID / secret entered yet.
  missingCredentials,

  /// Google rejected the client ID or secret.
  invalidClient,

  /// The user declined on the approval page.
  denied,

  /// The code expired before it was approved.
  expired,

  /// Google could not be reached.
  network,

  /// The user cancelled the sign-in in the app.
  cancelled,

  /// Anything else Google reported.
  other,
}

/// A device sign-in ended without tokens. [message] is ready to show the
/// user as-is.
class DeviceSignInException implements Exception {
  const DeviceSignInException(this.failure, this.message);

  final DeviceSignInFailure failure;
  final String message;

  @override
  String toString() => message;
}
