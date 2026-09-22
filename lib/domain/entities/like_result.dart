class LikeResult {
  final String trackId;
  final String trackName;
  final bool trackLiked;
  final bool removedFromArchive;
  final bool addedToBest;
  final List<String> followedArtistNames;
  final int trackLikeCount;
  final String? errorMessage;
  final bool skippedCooldown;

  /// The service already had the track liked, so nothing changed. Counts as
  /// a success: the song is liked, which is what the user asked for.
  final bool alreadyLiked;

  /// The service's own like went through (or was already there).
  ///
  /// With the `both` destination a like can half succeed, so the two legs are
  /// reported separately: [trackLiked] says whether the like as a whole
  /// counted, these say which half of it actually happened.
  final bool likedNatively;

  /// The track was added to the user's like playlist.
  final bool addedToLikePlaylist;

  /// The leg that failed while the other one carried the like, phrased for a
  /// log line. Null when nothing failed.
  final String? partialFailureMessage;

  const LikeResult({
    required this.trackId,
    required this.trackName,
    required this.trackLiked,
    this.removedFromArchive = false,
    this.addedToBest = false,
    this.followedArtistNames = const <String>[],
    this.trackLikeCount = 0,
    this.errorMessage,
    this.skippedCooldown = false,
    this.alreadyLiked = false,
    this.likedNatively = false,
    this.addedToLikePlaylist = false,
    this.partialFailureMessage,
  });

  bool get success => trackLiked && errorMessage == null;
}
