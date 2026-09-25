abstract class LikeCountRepository {
  Future<int> incrementTrackLikeCount(String trackId);
  Future<int> getTrackLikeCount(String trackId);
  /// Adds a like to [artistId]'s count and answers the number follow-artist
  /// decides on.
  ///
  /// With [trackId] — passed only while follow-artist is on — an
  /// implementation backed by the shared counter sheet records the
  /// (artist, track) pair there and answers how many distinct tracks by the
  /// artist were liked on any device, the number the desktop follows on. A
  /// local store has no such set and answers its own tally either way.
  Future<int> incrementArtistLikeCount(String artistId, {String? trackId});
  Future<int> getArtistLikeCount(String artistId);
  Future<Map<String, int>> loadAllTrackLikeCounts();
  Future<Map<String, int>> loadAllArtistLikeCounts();
  Future<DateTime?> getLastLikedAt(String trackId);
  Future<void> recordLikedAt(String trackId, DateTime at);
}
