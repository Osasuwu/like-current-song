import '../../domain/entities/like_result.dart';
import '../../domain/entities/music_provider.dart';
import '../../domain/entities/music_service_exceptions.dart';
import '../../domain/entities/pending_like.dart';
import '../../domain/entities/spotify_auth_state.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/repositories/music_service_repository.dart';

/// YouTube Music, before sign-in exists on Android.
///
/// Always reports "not connected" and never talks to any service: a like
/// throws [MusicServiceNotConnectedException] so the user sees why nothing
/// happened. Google device-flow sign-in (#94) and liking via the YouTube Data
/// API (#95) replace these bodies; the class keeps its place in the
/// provider registry (`music_service_factory.dart`).
class YouTubeMusicServiceRepository implements MusicServiceRepository {
  const YouTubeMusicServiceRepository();

  static const _provider = MusicProvider.ytmusic;

  @override
  Future<SpotifyAuthState> getAuthState() async =>
      const SpotifyAuthState.disconnected();

  @override
  Future<SpotifyAuthState> connect() async {
    throw UnsupportedError(
      '${_provider.displayName} sign-in is not available on Android yet.',
    );
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> handleAuthCallback(Uri uri) async => false;

  @override
  Future<LikeResult> likeCurrentTrack() async {
    throw const MusicServiceNotConnectedException(_provider);
  }

  @override
  Future<LikeResult> likeTrack(TrackInfo trackInfo) async {
    throw const MusicServiceNotConnectedException(_provider);
  }

  @override
  Future<void> refreshIfNeeded() async {}

  /// Queued likes are left in place for when a connected service picks them
  /// up; nothing is processed while YouTube Music is not connected.
  @override
  Future<int> processPendingLikes(List<PendingLike> pending) async => 0;

  @override
  Future<Map<String, Map<String, int>>> loadAllLikeCounts() async =>
      <String, Map<String, int>>{
        'tracks': <String, int>{},
        'artists': <String, int>{},
      };
}
