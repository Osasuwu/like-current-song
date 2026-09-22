import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/repositories/like_count_repository.dart';

/// The counters this app used to keep in Flutter's own SharedPreferences.
///
/// Nothing counts here any more: the native store behind
/// `NativeLikeCountRepository` is the single one both halves of the app write
/// to (#197). This class stays as the *source* `LocalCounterMigration` reads
/// from on first launch after the change, and is emptied once that merge has
/// landed. Do not wire it up as a counter again — a like recorded here is a
/// like the foreground service cannot see.
class SharedPrefsLikeCountRepository implements LikeCountRepository {
  static const _keyTrackCounts = 'track_like_counts';
  static const _keyArtistCounts = 'artist_like_counts';
  static const _keyTrackLastLikedAt = 'track_last_liked_at';

  @override
  Future<int> incrementTrackLikeCount(String trackId) =>
      _increment(_keyTrackCounts, trackId);

  @override
  Future<int> getTrackLikeCount(String trackId) =>
      _getCount(_keyTrackCounts, trackId);

  @override
  Future<int> incrementArtistLikeCount(String artistId) =>
      _increment(_keyArtistCounts, artistId);

  @override
  Future<int> getArtistLikeCount(String artistId) =>
      _getCount(_keyArtistCounts, artistId);

  @override
  Future<Map<String, int>> loadAllTrackLikeCounts() => _loadMap(_keyTrackCounts);

  @override
  Future<Map<String, int>> loadAllArtistLikeCounts() => _loadMap(_keyArtistCounts);

  @override
  Future<DateTime?> getLastLikedAt(String trackId) async {
    final map = await _loadMap(_keyTrackLastLikedAt);
    final epochMillis = map[trackId];
    if (epochMillis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(epochMillis, isUtc: true);
  }

  @override
  Future<void> recordLikedAt(String trackId, DateTime at) async {
    final map = await _loadMap(_keyTrackLastLikedAt);
    map[trackId] = at.toUtc().millisecondsSinceEpoch;
    await _saveMap(_keyTrackLastLikedAt, map);
  }

  /// Every cooldown timestamp still stored here, keyed by track id.
  ///
  /// The interface only asks about one track at a time, which is all a like
  /// needs; the migration has to hand the whole map over at once.
  Future<Map<String, DateTime>> loadAllLastLikedAt() async {
    final map = await _loadMap(_keyTrackLastLikedAt);
    return map.map((trackId, epochMillis) => MapEntry(
          trackId,
          DateTime.fromMillisecondsSinceEpoch(epochMillis, isUtc: true),
        ));
  }

  /// Drops all three maps, leaving no second set of counters behind.
  ///
  /// Only for use once the migration has seen the native side take them:
  /// these numbers exist nowhere else.
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyTrackCounts);
    await prefs.remove(_keyArtistCounts);
    await prefs.remove(_keyTrackLastLikedAt);
  }

  Future<int> _increment(String key, String itemId) async {
    final map = await _loadMap(key);
    final next = (map[itemId] ?? 0) + 1;
    map[itemId] = next;
    await _saveMap(key, map);
    return next;
  }

  Future<int> _getCount(String key, String itemId) async {
    final map = await _loadMap(key);
    return map[itemId] ?? 0;
  }

  Future<Map<String, int>> _loadMap(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as int));
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> _saveMap(String key, Map<String, int> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(map));
  }
}
