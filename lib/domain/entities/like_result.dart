class LikeResult {
  final String trackId;
  final String trackName;
  final bool trackLiked;
  final bool removedFromArchive;
  final bool addedToBestOf;
  final List<String> followedArtistNames;
  final int trackLikeCount;
  final String? errorMessage;
  final bool skippedCooldown;

  /// The service already had the track liked, so nothing changed. Counts as
  /// a success: the song is liked, which is what the user asked for.
  final bool alreadyLiked;

  const LikeResult({
    required this.trackId,
    required this.trackName,
    required this.trackLiked,
    this.removedFromArchive = false,
    this.addedToBestOf = false,
    this.followedArtistNames = const <String>[],
    this.trackLikeCount = 0,
    this.errorMessage,
    this.skippedCooldown = false,
    this.alreadyLiked = false,
  });

  bool get success => trackLiked && errorMessage == null;
}
