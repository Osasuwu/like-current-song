import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_client.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_models.dart'
    as models;
import 'package:like_spotify_mobile_app/data/spotify/spotify_music_service_repository.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_token_store.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_destination.dart';
import 'package:like_spotify_mobile_app/domain/entities/rule_config.dart';
import 'package:like_spotify_mobile_app/domain/entities/track_info.dart';
import 'package:like_spotify_mobile_app/domain/repositories/like_count_repository.dart';
import 'package:like_spotify_mobile_app/domain/repositories/platform_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/repositories/settings_repository.dart';

class MockSpotifyClient extends Mock implements SpotifyClient {}

class MockSpotifyTokenStore extends Mock implements SpotifyTokenStore {}

class MockPlatformServiceRepository extends Mock
    implements PlatformServiceRepository {}

class MockLikeCountRepository extends Mock implements LikeCountRepository {}

class MockSettingsRepository extends Mock implements SettingsRepository {}

/// Where a like goes, on the Dart Spotify path. The same three destinations
/// run in `SpotifyLikeWorker` (Kotlin) and must behave identically there.
void main() {
  late MockSpotifyClient mockClient;
  late MockSpotifyTokenStore mockTokenStore;
  late MockPlatformServiceRepository mockPlatform;
  late MockLikeCountRepository mockLikeCount;
  late MockSettingsRepository mockSettings;
  late SpotifyMusicServiceRepository repo;

  const trackInfo = TrackInfo(
    trackId: 'track-123',
    trackName: 'Test Song',
    artistIds: ['artist-1'],
    artistNames: ['Artist One'],
  );

  RuleConfig config({
    LikeDestination destination = LikeDestination.native,
    String playlistName = '',
  }) =>
      RuleConfig(
        archiveRemoveEnabled: false,
        archivePlaylistName: '',
        bestEnabled: false,
        bestPlaylistName: '',
        bestThreshold: 3,
        followArtistEnabled: false,
        followArtistThreshold: 5,
        likeDestination: destination,
        likePlaylistName: playlistName,
      );

  void useConfig(RuleConfig ruleConfig) {
    when(() => mockSettings.loadRuleConfig())
        .thenAnswer((_) async => ruleConfig);
  }

  setUp(() {
    mockClient = MockSpotifyClient();
    mockTokenStore = MockSpotifyTokenStore();
    mockPlatform = MockPlatformServiceRepository();
    mockLikeCount = MockLikeCountRepository();
    mockSettings = MockSettingsRepository();

    repo = SpotifyMusicServiceRepository(
      spotifyClient: mockClient,
      tokenStore: mockTokenStore,
      platformServiceRepository: mockPlatform,
      likeCountRepository: mockLikeCount,
      settingsRepository: mockSettings,
    );

    when(() => mockTokenStore.readClientId())
        .thenAnswer((_) async => 'test-client-id');
    when(() => mockTokenStore.readAccessToken())
        .thenAnswer((_) async => 'valid-token');
    when(() => mockTokenStore.readRefreshToken())
        .thenAnswer((_) async => 'refresh-token');
    when(() => mockTokenStore.readExpiryEpochSec()).thenAnswer(
      (_) async => DateTime.now().toUtc().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    );

    useConfig(config());

    when(() => mockLikeCount.getLastLikedAt(any())).thenAnswer((_) async => null);
    when(() => mockLikeCount.recordLikedAt(any(), any())).thenAnswer((_) async {});
    when(() => mockLikeCount.incrementTrackLikeCount(any()))
        .thenAnswer((_) async => 1);
    when(() => mockLikeCount.incrementArtistLikeCount(any(),
              trackId: any(named: 'trackId')))
        .thenAnswer((_) async => 1);

    when(() => mockClient.likeTrack(
          trackId: any(named: 'trackId'),
          accessToken: any(named: 'accessToken'),
        )).thenAnswer((_) async {});
    // The user already has a playlist by that name, so nothing is created.
    when(() => mockClient.getUserPlaylists(any(), offset: 0)).thenAnswer(
      (_) async => const models.SpotifyPlaylistPage(
        items: [models.SpotifyPlaylistItem(id: 'like-id', name: 'Trigger likes')],
        total: 1,
      ),
    );
    when(() => mockClient.addTracksToPlaylist(
          any(),
          playlistId: any(named: 'playlistId'),
          trackUris: any(named: 'trackUris'),
        )).thenAnswer((_) async {});
  });

  group('like destination', () {
    test('native likes the track and touches no playlist', () async {
      final result = await repo.likeTrack(trackInfo);

      expect(result.trackLiked, true);
      expect(result.likedNatively, true);
      expect(result.addedToLikePlaylist, false);
      expect(result.partialFailureMessage, isNull);
      verify(() => mockClient.likeTrack(
            trackId: 'track-123',
            accessToken: 'valid-token',
          )).called(1);
      verifyNever(() => mockClient.addTracksToPlaylist(
            any(),
            playlistId: any(named: 'playlistId'),
            trackUris: any(named: 'trackUris'),
          ));
    });

    test('playlist adds to the playlist and skips liked songs', () async {
      useConfig(config(
        destination: LikeDestination.playlist,
        playlistName: 'Trigger likes',
      ));

      final result = await repo.likeTrack(trackInfo);

      expect(result.trackLiked, true);
      expect(result.likedNatively, false);
      expect(result.addedToLikePlaylist, true);
      verifyNever(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          ));
      verify(() => mockClient.addTracksToPlaylist(
            'valid-token',
            playlistId: 'like-id',
            trackUris: ['spotify:track:track-123'],
          )).called(1);
    });

    test('both does the two legs', () async {
      useConfig(config(
        destination: LikeDestination.both,
        playlistName: 'Trigger likes',
      ));

      final result = await repo.likeTrack(trackInfo);

      expect(result.trackLiked, true);
      expect(result.likedNatively, true);
      expect(result.addedToLikePlaylist, true);
      expect(result.partialFailureMessage, isNull);
      verify(() => mockClient.likeTrack(
            trackId: 'track-123',
            accessToken: 'valid-token',
          )).called(1);
      verify(() => mockClient.addTracksToPlaylist(
            'valid-token',
            playlistId: 'like-id',
            trackUris: ['spotify:track:track-123'],
          )).called(1);
    });

    test('a playlist destination with no name falls back to liked songs', () async {
      // Only an older build or a hand-edited config can get here: the
      // settings screen refuses to save a nameless playlist destination.
      useConfig(config(destination: LikeDestination.both, playlistName: '   '));

      final result = await repo.likeTrack(trackInfo);

      expect(result.likedNatively, true);
      expect(result.addedToLikePlaylist, false);
      verify(() => mockClient.likeTrack(
            trackId: 'track-123',
            accessToken: 'valid-token',
          )).called(1);
      verifyNever(() => mockClient.addTracksToPlaylist(
            any(),
            playlistId: any(named: 'playlistId'),
            trackUris: any(named: 'trackUris'),
          ));
    });
  });

  group('partial failure', () {
    setUp(() {
      useConfig(config(
        destination: LikeDestination.both,
        playlistName: 'Trigger likes',
      ));
    });

    test('a failed liked-songs leg still counts the like and says so', () async {
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenThrow(Exception('liked songs are full'));

      final result = await repo.likeTrack(trackInfo);

      expect(result.trackLiked, true);
      expect(result.likedNatively, false);
      expect(result.addedToLikePlaylist, true);
      expect(result.partialFailureMessage, contains('Liked songs failed'));
      expect(result.partialFailureMessage, contains('Trigger likes'));
    });

    test('a failed playlist leg still counts the like and says so', () async {
      when(() => mockClient.addTracksToPlaylist(
            any(),
            playlistId: any(named: 'playlistId'),
            trackUris: any(named: 'trackUris'),
          )).thenThrow(Exception('playlist is full'));

      final result = await repo.likeTrack(trackInfo);

      expect(result.trackLiked, true);
      expect(result.likedNatively, true);
      expect(result.addedToLikePlaylist, false);
      expect(result.partialFailureMessage, contains('Adding to "Trigger likes"'));
    });

    test('both legs failing fails the like', () async {
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenThrow(Exception('liked songs are full'));
      when(() => mockClient.addTracksToPlaylist(
            any(),
            playlistId: any(named: 'playlistId'),
            trackUris: any(named: 'trackUris'),
          )).thenThrow(Exception('playlist is full'));

      await expectLater(repo.likeTrack(trackInfo), throwsException);
    });
  });
}
