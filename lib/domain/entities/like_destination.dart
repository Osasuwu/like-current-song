/// Where a like goes: the service's own "liked songs", a playlist of your
/// own, or both.
///
/// YouTube Music is the reason this exists — liked songs and liked videos
/// share one bucket there, so a liked song lands among everything else the
/// account has ever liked. Sending likes to a playlist instead gives them a
/// place of their own. Spotify has the same setting so the two services
/// behave the same way.
///
/// Deliberately one global setting rather than one per service, the same way
/// the archive and best playlist names are global. The Kotlin side keeps a
/// matching enum in `LikeDestination.kt`.
enum LikeDestination {
  native(id: 'native', displayName: 'Liked songs'),
  playlist(id: 'playlist', displayName: 'A playlist'),
  both(id: 'both', displayName: 'Both');

  const LikeDestination({required this.id, required this.displayName});

  /// Stable identifier used for persistence and the platform channel.
  final String id;

  /// Human-readable name for the UI.
  final String displayName;

  /// New installs and existing installs that predate the setting both keep
  /// the behaviour the app has always had: the service's own like.
  static const LikeDestination defaultDestination = LikeDestination.native;

  /// Whether the service's own like should be sent.
  bool get likesNatively => this != LikeDestination.playlist;

  /// Whether the track should be added to the user's like playlist.
  bool get addsToPlaylist => this != LikeDestination.native;

  /// Resolves a persisted [id]; unknown or missing values fall back to
  /// [defaultDestination] so an older build never crashes on a newer value.
  static LikeDestination fromId(String? id) {
    for (final destination in LikeDestination.values) {
      if (destination.id == id) return destination;
    }
    return defaultDestination;
  }

  /// The destination to actually run, given the configured playlist name.
  ///
  /// A playlist destination with no playlist name has nowhere to put the
  /// song. `validate()` stops the user saving such a config, so this only
  /// catches a hand-edited or partially written one: rather than failing
  /// every like, it falls back to the service's own like.
  static LikeDestination resolve(LikeDestination destination, String playlistName) {
    if (destination.addsToPlaylist && playlistName.trim().isEmpty) {
      return LikeDestination.native;
    }
    return destination;
  }
}
