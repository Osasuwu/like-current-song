/// The music service the app likes songs on.
///
/// Mirrors desktop's `music.provider` config value: [id] is the same string
/// (`spotify` / `ytmusic`), so a value persisted on one side reads the same on
/// the other. The Kotlin side keeps a matching enum in `MusicProvider.kt`.
enum MusicProvider {
  spotify(id: 'spotify', displayName: 'Spotify'),
  ytmusic(id: 'ytmusic', displayName: 'YouTube Music');

  const MusicProvider({required this.id, required this.displayName});

  /// Stable identifier used for persistence and the platform channel.
  final String id;

  /// Human-readable name for the UI and log messages.
  final String displayName;

  /// Used for new installs, existing installs that predate the setting, and
  /// any stored value this build does not recognise.
  static const MusicProvider defaultProvider = MusicProvider.spotify;

  /// Resolves a persisted [id]; unknown or missing values fall back to
  /// [defaultProvider] so an older build never crashes on a newer value.
  static MusicProvider fromId(String? id) {
    for (final provider in MusicProvider.values) {
      if (provider.id == id) return provider;
    }
    return defaultProvider;
  }
}
