import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/music/active_music_service_repository.dart';
import 'package:like_spotify_mobile_app/data/ytmusic/ytmusic_music_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_result.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_service_exceptions.dart';
import 'package:like_spotify_mobile_app/domain/entities/pending_like.dart';
import 'package:like_spotify_mobile_app/domain/entities/spotify_auth_state.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

void main() {
  late MockSettingsRepository settings;
  late MockMusicServiceRepository spotify;
  late MockMusicServiceRepository ytmusic;
  late ActiveMusicServiceRepository repo;

  const liked = LikeResult(
    trackId: 't1',
    trackName: 'Song',
    trackLiked: true,
  );

  void select(MusicProvider provider) {
    when(() => settings.loadMusicProvider()).thenAnswer((_) async => provider);
  }

  setUp(() {
    settings = MockSettingsRepository();
    spotify = MockMusicServiceRepository();
    ytmusic = MockMusicServiceRepository();
    repo = ActiveMusicServiceRepository(
      settingsRepository: settings,
      repositories: {
        MusicProvider.spotify: spotify,
        MusicProvider.ytmusic: ytmusic,
      },
    );
  });

  group('provider resolution', () {
    test('routes to Spotify when Spotify is selected', () async {
      select(MusicProvider.spotify);
      when(() => spotify.likeCurrentTrack()).thenAnswer((_) async => liked);

      expect(await repo.likeCurrentTrack(), same(liked));
      verify(() => spotify.likeCurrentTrack()).called(1);
      verifyZeroInteractions(ytmusic);
    });

    test('routes to YouTube Music and makes no Spotify call', () async {
      select(MusicProvider.ytmusic);
      when(() => ytmusic.likeCurrentTrack()).thenThrow(
        const MusicServiceNotConnectedException(MusicProvider.ytmusic),
      );

      await expectLater(
        repo.likeCurrentTrack(),
        throwsA(isA<MusicServiceNotConnectedException>()),
      );
      verifyZeroInteractions(spotify);
    });

    test('reads the selection on every call', () async {
      when(() => spotify.getAuthState())
          .thenAnswer((_) async => const SpotifyAuthState.disconnected());
      when(() => ytmusic.getAuthState())
          .thenAnswer((_) async => const SpotifyAuthState.disconnected());

      select(MusicProvider.spotify);
      await repo.getAuthState();
      select(MusicProvider.ytmusic);
      await repo.getAuthState();

      verify(() => spotify.getAuthState()).called(1);
      verify(() => ytmusic.getAuthState()).called(1);
    });

    test('connect and disconnect go to the selected service only', () async {
      select(MusicProvider.ytmusic);
      when(() => ytmusic.connect())
          .thenAnswer((_) async => const SpotifyAuthState.disconnected());
      when(() => ytmusic.disconnect()).thenAnswer((_) async {});

      await repo.connect();
      await repo.disconnect();

      verify(() => ytmusic.connect()).called(1);
      verify(() => ytmusic.disconnect()).called(1);
      verifyZeroInteractions(spotify);
    });

    test('resolve() returns the selected repository', () async {
      select(MusicProvider.ytmusic);
      expect(await repo.resolve(), same(ytmusic));
      select(MusicProvider.spotify);
      expect(await repo.resolve(), same(spotify));
    });
  });

  group('handleAuthCallback', () {
    final uri = Uri.parse('likespotify://auth-callback?code=abc');

    test('is offered to every service regardless of selection', () async {
      select(MusicProvider.ytmusic);
      when(() => ytmusic.handleAuthCallback(uri)).thenAnswer((_) async => false);
      when(() => spotify.handleAuthCallback(uri)).thenAnswer((_) async => true);

      expect(await repo.handleAuthCallback(uri), isTrue);
      verify(() => spotify.handleAuthCallback(uri)).called(1);
    });

    test('returns false when no service claims the link', () async {
      when(() => ytmusic.handleAuthCallback(uri)).thenAnswer((_) async => false);
      when(() => spotify.handleAuthCallback(uri)).thenAnswer((_) async => false);

      expect(await repo.handleAuthCallback(uri), isFalse);
    });
  });

  test('rejects a registry that is missing a provider', () {
    expect(
      () => ActiveMusicServiceRepository(
        settingsRepository: settings,
        repositories: {MusicProvider.spotify: spotify},
      ),
      throwsArgumentError,
    );
  });

  group('pending likes', () {
    PendingLike queued(String id, MusicProvider provider) => PendingLike(
          trackId: id,
          trackName: id,
          artistIds: const [],
          artistNames: const [],
          queuedAt: DateTime.utc(2025, 1, 1),
          providerId: provider.id,
        );

    final spotifyLike = queued('s1', MusicProvider.spotify);
    final ytLike = queued('y1', MusicProvider.ytmusic);

    setUpAll(() => registerFallbackValue(<PendingLike>[]));

    test('only the selected service replays, and only its own likes', () async {
      select(MusicProvider.spotify);
      when(() => spotify.processPendingLikes(any())).thenAnswer((_) async => 1);

      expect(await repo.processPendingLikes([spotifyLike, ytLike]), 1);

      final handed = verify(() => spotify.processPendingLikes(captureAny()))
          .captured
          .single as List<PendingLike>;
      expect(handed, [spotifyLike]);
      verifyZeroInteractions(ytmusic);
    });

    test('a Spotify like is never handed to YouTube Music', () async {
      select(MusicProvider.ytmusic);

      expect(await repo.processPendingLikes([spotifyLike]), 0);
      verifyZeroInteractions(ytmusic);
      verifyZeroInteractions(spotify);
    });
  });

  group('YouTubeMusicServiceRepository', () {
    late MockPlatformServiceRepository platform;
    late YouTubeMusicServiceRepository yt;

    void reply(Map<String, dynamic> map) {
      when(() => platform.likeYouTubeMusicCurrentTrack())
          .thenAnswer((_) async => map);
    }

    setUp(() {
      platform = MockPlatformServiceRepository();
      yt = YouTubeMusicServiceRepository(platformServiceRepository: platform);
    });

    test('reports not connected', () async {
      expect((await yt.getAuthState()).connected, isFalse);
    });

    test('a session like is a liked result', () async {
      reply({'outcome': 'liked', 'trackName': 'Song — Artist'});

      final result = await yt.likeCurrentTrack();

      expect(result.trackLiked, isTrue);
      expect(result.alreadyLiked, isFalse);
      expect(result.trackName, 'Song — Artist');
    });

    test('an already-liked song counts as liked', () async {
      reply({'outcome': 'already_liked', 'trackName': 'Song'});

      final result = await yt.likeCurrentTrack();

      expect(result.trackLiked, isTrue);
      expect(result.alreadyLiked, isTrue);
    });

    test('a cooldown skip is not a like', () async {
      reply({'outcome': 'cooldown', 'trackName': 'Song'});

      final result = await yt.likeCurrentTrack();

      expect(result.trackLiked, isFalse);
      expect(result.skippedCooldown, isTrue);
    });

    test('an API failure carries its HTTP status', () async {
      reply({'outcome': 'failed', 'message': 'forbidden', 'httpCode': 403});

      await expectLater(
        yt.likeCurrentTrack(),
        throwsA(
          isA<MusicServiceHttpException>()
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
    });

    test('a failure without a status is a plain like failure', () async {
      reply({
        'outcome': 'failed',
        'message': 'YouTube Music is not playing',
      });

      await expectLater(
        yt.likeCurrentTrack(),
        throwsA(
          isA<YouTubeMusicLikeException>()
              .having((e) => e is MusicServiceHttpException, 'http', isFalse)
              .having(
                (e) => e.toString(),
                'message',
                'YouTube Music is not playing',
              ),
        ),
      );
    });

    test('never replays queued likes', () async {
      expect(
        await yt.processPendingLikes([
          PendingLike(
            trackId: 'x',
            trackName: 'x',
            artistIds: const [],
            artistNames: const [],
            queuedAt: DateTime.utc(2025, 1, 1),
            providerId: MusicProvider.ytmusic.id,
          ),
        ]),
        0,
      );
      verifyZeroInteractions(platform);
    });

    test('does not claim auth callbacks', () async {
      expect(
        await yt.handleAuthCallback(Uri.parse('likespotify://auth-callback')),
        isFalse,
      );
    });
  });
}
