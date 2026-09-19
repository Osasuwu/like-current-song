import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_constants.dart';
import '../../domain/entities/app_log.dart';
import '../../domain/entities/music_provider.dart';
import '../../domain/entities/pending_like.dart';
import '../../domain/entities/rule_config.dart';
import '../../domain/entities/trigger_config.dart';
import '../../domain/repositories/settings_repository.dart';

class SharedPrefsSettingsRepository implements SettingsRepository {
  static const _keyPattern = 'trigger_pattern';
  static const _keyWindow = 'trigger_window_ms';
  static const _keyDebounce = 'trigger_debounce_ms';
  static const _keyFeedbackVolume = 'trigger_feedback_volume';
  // Legacy keys — read once for migration into _keyRuleConfig, never written again.
  static const _legacyKeyArchivePlaylistName = 'archive_playlist_name';
  static const _legacyKeyBestOfPlaylistName = 'best_of_playlist_name';
  static const _keyRuleConfig = 'rule_config';
  static const _keyServiceEnabled = 'service_enabled';
  static const _keyMusicProvider = 'music_provider';
  static const _keyLogs = 'logs';
  static const _keyPendingLikes = 'pending_likes';

  @override
  Future<TriggerConfig> loadTriggerConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return TriggerConfig(
      pattern: prefs.getString(_keyPattern) ?? AppConstants.defaultPattern,
      windowMs: prefs.getInt(_keyWindow) ?? AppConstants.defaultWindowMs,
      debounceMs: prefs.getInt(_keyDebounce) ?? AppConstants.defaultDebounceMs,
      feedbackVolume:
          prefs.getInt(_keyFeedbackVolume) ?? AppConstants.defaultFeedbackVolume,
    );
  }

  @override
  Future<void> saveTriggerConfig(TriggerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPattern, config.pattern);
    await prefs.setInt(_keyWindow, config.windowMs);
    await prefs.setInt(_keyDebounce, config.debounceMs);
    await prefs.setInt(_keyFeedbackVolume, config.feedbackVolume);
  }

  @override
  Future<RuleConfig> loadRuleConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyRuleConfig);
    if (raw != null && raw.isNotEmpty) {
      try {
        return RuleConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        // fall through to legacy migration / defaults
      }
    }

    final legacyArchive = prefs.getString(_legacyKeyArchivePlaylistName);
    final legacyBestOf = prefs.getString(_legacyKeyBestOfPlaylistName);
    if (legacyArchive != null || legacyBestOf != null) {
      final migrated = RuleConfig.defaults().copyWith(
        archivePlaylistName: legacyArchive ?? AppConstants.defaultArchivePlaylistName,
        bestOfPlaylistName: legacyBestOf ?? AppConstants.defaultBestOfPlaylistName,
      );
      await saveRuleConfig(migrated);
      return migrated;
    }

    return RuleConfig.defaults();
  }

  @override
  Future<void> saveRuleConfig(RuleConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyRuleConfig, jsonEncode(config.toJson()));
  }

  @override
  Future<MusicProvider> loadMusicProvider() async {
    final prefs = await SharedPreferences.getInstance();
    return MusicProvider.fromId(prefs.getString(_keyMusicProvider));
  }

  @override
  Future<void> saveMusicProvider(MusicProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyMusicProvider, provider.id);
  }

  @override
  Future<bool> loadServiceEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyServiceEnabled) ?? false;
  }

  @override
  Future<void> saveServiceEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyServiceEnabled, enabled);
  }

  @override
  Future<List<AppLog>> loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final lines = await _loadRawLogLines(prefs);
    return lines.map(AppLog.fromLine).toList(growable: false);
  }

  Future<List<String>> _loadRawLogLines(SharedPreferences prefs) async {
    final raw = prefs.getStringList(_keyLogs);
    if (raw != null) {
      return raw;
    }
    final json = prefs.getString(_keyLogs);
    if (json == null || json.isEmpty) {
      return <String>[];
    }
    return List<String>.from(jsonDecode(json) as List<dynamic>);
  }

  @override
  Future<void> appendLog(AppLog log) async {
    final prefs = await SharedPreferences.getInstance();
    final lines = await _loadRawLogLines(prefs);
    lines.insert(0, log.toLine());
    final clipped = lines.take(300).toList(growable: false);
    await prefs.setStringList(_keyLogs, clipped);
  }

  @override
  Future<void> clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyLogs, <String>[]);
  }

  @override
  Future<List<PendingLike>> loadPendingLikes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyPendingLikes);
    if (raw == null || raw.isEmpty) return <PendingLike>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => PendingLike.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      return <PendingLike>[];
    }
  }

  @override
  Future<void> savePendingLikes(List<PendingLike> likes) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(likes.map((e) => e.toJson()).toList());
    await prefs.setString(_keyPendingLikes, json);
  }

  @override
  Future<void> addPendingLike(PendingLike like) async {
    final likes = await loadPendingLikes();
    // Deduplicate by trackId
    final filtered = likes.where((l) => l.trackId != like.trackId).toList();
    filtered.add(like);
    // Cap at 50
    if (filtered.length > 50) {
      filtered.removeRange(0, filtered.length - 50);
    }
    await savePendingLikes(filtered);
  }

  @override
  Future<void> removePendingLike(String trackId) async {
    final likes = await loadPendingLikes();
    final filtered = likes.where((l) => l.trackId != trackId).toList();
    await savePendingLikes(filtered);
  }
}
