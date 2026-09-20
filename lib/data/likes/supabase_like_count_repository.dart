import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/entities/supabase_config.dart';
import '../../domain/repositories/like_count_repository.dart';
import 'shared_prefs_like_count_repository.dart';

/// Tries Supabase RPC first, falls back to local SharedPreferences.
class SupabaseLikeCountRepository implements LikeCountRepository {
  /// The project to count in, read at increment time rather than held: the
  /// counter can be turned on in *Connected services* without a restart, and
  /// with nothing configured every like simply stays local.
  final Future<SupabaseConfig> Function() readConfig;
  final String? Function() userIdGetter;
  final SharedPrefsLikeCountRepository _local = SharedPrefsLikeCountRepository();
  final http.Client _httpClient;

  SupabaseLikeCountRepository({
    required this.readConfig,
    required this.userIdGetter,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  @override
  Future<int> incrementTrackLikeCount(String trackId) async {
    final config = await _readConfigOrEmpty();
    if (config.isConfigured) {
      final userId = userIdGetter();
      if (userId != null) {
        final count = await _supabaseIncrement(config, userId, trackId);
        if (count != null) return count;
      }
    }
    return _local.incrementTrackLikeCount(trackId);
  }

  /// An unreadable store is one more reason to count locally, never a reason
  /// to fail the like.
  Future<SupabaseConfig> _readConfigOrEmpty() async {
    try {
      return await readConfig();
    } catch (e) {
      debugPrint('Supabase config unreadable, counting locally: $e');
      return SupabaseConfig.empty;
    }
  }

  @override
  Future<int> getTrackLikeCount(String trackId) =>
      _local.getTrackLikeCount(trackId);

  @override
  Future<int> incrementArtistLikeCount(String artistId) =>
      _local.incrementArtistLikeCount(artistId);

  @override
  Future<int> getArtistLikeCount(String artistId) =>
      _local.getArtistLikeCount(artistId);

  @override
  Future<Map<String, int>> loadAllTrackLikeCounts() =>
      _local.loadAllTrackLikeCounts();

  @override
  Future<Map<String, int>> loadAllArtistLikeCounts() =>
      _local.loadAllArtistLikeCounts();

  @override
  Future<DateTime?> getLastLikedAt(String trackId) =>
      _local.getLastLikedAt(trackId);

  @override
  Future<void> recordLikedAt(String trackId, DateTime at) =>
      _local.recordLikedAt(trackId, at);

  Future<int?> _supabaseIncrement(
    SupabaseConfig config,
    String userId,
    String trackId,
  ) async {
    try {
      final response = await _httpClient.post(
        Uri.parse('${config.url}/rest/v1/rpc/increment_track_like'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'apikey': config.anonKey,
          'Authorization': 'Bearer ${config.anonKey}',
        },
        body: jsonEncode(<String, String>{
          'p_user_id': userId,
          'p_track_id': trackId,
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode >= 200 && response.statusCode <= 299) {
        return int.tryParse(response.body.trim());
      }
      debugPrint('Supabase increment failed (${response.statusCode})');
      return null;
    } catch (e) {
      debugPrint('Supabase increment error: $e');
      return null;
    }
  }
}
