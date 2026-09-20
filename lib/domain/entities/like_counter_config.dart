/// Everything the shared like counter needs: the Google Sheet to count in and
/// the Google sign-in that may write to it.
///
/// All of it comes from the user (*Connected services* → *Shared like
/// counter*); with any part missing the counter stays on this device, which is
/// what [isConfigured] gates.
///
/// The sign-in is the counter's own, separate from the one YouTube Music uses,
/// so the counter keeps working whichever music service is picked. Nothing
/// stops the user pointing both at the same Google Cloud OAuth client.
class LikeCounterConfig {
  const LikeCounterConfig({
    this.spreadsheetId = '',
    this.clientId = '',
    this.clientSecret = '',
    this.accessToken = '',
    this.refreshToken = '',
    this.expiresAt,
  });

  /// Nothing set up: like counts stay local.
  static const empty = LikeCounterConfig();

  /// The spreadsheet's id — the long part of its URL between `/d/` and
  /// `/edit`. It must hold a `Likes` tab with the header row
  /// `user_id | track_id | count | backfilled | updated_at`.
  final String spreadsheetId;

  /// The user's own "TVs and Limited Input devices" OAuth client.
  final String clientId;
  final String clientSecret;

  final String accessToken;
  final String refreshToken;

  /// When [accessToken] stops working; null when nothing is signed in.
  final DateTime? expiresAt;

  /// The client ID and secret are both there, so a sign-in can be started.
  bool get hasCredentials => clientId.isNotEmpty && clientSecret.isNotEmpty;

  /// A refresh token is held, so an access token can always be minted.
  bool get isSignedIn => refreshToken.isNotEmpty;

  /// Ready to count remotely: a sheet, a client and a sign-in.
  bool get isConfigured =>
      spreadsheetId.isNotEmpty && hasCredentials && isSignedIn;

  LikeCounterConfig copyWith({
    String? spreadsheetId,
    String? clientId,
    String? clientSecret,
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) =>
      LikeCounterConfig(
        spreadsheetId: spreadsheetId ?? this.spreadsheetId,
        clientId: clientId ?? this.clientId,
        clientSecret: clientSecret ?? this.clientSecret,
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        expiresAt: expiresAt ?? this.expiresAt,
      );

  @override
  bool operator ==(Object other) =>
      other is LikeCounterConfig &&
      other.spreadsheetId == spreadsheetId &&
      other.clientId == clientId &&
      other.clientSecret == clientSecret &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(
        spreadsheetId,
        clientId,
        clientSecret,
        accessToken,
        refreshToken,
        expiresAt,
      );

  /// Secrets are masked: this ends up in logs.
  @override
  String toString() => 'LikeCounterConfig(spreadsheetId: $spreadsheetId, '
      'clientId: $clientId, clientSecret: ${_mask(clientSecret)}, '
      'accessToken: ${_mask(accessToken)}, '
      'refreshToken: ${_mask(refreshToken)}, expiresAt: $expiresAt)';

  static String _mask(String value) => value.isEmpty ? '' : '***';
}
