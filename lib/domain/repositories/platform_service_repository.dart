import '../entities/music_provider.dart';
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
  Future<void> updateRuleConfig(RuleConfig config);
  Stream<Map<String, dynamic>> events();
  Future<void> syncSpotifyTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresAtEpochSec,
    required String clientId,
  });
  Future<void> syncSupabaseConfig({
    required String supabaseUrl,
    required String supabaseAnonKey,
  });
  Future<void> playFeedbackTone({required bool success});

  /// Likes the song playing in the YouTube Music app, natively: the media
  /// session's thumbs-up first, the YouTube Data API as fallback.
  ///
  /// Returns `outcome` (`liked` | `already_liked` | `cooldown` | `failed`),
  /// `trackName`, and on failure `message` and optionally `httpCode`.
  Future<Map<String, dynamic>> likeYouTubeMusicCurrentTrack();
}
