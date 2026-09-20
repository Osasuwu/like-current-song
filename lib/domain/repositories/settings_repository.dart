import '../entities/app_log.dart';
import '../entities/music_provider.dart';
import '../entities/music_routing.dart';
import '../entities/pending_like.dart';
import '../entities/rule_config.dart';
import '../entities/trigger_config.dart';

abstract class SettingsRepository {
  Future<TriggerConfig> loadTriggerConfig();
  Future<void> saveTriggerConfig(TriggerConfig config);
  Future<RuleConfig> loadRuleConfig();
  Future<void> saveRuleConfig(RuleConfig config);
  /// The selected music service; [MusicProvider.defaultProvider] when unset.
  Future<MusicProvider> loadMusicProvider();
  Future<void> saveMusicProvider(MusicProvider provider);

  /// How likes are routed; [MusicRoutingMode.defaultMode] when unset, so an
  /// install upgraded from a build without automatic routing keeps using the
  /// service it had picked.
  Future<MusicRoutingMode> loadMusicRoutingMode();
  Future<void> saveMusicRoutingMode(MusicRoutingMode mode);
  Future<bool> loadServiceEnabled();
  Future<void> saveServiceEnabled(bool enabled);
  Future<List<AppLog>> loadLogs();
  Future<void> appendLog(AppLog log);
  Future<void> clearLogs();
  Future<List<PendingLike>> loadPendingLikes();
  Future<void> savePendingLikes(List<PendingLike> likes);
  Future<void> addPendingLike(PendingLike like);
  Future<void> removePendingLike(String trackId);
}
