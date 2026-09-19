class AppConstants {
  static const spotifyAuthorizeUrl = 'https://accounts.spotify.com/authorize';
  static const spotifyTokenUrl = 'https://accounts.spotify.com/api/token';
  static const spotifyApiBase = 'https://api.spotify.com/v1';

  static const defaultPattern = 'pause,play';
  static const defaultWindowMs = 1000;
  static const defaultDebounceMs = 650;
  static const defaultFeedbackVolume = 100;
  static const defaultArchivePlaylistName = 'Discover Weekly Archive';
  static const defaultBestOfPlaylistName = 'Botbotb(Best of the best of the best)';
  static const defaultLikeCooldownMinutes = 10;

  static const serviceMethodChannel = 'like_spotify_mobile_app/service';
  static const serviceEventChannel = 'like_spotify_mobile_app/events';
}
