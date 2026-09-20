class AppConstants {
  static const spotifyAuthorizeUrl = 'https://accounts.spotify.com/authorize';
  static const spotifyTokenUrl = 'https://accounts.spotify.com/api/token';
  static const spotifyApiBase = 'https://api.spotify.com/v1';

  /// Where Spotify sends the OAuth callback. Not configurable: it is the
  /// intent filter the manifest declares (`likespotify://auth-callback`), so
  /// anything else would simply never reach the app. It is shown on
  /// *Connected services* because it has to be pasted into the Spotify
  /// dashboard.
  static const spotifyRedirectUri = 'likespotify://auth-callback';

  static const defaultPattern = 'pause,play';
  static const defaultWindowMs = 1000;
  static const defaultDebounceMs = 650;
  static const defaultFeedbackVolume = 100;
  /// Playlist names the extra actions used out of the box up to v1.0.3.
  /// Fresh installs start with empty names; these are kept only so older
  /// installs upgrade without a behaviour change (see RuleConfig.legacyDefaults).
  static const legacyArchivePlaylistName = 'Discover Weekly Archive';
  static const legacyBestPlaylistName = 'Botbotb(Best of the best of the best)';
  static const defaultBestThreshold = 3;
  static const defaultFollowArtistThreshold = 5;
  static const defaultLikeCooldownMinutes = 10;

  static const serviceMethodChannel = 'like_spotify_mobile_app/service';
  static const serviceEventChannel = 'like_spotify_mobile_app/events';
}
