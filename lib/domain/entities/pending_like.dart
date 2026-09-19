import 'music_provider.dart';

class PendingLike {
  final String trackId;
  final String trackName;
  final List<String> artistIds;
  final List<String> artistNames;
  final DateTime queuedAt;

  /// [MusicProvider.id] of the service this like was queued for.
  ///
  /// Kept as the raw id rather than a [MusicProvider] so a value written by a
  /// newer build (an id this build doesn't know) matches no service instead of
  /// falling back to Spotify: a queued like must only ever be replayed on the
  /// service it was queued for.
  final String providerId;

  const PendingLike({
    required this.trackId,
    required this.trackName,
    required this.artistIds,
    required this.artistNames,
    required this.queuedAt,
    this.providerId = spotifyProviderId,
  });

  /// Queues written before the provider field existed were all Spotify.
  static const String spotifyProviderId = 'spotify';

  /// Whether this like belongs to [provider]'s queue.
  bool isFor(MusicProvider provider) => provider.id == providerId;

  String get trackUri => 'spotify:track:$trackId';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'trackId': trackId,
        'trackName': trackName,
        'artistIds': artistIds,
        'artistNames': artistNames,
        'queuedAt': queuedAt.toIso8601String(),
        'provider': providerId,
      };

  factory PendingLike.fromJson(Map<String, dynamic> json) => PendingLike(
        trackId: json['trackId'] as String,
        trackName: json['trackName'] as String,
        artistIds: List<String>.from(json['artistIds'] as List<dynamic>),
        artistNames: List<String>.from(json['artistNames'] as List<dynamic>),
        queuedAt: DateTime.parse(json['queuedAt'] as String),
        providerId: json['provider'] as String? ?? spotifyProviderId,
      );
}
