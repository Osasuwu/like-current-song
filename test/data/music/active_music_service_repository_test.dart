import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/music/active_music_service_repository.dart';
import 'package:like_spotify_mobile_app/data/ytmusic/ytmusic_music_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_result.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_service_exceptions.dart';
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

  group('YouTubeMusicServiceRepository (stub)', () {
    const yt = YouTubeMusicServiceRepository();

    test('reports not connected', () async {
      expect((await yt.getAuthState()).connected, isFalse);
    });

    test('like throws MusicServiceNotConnectedException', () async {
      await expectLater(
        yt.likeCurrentTrack(),
        throwsA(
          isA<MusicServiceNotConnectedException>()
              .having((e) => e.provider, 'provider', MusicProvider.ytmusic)
              .having(
                (e) => e.toString(),
                'message',
                'YouTube Music not connected',
              ),
        ),
      );
    });

    test('does not claim auth callbacks', () async {
      expect(
        await yt.handleAuthCallback(Uri.parse('likespotify://auth-callback')),
        isFalse,
      );
    });
  });
}
