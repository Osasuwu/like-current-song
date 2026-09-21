import '../entities/music_provider.dart';
import '../entities/music_routing.dart';
import '../entities/rule_config.dart';
import '../entities/trigger_config.dart';

abstract class PlatformServiceRepository {
  Future<void> startForegroundListener();
  Future<void> stopForegroundListener();
  Future<bool> isServiceEnabled();
  Future<void> updateTriggerConfig(TriggerConfig config);
  Future<bool> isIgnoringBatteryOptimizations();
  Future<void> openIgnoreBatteryOptimizationSettings();
  Future<void> openBatteryOptimizationSettings();
  Future<void> openNotificationSettings();
  Future<bool> isNotificationListenerEnabled();
  Future<void> openNotificationListenerSettings();
  Future<bool> isMiuiDevice();
  Future<void> openMiuiAutostartSettings();
  /// Whether [provider]'s Android app is installed.
  Future<bool> isMusicAppInstalled(MusicProvider provider);

  /// Launches [provider]'s Android app; false when it is not installed.
  Future<bool> openMusicApp(MusicProvider provider);

  /// Tells the native listener which service a pause-play should like on.
  Future<void> updateMusicProvider(MusicProvider provider);

  /// Tells the native listener whether to route a like to the picked service
  /// or to whichever connected service is playing.
  Future<void> updateMusicRoutingMode(MusicRoutingMode mode);

  /// What the native side sees on the device's media sessions right now:
  /// which providers own a playing session, and which one played last.
  ///
  /// Reading sessions needs notification access; without it the snapshot is
  /// empty rather than an error, because that is a legitimate state — Spotify
  /// likes work without it.
  Future<MusicSessionSnapshot> readMusicSessions();
  Future<void> updateRuleConfig(RuleConfig config);
  Stream<Map<String, dynamic>> events();
  Future<void> syncSpotifyTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresAtEpochSec,
    required String clientId,
  });

  /// Drops the Spotify user id the native side remembers.
  ///
  /// That id keys the shared like counter's rows and is cached indefinitely,
  /// so it has to be dropped whenever the account can have changed — otherwise
  /// a second account's likes are filed under the first account's name.
  Future<void> clearSpotifyUserId();

  /// Hands YouTube Music's Google tokens to the native side, which uses and
  /// refreshes them in the background (writing refreshed tokens back itself).
  Future<void> syncYouTubeMusicTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresAtEpochMs,
    required String clientId,
    required String clientSecret,
    String? userSub,
  });

  /// Removes YouTube Music's tokens from the native side (sign-out).
  Future<void> clearYouTubeMusicTokens();

  /// Hands the shared like counter's spreadsheet and Google sign-in to the
  /// native side, which counts the likes that happen with no Flutter UI
  /// running and refreshes the access token itself.
  ///
  /// An empty spreadsheet id or an empty refresh token turns the shared
  /// counter off: likes are then counted on this device only.
  Future<void> syncLikeCounterConfig({
    required String spreadsheetId,
    required String clientId,
    required String clientSecret,
    required String accessToken,
    required String refreshToken,
    required int expiresAtEpochMs,
  });
  Future<void> playFeedbackTone({required bool success});

  /// Likes the song playing in the YouTube Music app, natively: the media
  /// session's thumbs-up first, the YouTube Data API as fallback.
  ///
  /// Returns `outcome` (`liked` | `already_liked` | `cooldown` | `failed`),
  /// `trackName`, and on failure `message` and optionally `httpCode`.
  Future<Map<String, dynamic>> likeYouTubeMusicCurrentTrack();
}
