import 'package:flutter/services.dart';

import '../../core/app_constants.dart';
import '../../domain/repositories/like_count_repository.dart';

/// The device's own like counters, read and written on the native side.
///
/// Both halves of the app count likes — Flutter when the user taps, the
/// foreground service when a media button fires — and they used to count into
/// two different SharedPreferences files that never met, so a user who mixed
/// the two input methods split every count in half and the follow-artist and
/// cooldown rules never saw the whole picture (#197). Native
/// `like_spotify_prefs` is the one store now, and this is Dart's way in.
///
/// Replies come back loosely typed across the channel, so every one of them is
/// converted rather than cast: a malformed entry is dropped instead of taking
/// a whole like down with it.
class NativeLikeCountRepository implements LikeCountRepository {
  const NativeLikeCountRepository();

  static const _channel = MethodChannel(AppConstants.serviceMethodChannel);

  static const _trackKind = 'track';
  static const _artistKind = 'artist';

  @override
  Future<int> incrementTrackLikeCount(String trackId) =>
      _increment(_trackKind, trackId);

  @override
  Future<int> getTrackLikeCount(String trackId) => _getCount(_trackKind, trackId);

  @override
  Future<int> incrementArtistLikeCount(String artistId, {String? trackId}) =>
      _increment(_artistKind, artistId);

  @override
  Future<int> getArtistLikeCount(String artistId) =>
      _getCount(_artistKind, artistId);

  @override
  Future<Map<String, int>> loadAllTrackLikeCounts() => _loadCounts(_trackKind);

  @override
  Future<Map<String, int>> loadAllArtistLikeCounts() => _loadCounts(_artistKind);

  @override
  Future<DateTime?> getLastLikedAt(String trackId) async {
    final epochMillis = await _channel.invokeMethod<int>(
      'getLastLikedAt',
      <String, dynamic>{'id': trackId},
    );
    if (epochMillis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(epochMillis, isUtc: true);
  }

  @override
  Future<void> recordLikedAt(String trackId, DateTime at) async {
    await _channel.invokeMethod<void>('recordLikedAt', <String, dynamic>{
      'id': trackId,
      'atEpochMillis': at.toUtc().millisecondsSinceEpoch,
    });
  }

  /// Folds counters recorded elsewhere into the native store: counts are added
  /// to what is there, last-liked times take the later of the two.
  ///
  /// Adding is the honest arithmetic, because the two stores never shared a
  /// like — but it is right exactly once. The native side records that the
  /// fold happened, in the same commit as the counts, and answers every later
  /// call with false, so this is safe to call whenever we are unsure.
  ///
  /// False therefore means the counters were already across — a finished
  /// merge, not a refused one. Only a thrown [PlatformException] means they
  /// did not arrive.
  Future<bool> mergeLocalCounters({
    required Map<String, int> tracks,
    required Map<String, int> artists,
    required Map<String, int> lastLikedAt,
  }) async {
    final merged =
        await _channel.invokeMethod<bool>('mergeLocalCounters', <String, dynamic>{
      'tracks': tracks,
      'artists': artists,
      'lastLikedAt': lastLikedAt,
    });
    return merged ?? false;
  }

  Future<int> _increment(String kind, String id) async {
    final count = await _channel.invokeMethod<int>(
      'incrementLocalCount',
      <String, dynamic>{'kind': kind, 'id': id},
    );
    return count ?? 0;
  }

  Future<int> _getCount(String kind, String id) async {
    final count = await _channel.invokeMethod<int>(
      'getLocalCount',
      <String, dynamic>{'kind': kind, 'id': id},
    );
    return count ?? 0;
  }

  Future<Map<String, int>> _loadCounts(String kind) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'loadLocalCounts',
      <String, dynamic>{'kind': kind},
    );
    if (raw == null) return const <String, int>{};

    final counts = <String, int>{};
    raw.forEach((key, value) {
      if (key is String && value is int) counts[key] = value;
    });
    return counts;
  }
}
