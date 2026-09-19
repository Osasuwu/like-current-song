import '../entities/like_result.dart';
import '../entities/pending_like.dart';
import '../entities/spotify_auth_state.dart';
import '../entities/track_info.dart';

/// One music service (Spotify, YouTube Music, ...) as seen by the app.
///
/// Presentation and state code depend only on this interface. The instance
/// they receive resolves the user's selected [MusicProvider] on every call,
/// so switching services in Settings takes effect without a restart.
///
/// Implementations throw `MusicServiceNotConnectedException` when asked to
/// like without a usable sign-in, and should make their API errors implement
/// `MusicServiceHttpException` so the HTTP code reaches the logs.
abstract class MusicServiceRepository {
  Future<SpotifyAuthState> getAuthState();

  /// Starts this service's sign-in flow. The result may still be
  /// disconnected when sign-in completes out of band (e.g. an OAuth redirect
  /// delivered later to [handleAuthCallback]).
  Future<SpotifyAuthState> connect();

  Future<void> disconnect();

  /// Offers an incoming deep link to the service. Returns true when it was
  /// this service's sign-in callback and sign-in completed.
  Future<bool> handleAuthCallback(Uri uri);

  Future<LikeResult> likeCurrentTrack();
  Future<LikeResult> likeTrack(TrackInfo trackInfo);
  Future<void> refreshIfNeeded();
  Future<int> processPendingLikes(List<PendingLike> pending);
  Future<Map<String, Map<String, int>>> loadAllLikeCounts();
}
