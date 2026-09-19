import '../../domain/entities/like_result.dart';
import '../../domain/entities/music_provider.dart';
import '../../domain/entities/pending_like.dart';
import '../../domain/entities/spotify_auth_state.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/settings_repository.dart';

/// Routes every [MusicServiceRepository] call to the repository of the music
/// service currently selected in Settings.
///
/// The selection is read on each call, so a change made in Settings applies
/// to the next like without rebuilding anything. Every [MusicProvider] must
/// have a registered repository: there is deliberately no fallback, because
/// falling back to Spotify would send a Spotify request while the user has
/// chosen another service.
class ActiveMusicServiceRepository implements MusicServiceRepository {
  ActiveMusicServiceRepository({
    required SettingsRepository settingsRepository,
    required Map<MusicProvider, MusicServiceRepository> repositories,
  })  : _settingsRepository = settingsRepository,
        _repositories = Map<MusicProvider, MusicServiceRepository>.unmodifiable(
          repositories,
        ) {
    final missing =
        MusicProvider.values.where((p) => !_repositories.containsKey(p));
    if (missing.isNotEmpty) {
      throw ArgumentError.value(
        repositories.keys.map((p) => p.id).toList(),
        'repositories',
        'No repository registered for: ${missing.map((p) => p.id).join(', ')}',
      );
    }
  }

  final SettingsRepository _settingsRepository;
  final Map<MusicProvider, MusicServiceRepository> _repositories;

  /// The repository for the currently selected music service.
  Future<MusicServiceRepository> resolve() async {
    final provider = await _settingsRepository.loadMusicProvider();
    return _repositories[provider]!;
  }

  @override
  Future<SpotifyAuthState> getAuthState() async =>
      (await resolve()).getAuthState();

  @override
  Future<SpotifyAuthState> connect() async => (await resolve()).connect();

  @override
  Future<void> disconnect() async => (await resolve()).disconnect();

  /// Offered to every registered service, not just the selected one: an
  /// OAuth redirect must still complete if the user switched services while
  /// the browser was open. Each service ignores URIs that aren't its own.
  @override
  Future<bool> handleAuthCallback(Uri uri) async {
    for (final repository in _repositories.values) {
      if (await repository.handleAuthCallback(uri)) return true;
    }
    return false;
  }

  @override
  Future<LikeResult> likeCurrentTrack() async =>
      (await resolve()).likeCurrentTrack();

  @override
  Future<LikeResult> likeTrack(TrackInfo trackInfo) async =>
      (await resolve()).likeTrack(trackInfo);

  @override
  Future<void> refreshIfNeeded() async => (await resolve()).refreshIfNeeded();

  @override
  Future<int> processPendingLikes(List<PendingLike> pending) async =>
      (await resolve()).processPendingLikes(pending);

  @override
  Future<Map<String, Map<String, int>>> loadAllLikeCounts() async =>
      (await resolve()).loadAllLikeCounts();
}
