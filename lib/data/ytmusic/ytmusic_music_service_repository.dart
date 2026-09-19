import '../../domain/entities/like_result.dart';
import '../../domain/entities/music_provider.dart';
import '../../domain/entities/music_service_exceptions.dart';
import '../../domain/entities/pending_like.dart';
import '../../domain/entities/spotify_auth_state.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';

/// A YouTube Music like that did not go through.
class YouTubeMusicLikeException implements Exception {
  const YouTubeMusicLikeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A YouTube Music like the Data API rejected with an HTTP status.
class YouTubeMusicLikeHttpException extends YouTubeMusicLikeException
    implements MusicServiceHttpException {
  const YouTubeMusicLikeHttpException(super.message, this.statusCode);

  @override
  final int statusCode;
}

/// YouTube Music on Android.
///
/// Liking is native (`YouTubeMusicLiker.kt`): a thumbs-up through the YouTube
/// Music app's media session, which needs no sign-in, with the YouTube Data
/// API as fallback when the session rating doesn't take. The same code runs
/// when the trigger fires with no Flutter UI attached, so the screen-off path
/// and this one behave identically.
class YouTubeMusicServiceRepository implements MusicServiceRepository {
  const YouTubeMusicServiceRepository({
    required PlatformServiceRepository platformServiceRepository,
  }) : _platform = platformServiceRepository;

  final PlatformServiceRepository _platform;

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
    final reply = await _platform.likeYouTubeMusicCurrentTrack();
    final trackName = reply['trackName'] as String? ?? _provider.displayName;
    switch (reply['outcome']) {
      case 'liked':
        return LikeResult(trackId: '', trackName: trackName, trackLiked: true);
      case 'already_liked':
        return LikeResult(
          trackId: '',
          trackName: trackName,
          trackLiked: true,
          alreadyLiked: true,
        );
      case 'cooldown':
        return LikeResult(
          trackId: '',
          trackName: trackName,
          trackLiked: false,
          skippedCooldown: true,
        );
      default:
        final message = reply['message'] as String? ?? 'like failed';
        final httpCode = reply['httpCode'];
        if (httpCode is int) {
          throw YouTubeMusicLikeHttpException(message, httpCode);
        }
        throw YouTubeMusicLikeException(message);
    }
  }

  /// The session can only like what is playing now, so there is no way to
  /// like an arbitrary track from here.
  @override
  Future<LikeResult> likeTrack(TrackInfo trackInfo) async {
    throw const YouTubeMusicLikeException(
      'YouTube Music can only like the song that is playing',
    );
  }

  @override
  Future<void> refreshIfNeeded() async {}

  /// YouTube Music likes are never queued (see `AppController.queueTrackForLater`):
  /// the like targets whatever is playing, so a replay would hit another song.
  @override
  Future<int> processPendingLikes(List<PendingLike> pending) async => 0;

  @override
  Future<Map<String, Map<String, int>>> loadAllLikeCounts() async =>
      <String, Map<String, int>>{
        'tracks': <String, int>{},
        'artists': <String, int>{},
      };
}
