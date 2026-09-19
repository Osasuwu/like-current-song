/// Sign-in state of one music service.
///
/// Named for the first service it served; it is provider-neutral.
class SpotifyAuthState {
  final String? accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final bool connected;

  /// The signed-in account's stable id at the provider, when the provider
  /// reports one (YouTube Music: the Google id_token `sub`). Shown in the UI;
  /// null when unknown.
  final String? accountId;

  const SpotifyAuthState({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.connected,
    this.accountId,
  });

  const SpotifyAuthState.disconnected()
      : accessToken = null,
        refreshToken = null,
        expiresAt = null,
        connected = false,
        accountId = null;

  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!.toUtc());
}
