import '../entities/music_provider.dart';

/// The account id that keys the shared like counter (the `user_id` column of
/// the counter sheet) for a like made through [provider].
///
/// Each service keys its own rows, the same way desktop does, so the phone
/// and the computer add to one count per account:
/// - Spotify: the Spotify user id.
/// - YouTube Music: the Google account's id_token `sub`.
///
/// Null (never the other service's id) when that service has no account id,
/// i.e. the user is not signed in there; the like is then not counted
/// remotely. Mirrors `LikeCounter.userIdFor` in `LikeCounter.kt`, which
/// counts likes made without the Flutter UI.
String? likeCounterUserId(
  MusicProvider provider, {
  String? spotifyUserId,
  String? youTubeMusicSub,
}) {
  final id = switch (provider) {
    MusicProvider.spotify => spotifyUserId,
    MusicProvider.ytmusic => youTubeMusicSub,
  };
  final trimmed = id?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
