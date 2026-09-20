import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_client.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_models.dart'
    as models;
import 'package:like_spotify_mobile_app/data/spotify/spotify_music_service_repository.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_token_store.dart';
import 'package:like_spotify_mobile_app/domain/entities/pending_like.dart';
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
    artistIds: ['artist-1', 'artist-2'],
    artistNames: ['Artist One', 'Artist Two'],
  );

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

    // Default token store stubs
    when(() => mockTokenStore.readClientId())
        .thenAnswer((_) async => 'test-client-id');
    when(() => mockTokenStore.readAccessToken())
        .thenAnswer((_) async => 'valid-token');
    when(() => mockTokenStore.readRefreshToken())
        .thenAnswer((_) async => 'refresh-token');
    when(() => mockTokenStore.readExpiryEpochSec()).thenAnswer(
      (_) async => (DateTime.now().toUtc().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000),
    );

    // Default settings stubs: rules enabled but playlist names empty,
    // matching the original "not configured" default behaviour.
    when(() => mockSettings.loadRuleConfig()).thenAnswer(
      (_) async => const RuleConfig(
        archiveRemoveEnabled: true,
        archivePlaylistName: '',
        bestEnabled: true,
        bestPlaylistName: '',
        bestThreshold: 3,
        followArtistEnabled: true,
        followArtistThreshold: 5,
      ),
    );

    // Default cooldown stubs: no prior like recorded.
    when(() => mockLikeCount.getLastLikedAt(any()))
        .thenAnswer((_) async => null);
    when(() => mockLikeCount.recordLikedAt(any(), any()))
        .thenAnswer((_) async {});
  });

  group('likeTrack', () {
    test('likes track and returns result', () async {
      when(() => mockClient.likeTrack(
            trackId: 'track-123',
            accessToken: 'valid-token',
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount(any()))
          .thenAnswer((_) async => 1);

      final result = await repo.likeTrack(trackInfo);

      expect(result.trackLiked, true);
      expect(result.trackName, 'Test Song');
      expect(result.trackLikeCount, 1);
      expect(result.addedToBest, false);
      expect(result.followedArtistNames, isEmpty);
      verify(() => mockClient.likeTrack(
            trackId: 'track-123',
            accessToken: 'valid-token',
          )).called(1);
    });

    test('adds to best playlist when track reaches 3 likes', () async {
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
          .thenAnswer((_) async => 3);
      when(() => mockLikeCount.incrementArtistLikeCount(any()))
          .thenAnswer((_) async => 1);
      when(() => mockSettings.loadRuleConfig()).thenAnswer(
        (_) async => const RuleConfig(
          archiveRemoveEnabled: true,
          archivePlaylistName: '',
          bestEnabled: true,
          bestPlaylistName: 'Best Of',
          bestThreshold: 3,
          followArtistEnabled: true,
          followArtistThreshold: 5,
        ),
      );
      when(() => mockClient.getUserPlaylists(any(), offset: 0)).thenAnswer(
        (_) async => const models.SpotifyPlaylistPage(
          items: [models.SpotifyPlaylistItem(id: 'best-id', name: 'Best Of')],
          total: 1,
        ),
      );
      when(() => mockClient.addTracksToPlaylist(
            any(),
            playlistId: 'best-id',
            trackUris: ['spotify:track:track-123'],
          )).thenAnswer((_) async {});

      final result = await repo.likeTrack(trackInfo);

      expect(result.addedToBest, true);
      expect(result.trackLikeCount, 3);
    });

    test('does not add to best when count is not exactly 3', () async {
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
          .thenAnswer((_) async => 4);
      when(() => mockLikeCount.incrementArtistLikeCount(any()))
          .thenAnswer((_) async => 1);

      final result = await repo.likeTrack(trackInfo);

      expect(result.addedToBest, false);
    });

    test('auto-follows artist when they reach 5 likes', () async {
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount('artist-1'))
          .thenAnswer((_) async => 5);
      when(() => mockLikeCount.incrementArtistLikeCount('artist-2'))
          .thenAnswer((_) async => 2);
      when(() => mockClient.followArtists(
            any(),
            artistIds: ['artist-1'],
          )).thenAnswer((_) async {});

      final result = await repo.likeTrack(trackInfo);

      expect(result.followedArtistNames, ['Artist One']);
      verify(() => mockClient.followArtists(
            any(),
            artistIds: ['artist-1'],
          )).called(1);
      verifyNever(() => mockClient.followArtists(
            any(),
            artistIds: ['artist-2'],
          ));
    });

    test('removes from archive playlist when configured', () async {
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount(any()))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount(any()))
          .thenAnswer((_) async => 1);
      when(() => mockSettings.loadRuleConfig()).thenAnswer(
        (_) async => const RuleConfig(
          archiveRemoveEnabled: true,
          archivePlaylistName: 'Discover Weekly Archive',
          bestEnabled: true,
          bestPlaylistName: '',
          bestThreshold: 3,
          followArtistEnabled: true,
          followArtistThreshold: 5,
        ),
      );
      when(() => mockClient.getUserPlaylists(any(), offset: 0)).thenAnswer(
        (_) async => const models.SpotifyPlaylistPage(
          items: [
            models.SpotifyPlaylistItem(
                id: 'archive-id', name: 'Discover Weekly Archive'),
          ],
          total: 1,
        ),
      );
      when(() => mockClient.removeTracksFromPlaylist(
            any(),
            playlistId: 'archive-id',
            trackUris: ['spotify:track:track-123'],
          )).thenAnswer((_) async {});

      final result = await repo.likeTrack(trackInfo);

      expect(result.removedFromArchive, true);
    });

    test('skips liking when track was liked within the cooldown window', () async {
      when(() => mockLikeCount.getLastLikedAt('track-123')).thenAnswer(
        (_) async => DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
      );
      when(() => mockLikeCount.getTrackLikeCount('track-123'))
          .thenAnswer((_) async => 1);

      final result = await repo.likeTrack(trackInfo);

      expect(result.trackLiked, false);
      expect(result.skippedCooldown, true);
      expect(result.trackLikeCount, 1);
      verifyNever(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          ));
    });

    test('likes track when the cooldown window has expired', () async {
      when(() => mockLikeCount.getLastLikedAt('track-123')).thenAnswer(
        (_) async => DateTime.now().toUtc().subtract(const Duration(minutes: 11)),
      );
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount(any()))
          .thenAnswer((_) async => 2);
      when(() => mockLikeCount.incrementArtistLikeCount(any()))
          .thenAnswer((_) async => 1);

      final result = await repo.likeTrack(trackInfo);

      expect(result.trackLiked, true);
      expect(result.skippedCooldown, false);
      verify(() => mockClient.likeTrack(
            trackId: 'track-123',
            accessToken: 'valid-token',
          )).called(1);
    });

    test('likes track regardless of last-liked time when cooldown is disabled', () async {
      when(() => mockSettings.loadRuleConfig()).thenAnswer(
        (_) async => const RuleConfig(
          archiveRemoveEnabled: true,
          archivePlaylistName: '',
          bestEnabled: true,
          bestPlaylistName: '',
          bestThreshold: 3,
          followArtistEnabled: true,
          followArtistThreshold: 5,
          likeCooldownEnabled: false,
        ),
      );
      when(() => mockLikeCount.getLastLikedAt('track-123')).thenAnswer(
        (_) async => DateTime.now().toUtc(),
      );
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount(any()))
          .thenAnswer((_) async => 2);
      when(() => mockLikeCount.incrementArtistLikeCount(any()))
          .thenAnswer((_) async => 1);

      final result = await repo.likeTrack(trackInfo);

      expect(result.trackLiked, true);
      expect(result.skippedCooldown, false);
    });
  });

  group('likeCurrentTrack', () {
    test('gets current track and delegates to likeTrack', () async {
      when(() => mockClient.getCurrentlyPlayingFull('valid-token'))
          .thenAnswer((_) async => trackInfo);
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount(any()))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount(any()))
          .thenAnswer((_) async => 1);

      final result = await repo.likeCurrentTrack();

      expect(result.trackLiked, true);
      expect(result.trackName, 'Test Song');
    });

    test('retries on SpotifyAuthException', () async {
      var callCount = 0;
      when(() => mockClient.getCurrentlyPlayingFull('valid-token'))
          .thenAnswer((_) async {
        callCount++;
        if (callCount == 1) throw SpotifyAuthException('expired');
        return trackInfo;
      });
      when(() => mockClient.refreshToken(
            refreshToken: any(named: 'refreshToken'),
            clientId: any(named: 'clientId'),
          )).thenAnswer((_) async => const models.SpotifyTokenResponse(
            accessToken: 'new-token',
            refreshToken: 'new-refresh',
            expiresInSec: 3600,
          ));
      when(() => mockTokenStore.save(
            accessToken: any(named: 'accessToken'),
            refreshToken: any(named: 'refreshToken'),
            expiresAtEpochSec: any(named: 'expiresAtEpochSec'),
          )).thenAnswer((_) async {});
      when(() => mockPlatform.syncSpotifyTokens(
            accessToken: any(named: 'accessToken'),
            refreshToken: any(named: 'refreshToken'),
            expiresAtEpochSec: any(named: 'expiresAtEpochSec'),
            clientId: any(named: 'clientId'),
          )).thenAnswer((_) async {});
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount(any()))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount(any()))
          .thenAnswer((_) async => 1);

      final result = await repo.likeCurrentTrack();
      expect(result.trackLiked, true);
    });

    test('throws when no track is playing', () async {
      when(() => mockClient.getCurrentlyPlayingFull('valid-token'))
          .thenAnswer((_) async => null);

      expect(() => repo.likeCurrentTrack(), throwsException);
    });
  });

  group('processPendingLikes', () {
    test('processes all pending likes', () async {
      final pending = [
        PendingLike(
          trackId: 'p-1',
          trackName: 'Pending 1',
          artistIds: ['a-1'],
          artistNames: ['Artist 1'],
          queuedAt: DateTime.now(),
        ),
        PendingLike(
          trackId: 'p-2',
          trackName: 'Pending 2',
          artistIds: ['a-2'],
          artistNames: ['Artist 2'],
          queuedAt: DateTime.now(),
        ),
      ];

      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount(any()))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount(any()))
          .thenAnswer((_) async => 1);
      when(() => mockSettings.removePendingLike(any()))
          .thenAnswer((_) async {});

      final count = await repo.processPendingLikes(pending);

      expect(count, 2);
      verify(() => mockSettings.removePendingLike('p-1')).called(1);
      verify(() => mockSettings.removePendingLike('p-2')).called(1);
    });

    test('stops on first failure', () async {
      final pending = [
        PendingLike(
          trackId: 'p-1',
          trackName: 'Pending 1',
          artistIds: [],
          artistNames: [],
          queuedAt: DateTime.now(),
        ),
        PendingLike(
          trackId: 'p-2',
          trackName: 'Pending 2',
          artistIds: [],
          artistNames: [],
          queuedAt: DateTime.now(),
        ),
      ];

      when(() => mockClient.likeTrack(
            trackId: 'p-1',
            accessToken: any(named: 'accessToken'),
          )).thenThrow(Exception('Network error'));

      final count = await repo.processPendingLikes(pending);

      expect(count, 0);
      verifyNever(() => mockSettings.removePendingLike(any()));
    });
  });

  group('ensureUserId', () {
    test('asks Spotify for the id without creating a playlist first', () async {
      // The regression: the id used to be a side effect of playlist creation,
      // so with the playlist rules off -- the default -- the shared like
      // counter never had a key for its rows and every like silently stayed
      // on the device while the user's sheet stayed empty.
      when(() => mockClient.getCurrentUserId('valid-token'))
          .thenAnswer((_) async => 'spotify-user');

      expect(await repo.ensureUserId(), 'spotify-user');
      verifyNever(() => mockClient.getUserPlaylists(any(), offset: any(named: 'offset')));
      verifyNever(() => mockClient.createPlaylist(any(),
          userId: any(named: 'userId'), name: any(named: 'name')));
    });

    test('asks once and keeps the answer', () async {
      when(() => mockClient.getCurrentUserId(any()))
          .thenAnswer((_) async => 'spotify-user');

      expect(await repo.ensureUserId(), 'spotify-user');
      expect(await repo.ensureUserId(), 'spotify-user');

      verify(() => mockClient.getCurrentUserId(any())).called(1);
    });

    test('answers null when the lookup fails, rather than throwing', () async {
      // A like must not fail because the counter could not name its row; the
      // caller reads null as "count locally for this press".
      when(() => mockClient.getCurrentUserId(any()))
          .thenThrow(Exception('network down'));

      expect(await repo.ensureUserId(), isNull);
    });
  });
}

