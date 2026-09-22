import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_client.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_models.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_playlist_service.dart';

class MockSpotifyClient extends Mock implements SpotifyClient {}

void main() {
  late MockSpotifyClient mockClient;
  late SpotifyPlaylistService service;
  const token = 'test-token';

  setUpAll(() {
    // `any(named: 'trackUris')` needs a fallback for the non-primitive type.
    registerFallbackValue(<String>[]);
  });

  setUp(() {
    mockClient = MockSpotifyClient();
    service = SpotifyPlaylistService(mockClient);
  });

  group('findPlaylistByName', () {
    test('returns playlist ID when found on first page', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(
          items: [
            SpotifyPlaylistItem(id: 'pl-1', name: 'My Playlist'),
            SpotifyPlaylistItem(id: 'pl-2', name: 'Best of the Best'),
          ],
          total: 2,
        ),
      );

      final id = await service.findPlaylistByName(token, 'Best of the Best');
      expect(id, 'pl-2');
    });

    test('returns null when playlist not found', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(items: [], total: 0),
      );

      final id = await service.findPlaylistByName(token, 'Nonexistent');
      expect(id, isNull);
    });

    test('paginates through all pages', () async {
      final page1 = SpotifyPlaylistPage(
        items: List<SpotifyPlaylistItem>.generate(
          50,
          (i) => SpotifyPlaylistItem(id: 'pl-$i', name: 'Playlist $i'),
        ),
        total: 51,
      );
      const page2 = SpotifyPlaylistPage(
        items: [SpotifyPlaylistItem(id: 'target', name: 'Target Playlist')],
        total: 51,
      );

      when(() => mockClient.getUserPlaylists(token, offset: 0))
          .thenAnswer((_) async => page1);
      when(() => mockClient.getUserPlaylists(token, offset: 50))
          .thenAnswer((_) async => page2);

      final id = await service.findPlaylistByName(token, 'Target Playlist');
      expect(id, 'target');
    });

    test('is case-insensitive', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(
          items: [SpotifyPlaylistItem(id: 'pl-1', name: 'MY PLAYLIST')],
          total: 1,
        ),
      );

      final id = await service.findPlaylistByName(token, 'my playlist');
      expect(id, 'pl-1');
    });

    test('caches results and avoids duplicate API calls', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(
          items: [SpotifyPlaylistItem(id: 'cached-id', name: 'Cached')],
          total: 1,
        ),
      );

      // First call — hits API
      await service.findPlaylistByName(token, 'Cached');
      // Second call — should use cache
      final id = await service.findPlaylistByName(token, 'Cached');

      expect(id, 'cached-id');
      verify(() => mockClient.getUserPlaylists(token, offset: 0)).called(1);
    });
  });

  group('ensurePlaylist', () {
    test('returns existing playlist without creating', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(
          items: [SpotifyPlaylistItem(id: 'exists', name: 'Existing')],
          total: 1,
        ),
      );

      final id = await service.ensurePlaylist(token, 'Existing');
      expect(id, 'exists');
      verifyNever(() => mockClient.createPlaylist(
            token,
            userId: any(named: 'userId'),
            name: any(named: 'name'),
          ));
    });

    test('creates playlist when not found and createIfMissing=true', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(items: [], total: 0),
      );
      when(() => mockClient.getCurrentUserId(token))
          .thenAnswer((_) async => 'user-123');
      when(() => mockClient.createPlaylist(
            token,
            userId: 'user-123',
            name: 'New Playlist',
          )).thenAnswer((_) async => 'new-pl-id');

      final id = await service.ensurePlaylist(token, 'New Playlist');
      expect(id, 'new-pl-id');
    });

    test('returns null when not found and createIfMissing=false', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(items: [], total: 0),
      );

      final id = await service.ensurePlaylist(
        token,
        'Nonexistent',
        createIfMissing: false,
      );
      expect(id, isNull);
    });
  });

  group('cache invalidation', () {
    test('invalidateCache forces re-fetch on next call', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(
          items: [SpotifyPlaylistItem(id: 'pl-1', name: 'Test')],
          total: 1,
        ),
      );

      await service.findPlaylistByName(token, 'Test');
      service.invalidateCache();
      await service.findPlaylistByName(token, 'Test');

      verify(() => mockClient.getUserPlaylists(token, offset: 0)).called(2);
    });
  });

  group('addTrackToNamedPlaylist', () {
    const trackUri = 'spotify:track:4cOdK2wGLETKBW3PvgPWqT';

    setUp(() {
      when(() => mockClient.getCurrentUserId(token))
          .thenAnswer((_) async => 'me');
    });

    test('adds to the resolved playlist without creating anything', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(
          items: [SpotifyPlaylistItem(id: 'pl-1', name: 'Liked')],
          total: 1,
        ),
      );
      when(() => mockClient.addTracksToPlaylist(token,
          playlistId: 'pl-1', trackUris: [trackUri])).thenAnswer((_) async {});

      await service.addTrackToNamedPlaylist(token, 'Liked', trackUri);

      verify(() => mockClient.addTracksToPlaylist(token,
          playlistId: 'pl-1', trackUris: [trackUri])).called(1);
      verifyNever(() => mockClient.createPlaylist(token,
          userId: any(named: 'userId'), name: any(named: 'name')));
    });

    test('drops a stale cached id on 404, then recreates and retries once',
        () async {
      var listings = 0;
      when(() => mockClient.getUserPlaylists(token, offset: 0))
          .thenAnswer((_) async {
        listings++;
        // The first enumeration still sees the playlist, so its id lands in
        // the cache; by the second it has been deleted. That is exactly the
        // state that used to strand every like behind a 404.
        return listings == 1
            ? const SpotifyPlaylistPage(
                items: [SpotifyPlaylistItem(id: 'pl-dead', name: 'Liked')],
                total: 1,
              )
            : const SpotifyPlaylistPage(items: [], total: 0);
      });
      when(() => mockClient.addTracksToPlaylist(token,
              playlistId: 'pl-dead', trackUris: [trackUri]))
          .thenThrow(SpotifyApiException(404, 'Not found'));
      when(() => mockClient.createPlaylist(token, userId: 'me', name: 'Liked'))
          .thenAnswer((_) async => 'pl-new');
      when(() => mockClient.addTracksToPlaylist(token,
          playlistId: 'pl-new', trackUris: [trackUri])).thenAnswer((_) async {});

      await service.addTrackToNamedPlaylist(token, 'Liked', trackUri);

      verify(() => mockClient.addTracksToPlaylist(token,
          playlistId: 'pl-dead', trackUris: [trackUri])).called(1);
      verify(() => mockClient.addTracksToPlaylist(token,
          playlistId: 'pl-new', trackUris: [trackUri])).called(1);
      // The dead id is gone: the cache now names the playlist that exists.
      expect(await service.findPlaylistByName(token, 'Liked'), 'pl-new');
    });

    test('gives up after one retry instead of looping', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(
          items: [SpotifyPlaylistItem(id: 'pl-1', name: 'Liked')],
          total: 1,
        ),
      );
      when(() => mockClient.addTracksToPlaylist(token,
              playlistId: 'pl-1', trackUris: [trackUri]))
          .thenThrow(SpotifyApiException(404, 'Not found'));

      await expectLater(
        service.addTrackToNamedPlaylist(token, 'Liked', trackUri),
        throwsA(isA<SpotifyApiException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
      verify(() => mockClient.addTracksToPlaylist(token,
          playlistId: 'pl-1', trackUris: [trackUri])).called(2);
    });

    test('rethrows anything that is not a 404', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(
          items: [SpotifyPlaylistItem(id: 'pl-1', name: 'Liked')],
          total: 1,
        ),
      );
      when(() => mockClient.addTracksToPlaylist(token,
              playlistId: 'pl-1', trackUris: [trackUri]))
          .thenThrow(SpotifyApiException(403, 'Forbidden'));

      await expectLater(
        service.addTrackToNamedPlaylist(token, 'Liked', trackUri),
        throwsA(isA<SpotifyApiException>()
            .having((e) => e.statusCode, 'statusCode', 403)),
      );
      // No second attempt: only a 404 means the id went bad.
      verify(() => mockClient.addTracksToPlaylist(token,
          playlistId: 'pl-1', trackUris: [trackUri])).called(1);
    });

    test('throws when the playlist can neither be found nor created', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(items: [], total: 0),
      );
      when(() => mockClient.createPlaylist(token, userId: 'me', name: 'Liked'))
          .thenThrow(SpotifyApiException(403, 'Forbidden'));

      await expectLater(
        service.addTrackToNamedPlaylist(token, 'Liked', trackUri),
        throwsA(isA<Exception>()),
      );
      verifyNever(() => mockClient.addTracksToPlaylist(token,
          playlistId: any(named: 'playlistId'),
          trackUris: any(named: 'trackUris')));
    });
  });

  group('removeTrack', () {
    const trackUri = 'spotify:track:4cOdK2wGLETKBW3PvgPWqT';

    test('drops the cached id when the playlist is already gone', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(
          items: [SpotifyPlaylistItem(id: 'pl-1', name: 'Archive')],
          total: 1,
        ),
      );
      when(() => mockClient.removeTracksFromPlaylist(token,
              playlistId: 'pl-1', trackUris: [trackUri]))
          .thenThrow(SpotifyApiException(404, 'Not found'));

      expect(await service.findPlaylistByName(token, 'Archive'), 'pl-1');
      expect(await service.removeTrack(token, 'pl-1', trackUri), isFalse);

      // With the entry dropped the next lookup asks Spotify again instead of
      // handing back an id the API has already rejected.
      await service.findPlaylistByName(token, 'Archive');
      verify(() => mockClient.getUserPlaylists(token, offset: 0)).called(2);
    });

    test('keeps the cache on a failure that is not a 404', () async {
      when(() => mockClient.getUserPlaylists(token, offset: 0)).thenAnswer(
        (_) async => const SpotifyPlaylistPage(
          items: [SpotifyPlaylistItem(id: 'pl-1', name: 'Archive')],
          total: 1,
        ),
      );
      when(() => mockClient.removeTracksFromPlaylist(token,
              playlistId: 'pl-1', trackUris: [trackUri]))
          .thenThrow(SpotifyApiException(500, 'Server error'));

      expect(await service.findPlaylistByName(token, 'Archive'), 'pl-1');
      expect(await service.removeTrack(token, 'pl-1', trackUri), isFalse);

      await service.findPlaylistByName(token, 'Archive');
      verify(() => mockClient.getUserPlaylists(token, offset: 0)).called(1);
    });
  });
}
