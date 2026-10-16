import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:like_spotify_mobile_app/data/settings/shared_prefs_settings_repository.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_client.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_models.dart'
    as models;
import 'package:like_spotify_mobile_app/data/spotify/spotify_music_service_repository.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_token_store.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/domain/entities/pending_like.dart';
import 'package:like_spotify_mobile_app/domain/entities/rule_config.dart';
import 'package:like_spotify_mobile_app/domain/entities/track_info.dart';
import 'package:like_spotify_mobile_app/domain/repositories/like_count_repository.dart';
import 'package:like_spotify_mobile_app/domain/repositories/platform_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockSpotifyClient extends Mock implements SpotifyClient {}

class MockSpotifyTokenStore extends Mock implements SpotifyTokenStore {}

class MockPlatformServiceRepository extends Mock
    implements PlatformServiceRepository {}

class MockLikeCountRepository extends Mock implements LikeCountRepository {}

class MockSettingsRepository extends Mock implements SettingsRepository {}

/// Only ever handed to `any()`, never looked at.
class _FakeAppLog extends Fake implements AppLog {}

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

  setUpAll(() {
    registerFallbackValue(_FakeAppLog());
  });

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

    // Default follow stubs: nobody has been auto-followed yet.
    when(() => mockPlatform.loadFollowedArtists())
        .thenAnswer((_) async => <String>{});
    when(() => mockPlatform.markArtistFollowed(any()))
        .thenAnswer((_) async {});

    // Default best stubs: nothing promoted yet; logging succeeds.
    when(() => mockSettings.loadPromotedTracks())
        .thenAnswer((_) async => <String>{});
    when(() => mockSettings.markTrackPromoted(any()))
        .thenAnswer((_) async {});
    when(() => mockSettings.appendLog(any())).thenAnswer((_) async {});
  });

  group('likeTrack', () {
    test('likes track and returns result', () async {
      when(() => mockClient.likeTrack(
            trackId: 'track-123',
            accessToken: 'valid-token',
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount(any(),
              trackId: any(named: 'trackId')))
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

    group('best playlist', () {
      const bestConfig = RuleConfig(
        archiveRemoveEnabled: true,
        archivePlaylistName: '',
        bestEnabled: true,
        bestPlaylistName: 'Best Of',
        bestThreshold: 3,
        followArtistEnabled: true,
        followArtistThreshold: 5,
      );

      void stubLikeAt(int trackCount) {
        when(() => mockClient.likeTrack(
              trackId: any(named: 'trackId'),
              accessToken: any(named: 'accessToken'),
            )).thenAnswer((_) async {});
        when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
            .thenAnswer((_) async => trackCount);
        when(() => mockLikeCount.incrementArtistLikeCount(any(),
                trackId: any(named: 'trackId')))
            .thenAnswer((_) async => 1);
      }

      void stubBestPlaylist({required bool containsTrack}) {
        when(() => mockClient.getUserPlaylists(any(), offset: 0)).thenAnswer(
          (_) async => const models.SpotifyPlaylistPage(
            items: [models.SpotifyPlaylistItem(id: 'best-id', name: 'Best Of')],
            total: 1,
          ),
        );
        when(() => mockClient.playlistContainsTrack(any(),
                playlistId: 'best-id', trackId: 'track-123'))
            .thenAnswer((_) async => containsTrack);
        when(() => mockClient.addTracksToPlaylist(
              any(),
              playlistId: 'best-id',
              trackUris: ['spotify:track:track-123'],
            )).thenAnswer((_) async {});
      }

      setUp(() {
        when(() => mockSettings.loadRuleConfig())
            .thenAnswer((_) async => bestConfig);
      });

      test('adds a track that reaches the threshold, and remembers it',
          () async {
        stubLikeAt(3);
        stubBestPlaylist(containsTrack: false);

        final result = await repo.likeTrack(trackInfo);

        expect(result.addedToBest, true);
        expect(result.trackLikeCount, 3);
        verify(() => mockClient.addTracksToPlaylist(any(),
            playlistId: 'best-id',
            trackUris: ['spotify:track:track-123'])).called(1);
        verify(() => mockSettings.markTrackPromoted('track-123')).called(1);
      });

      test('adds a track whose count is already past the threshold', () async {
        // A lowered threshold, or likes counted on another device, can carry a
        // count past the threshold without ever landing on it (#245, #253).
        stubLikeAt(5);
        stubBestPlaylist(containsTrack: false);

        final result = await repo.likeTrack(trackInfo);

        expect(result.addedToBest, true);
        verify(() => mockClient.addTracksToPlaylist(any(),
            playlistId: 'best-id',
            trackUris: ['spotify:track:track-123'])).called(1);
        verify(() => mockSettings.markTrackPromoted('track-123')).called(1);
      });

      test('does nothing below the threshold', () async {
        stubLikeAt(2);
        stubBestPlaylist(containsTrack: false);

        final result = await repo.likeTrack(trackInfo);

        expect(result.addedToBest, false);
        verifyNever(() => mockClient.playlistContainsTrack(any(),
            playlistId: any(named: 'playlistId'),
            trackId: any(named: 'trackId')));
        verifyNever(() => mockClient.addTracksToPlaylist(any(),
            playlistId: any(named: 'playlistId'),
            trackUris: any(named: 'trackUris')));
        verifyNever(() => mockSettings.markTrackPromoted(any()));
      });

      test('does not add a track this device already promoted', () async {
        stubLikeAt(4);
        stubBestPlaylist(containsTrack: false);
        when(() => mockSettings.loadPromotedTracks())
            .thenAnswer((_) async => <String>{'track-123'});

        final result = await repo.likeTrack(trackInfo);

        expect(result.addedToBest, false);
        verifyNever(() => mockClient.playlistContainsTrack(any(),
            playlistId: any(named: 'playlistId'),
            trackId: any(named: 'trackId')));
        verifyNever(() => mockClient.addTracksToPlaylist(any(),
            playlistId: any(named: 'playlistId'),
            trackUris: any(named: 'trackUris')));
        verifyNever(() => mockSettings.markTrackPromoted(any()));
      });

      test('only remembers a track that is in the playlist already', () async {
        // Promoted by the background path, by another device, or before this
        // memory existed: a second copy is the one thing this must not make.
        stubLikeAt(4);
        stubBestPlaylist(containsTrack: true);

        final result = await repo.likeTrack(trackInfo);

        expect(result.addedToBest, false);
        verifyNever(() => mockClient.addTracksToPlaylist(any(),
            playlistId: any(named: 'playlistId'),
            trackUris: any(named: 'trackUris')));
        verify(() => mockSettings.markTrackPromoted('track-123')).called(1);
      });

      test('does not remember an add Spotify refused, and logs it', () async {
        stubLikeAt(3);
        stubBestPlaylist(containsTrack: false);
        when(() => mockClient.addTracksToPlaylist(any(),
                playlistId: 'best-id',
                trackUris: ['spotify:track:track-123']))
            .thenThrow(SpotifyApiException(500, 'Server error'));

        final result = await repo.likeTrack(trackInfo);

        expect(result.addedToBest, false);
        verifyNever(() => mockSettings.markTrackPromoted(any()));
        final logged = verify(() => mockSettings.appendLog(captureAny()))
            .captured
            .cast<AppLog>()
            .where((log) => log.actionType == 'best_add')
            .toList();
        expect(logged, hasLength(1));
        expect(logged.single.result, LogResult.failure);
        expect(logged.single.httpCode, 500);
      });

      test('does not add when the membership check fails', () async {
        stubLikeAt(3);
        stubBestPlaylist(containsTrack: false);
        when(() => mockClient.playlistContainsTrack(any(),
                playlistId: 'best-id', trackId: 'track-123'))
            .thenThrow(SpotifyApiException(503, 'Unavailable'));

        final result = await repo.likeTrack(trackInfo);

        expect(result.addedToBest, false);
        verifyNever(() => mockClient.addTracksToPlaylist(any(),
            playlistId: any(named: 'playlistId'),
            trackUris: any(named: 'trackUris')));
        verifyNever(() => mockSettings.markTrackPromoted(any()));
      });

      test('a promoted track stays promoted across a restart', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        await SharedPrefsSettingsRepository().saveRuleConfig(bestConfig);
        stubLikeAt(3);
        stubBestPlaylist(containsTrack: false);

        SpotifyMusicServiceRepository freshRepo() =>
            SpotifyMusicServiceRepository(
              spotifyClient: mockClient,
              tokenStore: mockTokenStore,
              platformServiceRepository: mockPlatform,
              likeCountRepository: mockLikeCount,
              settingsRepository: SharedPrefsSettingsRepository(),
            );

        expect((await freshRepo().likeTrack(trackInfo)).addedToBest, true);

        // The app restarts: new instances, the same stored preferences. The
        // playlist still reads as not containing the track, so only the
        // memory can stop a second add.
        stubLikeAt(4);
        expect((await freshRepo().likeTrack(trackInfo)).addedToBest, false);

        verify(() => mockClient.addTracksToPlaylist(any(),
            playlistId: 'best-id',
            trackUris: ['spotify:track:track-123'])).called(1);
      });
    });

    test('auto-follows artist when they reach 5 likes', () async {
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount('artist-1',
              trackId: any(named: 'trackId')))
          .thenAnswer((_) async => 5);
      when(() => mockLikeCount.incrementArtistLikeCount('artist-2',
              trackId: any(named: 'trackId')))
          .thenAnswer((_) async => 2);
      when(() => mockClient.followArtists(
            any(),
            artistIds: ['artist-1'],
          )).thenAnswer((_) async {});

      final result = await repo.likeTrack(trackInfo);

      expect(result.followedArtistNames, ['Artist One']);
      // The track goes along, so a shared counter can count distinct tracks
      // across devices rather than presses on this one (#209).
      verify(() => mockLikeCount.incrementArtistLikeCount(
            'artist-1',
            trackId: 'track-123',
          )).called(1);
      verify(() => mockClient.followArtists(
            any(),
            artistIds: ['artist-1'],
          )).called(1);
      verifyNever(() => mockClient.followArtists(
            any(),
            artistIds: ['artist-2'],
          ));
    });

    test('follows an artist whose count is already past the threshold',
        () async {
      // What the unified counter makes possible: the merge can push a count
      // from below the threshold to well past it in one step, and the rule
      // still has to fire.
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount('artist-1',
              trackId: any(named: 'trackId')))
          .thenAnswer((_) async => 11);
      when(() => mockLikeCount.incrementArtistLikeCount('artist-2',
              trackId: any(named: 'trackId')))
          .thenAnswer((_) async => 2);
      when(() => mockClient.followArtists(any(), artistIds: ['artist-1']))
          .thenAnswer((_) async {});

      final result = await repo.likeTrack(trackInfo);

      expect(result.followedArtistNames, ['Artist One']);
      verify(() => mockPlatform.markArtistFollowed('artist-1')).called(1);
    });

    test('does not follow an artist this device already followed', () async {
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount(any(),
              trackId: any(named: 'trackId')))
          .thenAnswer((_) async => 11);
      when(() => mockPlatform.loadFollowedArtists())
          .thenAnswer((_) async => <String>{'artist-1', 'artist-2'});

      final result = await repo.likeTrack(trackInfo);

      expect(result.followedArtistNames, isEmpty);
      verifyNever(() => mockClient.followArtists(
            any(),
            artistIds: any(named: 'artistIds'),
          ));
      verifyNever(() => mockPlatform.markArtistFollowed(any()));
    });

    test('does not remember a follow Spotify refused', () async {
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount('artist-1',
              trackId: any(named: 'trackId')))
          .thenAnswer((_) async => 5);
      when(() => mockLikeCount.incrementArtistLikeCount('artist-2',
              trackId: any(named: 'trackId')))
          .thenAnswer((_) async => 1);
      when(() => mockClient.followArtists(any(), artistIds: ['artist-1']))
          .thenThrow(Exception('follow refused'));
      when(() => mockSettings.appendLog(any())).thenAnswer((_) async {});

      final result = await repo.likeTrack(trackInfo);

      expect(result.followedArtistNames, isEmpty);
      verifyNever(() => mockPlatform.markArtistFollowed(any()));
    });

    test('does not read the followed set when the rule is off', () async {
      when(() => mockSettings.loadRuleConfig()).thenAnswer(
        (_) async => const RuleConfig(
          archiveRemoveEnabled: false,
          archivePlaylistName: '',
          bestEnabled: false,
          bestPlaylistName: '',
          bestThreshold: 3,
          followArtistEnabled: false,
          followArtistThreshold: 5,
        ),
      );
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount('track-123'))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount(any(),
              trackId: any(named: 'trackId')))
          .thenAnswer((_) async => 11);

      final result = await repo.likeTrack(trackInfo);

      expect(result.followedArtistNames, isEmpty);
      verifyNever(() => mockPlatform.loadFollowedArtists());
    });

    test('removes from archive playlist when configured', () async {
      when(() => mockClient.likeTrack(
            trackId: any(named: 'trackId'),
            accessToken: any(named: 'accessToken'),
          )).thenAnswer((_) async {});
      when(() => mockLikeCount.incrementTrackLikeCount(any()))
          .thenAnswer((_) async => 1);
      when(() => mockLikeCount.incrementArtistLikeCount(any(),
              trackId: any(named: 'trackId')))
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
      when(() => mockLikeCount.incrementArtistLikeCount(any(),
              trackId: any(named: 'trackId')))
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
      when(() => mockLikeCount.incrementArtistLikeCount(any(),
              trackId: any(named: 'trackId')))
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
      when(() => mockLikeCount.incrementArtistLikeCount(any(),
              trackId: any(named: 'trackId')))
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
      when(() => mockLikeCount.incrementArtistLikeCount(any(),
              trackId: any(named: 'trackId')))
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
      when(() => mockLikeCount.incrementArtistLikeCount(any(),
              trackId: any(named: 'trackId')))
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

    test('forgets the id on disconnect, on both sides', () async {
      // The id is cached forever -- in memory here and in SharedPreferences
      // natively -- and keys the shared counter's rows. Signing in as someone
      // else and keeping it would file their likes under the old account.
      when(() => mockTokenStore.clear()).thenAnswer((_) async {});
      when(() => mockPlatform.clearSpotifyUserId()).thenAnswer((_) async {});
      when(() => mockClient.getCurrentUserId(any()))
          .thenAnswer((_) async => 'first-account');

      expect(await repo.ensureUserId(), 'first-account');
      await repo.disconnect();

      verify(() => mockPlatform.clearSpotifyUserId()).called(1);

      when(() => mockClient.getCurrentUserId(any()))
          .thenAnswer((_) async => 'second-account');
      expect(await repo.ensureUserId(), 'second-account');
    });

    test('a native side that cannot forget it does not fail the disconnect',
        () async {
      when(() => mockTokenStore.clear()).thenAnswer((_) async {});
      when(() => mockPlatform.clearSpotifyUserId())
          .thenThrow(Exception('no channel'));

      await expectLater(repo.disconnect(), completes);
    });
  });
}

