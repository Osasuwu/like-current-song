import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/music/active_music_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_result.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_routing.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_service_exceptions.dart';
import 'package:like_spotify_mobile_app/domain/entities/pending_like.dart';
import 'package:like_spotify_mobile_app/domain/entities/spotify_auth_state.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

void main() {
  late MockSettingsRepository settings;
  late MockPlatformServiceRepository platform;
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

  /// Turns automatic routing on, as the Connected services screen would.
  void automatic() {
    when(() => settings.loadMusicRoutingMode())
        .thenAnswer((_) async => MusicRoutingMode.automatic);
  }

  /// What the native side reports about media sessions.
  void sessions({
    List<MusicProvider> playing = const <MusicProvider>[],
    MusicProvider? lastPlaying,
  }) {
    when(() => platform.readMusicSessions()).thenAnswer(
      (_) async => MusicSessionSnapshot(
        playing: playing,
        lastPlaying: lastPlaying,
      ),
    );
  }

  /// Which services are signed in; anything else reports disconnected.
  void connected(Set<MusicProvider> providers) {
    final repos = <MusicProvider, MockMusicServiceRepository>{
      MusicProvider.spotify: spotify,
      MusicProvider.ytmusic: ytmusic,
    };
    repos.forEach((provider, repository) {
      when(() => repository.getAuthState()).thenAnswer(
        (_) async => providers.contains(provider)
            ? SpotifyAuthState(
                accessToken: 'token',
                refreshToken: null,
                expiresAt: null,
                connected: true,
                accountId: provider.id,
              )
            : const SpotifyAuthState.disconnected(),
      );
    });
  }

  setUp(() {
    settings = MockSettingsRepository();
    platform = MockPlatformServiceRepository();
    spotify = MockMusicServiceRepository();
    ytmusic = MockMusicServiceRepository();
    repo = ActiveMusicServiceRepository(
      settingsRepository: settings,
      platformServiceRepository: platform,
      repositories: {
        MusicProvider.spotify: spotify,
        MusicProvider.ytmusic: ytmusic,
      },
    );
    // The default everywhere: automatic is opt-in, so every test that does not
    // turn it on is testing the picker.
    when(() => settings.loadMusicRoutingMode())
        .thenAnswer((_) async => MusicRoutingMode.picker);
    sessions();
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

  // The Dart half of the rule mirrored in `MusicProvider.resolve` (Kotlin).
  group('automatic routing', () {
    test('the picked service wins while automatic is off, whatever plays',
        () async {
      select(MusicProvider.spotify);
      connected(<MusicProvider>{MusicProvider.spotify, MusicProvider.ytmusic});
      sessions(playing: <MusicProvider>[MusicProvider.ytmusic]);

      expect(
        await repo.resolveRouting(),
        const MusicRoutingDecision(
          provider: MusicProvider.spotify,
          reason: MusicRoutingReason.picker,
        ),
        reason: 'automatic is opt-in: an upgraded install must not move',
      );
      verifyNever(() => platform.readMusicSessions());
    });

    test('a playing session beats the picked service', () async {
      select(MusicProvider.spotify);
      automatic();
      connected(<MusicProvider>{MusicProvider.spotify, MusicProvider.ytmusic});
      sessions(
        playing: <MusicProvider>[MusicProvider.ytmusic],
        lastPlaying: MusicProvider.spotify,
      );
      when(() => ytmusic.likeCurrentTrack()).thenAnswer((_) async => liked);

      expect(
        await repo.resolveRouting(),
        const MusicRoutingDecision(
          provider: MusicProvider.ytmusic,
          reason: MusicRoutingReason.playingSession,
        ),
      );
      expect(await repo.likeCurrentTrack(), same(liked));
      verifyNever(() => spotify.likeCurrentTrack());
    });

    test('nothing playing falls back to the service that played last',
        () async {
      select(MusicProvider.spotify);
      automatic();
      connected(<MusicProvider>{MusicProvider.spotify, MusicProvider.ytmusic});
      sessions(lastPlaying: MusicProvider.ytmusic);

      expect(
        await repo.resolveRouting(),
        const MusicRoutingDecision(
          provider: MusicProvider.ytmusic,
          reason: MusicRoutingReason.lastPlaying,
        ),
      );
    });

    test('two services playing at once is no answer either', () async {
      select(MusicProvider.spotify);
      automatic();
      connected(<MusicProvider>{MusicProvider.spotify, MusicProvider.ytmusic});
      sessions(
        playing: <MusicProvider>[MusicProvider.spotify, MusicProvider.ytmusic],
        lastPlaying: MusicProvider.ytmusic,
      );

      expect(
        (await repo.resolveRouting()).reason,
        MusicRoutingReason.lastPlaying,
      );
    });

    test('with neither session nor history, the picked service stands in',
        () async {
      select(MusicProvider.ytmusic);
      automatic();
      connected(<MusicProvider>{MusicProvider.spotify, MusicProvider.ytmusic});
      sessions();

      expect(
        await repo.resolveRouting(),
        const MusicRoutingDecision(
          provider: MusicProvider.ytmusic,
          reason: MusicRoutingReason.pickerFallback,
        ),
      );
    });

    test('an unreadable snapshot is the same as an empty one', () async {
      select(MusicProvider.spotify);
      automatic();
      connected(<MusicProvider>{MusicProvider.spotify, MusicProvider.ytmusic});
      // No notification access: the platform call throws rather than answers.
      when(() => platform.readMusicSessions())
          .thenThrow(Exception('permission denied'));

      expect(
        await repo.resolveRouting(),
        const MusicRoutingDecision(
          provider: MusicProvider.spotify,
          reason: MusicRoutingReason.pickerFallback,
        ),
      );
    });

    test('a service that is not signed in is never chosen', () async {
      select(MusicProvider.spotify);
      automatic();
      connected(<MusicProvider>{MusicProvider.spotify});
      // YouTube Music is both playing now and the last one that played, and
      // still loses: a like sent to a signed-out service goes nowhere.
      sessions(
        playing: <MusicProvider>[MusicProvider.ytmusic],
        lastPlaying: MusicProvider.ytmusic,
      );

      expect(
        await repo.resolveRouting(),
        const MusicRoutingDecision(
          provider: MusicProvider.spotify,
          reason: MusicRoutingReason.pickerFallback,
        ),
      );
    });

    test('reports each automatic decision, and only those', () async {
      final decisions = <MusicRoutingDecision>[];
      repo.onAutomaticRouting = decisions.add;
      select(MusicProvider.spotify);
      connected(<MusicProvider>{MusicProvider.spotify, MusicProvider.ytmusic});
      sessions(playing: <MusicProvider>[MusicProvider.ytmusic]);
      when(() => spotify.likeCurrentTrack()).thenAnswer((_) async => liked);
      when(() => ytmusic.likeCurrentTrack()).thenAnswer((_) async => liked);

      await repo.likeCurrentTrack();
      expect(decisions, isEmpty, reason: 'an explicit pick is not news');

      automatic();
      await repo.likeCurrentTrack();

      expect(decisions, <MusicRoutingDecision>[
        const MusicRoutingDecision(
          provider: MusicProvider.ytmusic,
          reason: MusicRoutingReason.playingSession,
        ),
      ]);
      expect(
        decisions.single.logLine,
        'Automatic routing -> YouTube Music (playing session)',
      );
    });

    test('connectedProviders survives a service that cannot answer', () async {
      when(() => spotify.getAuthState()).thenThrow(Exception('token store'));
      when(() => ytmusic.getAuthState()).thenAnswer(
        (_) async => const SpotifyAuthState(
          accessToken: 'token',
          refreshToken: null,
          expiresAt: null,
          connected: true,
        ),
      );

      expect(
        await repo.connectedProviders(),
        <MusicProvider>{MusicProvider.ytmusic},
      );
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
        platformServiceRepository: platform,
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
}
