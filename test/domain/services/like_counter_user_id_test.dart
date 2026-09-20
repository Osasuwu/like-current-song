import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/services/like_counter_user_id.dart';

void main() {
  group('likeCounterUserId', () {
    test('Spotify likes are keyed by the Spotify user id', () {
      expect(
        likeCounterUserId(
          MusicProvider.spotify,
          spotifyUserId: 'spotify-user',
          youTubeMusicSub: 'google-sub',
        ),
        'spotify-user',
      );
    });

    test('YouTube Music likes are keyed by the Google sub', () {
      expect(
        likeCounterUserId(
          MusicProvider.ytmusic,
          spotifyUserId: 'spotify-user',
          youTubeMusicSub: 'google-sub',
        ),
        'google-sub',
      );
    });

    test('never falls back to the other service\'s id', () {
      expect(
        likeCounterUserId(
          MusicProvider.ytmusic,
          spotifyUserId: 'spotify-user',
        ),
        isNull,
      );
      expect(
        likeCounterUserId(
          MusicProvider.spotify,
          youTubeMusicSub: 'google-sub',
        ),
        isNull,
      );
    });

    test('a blank id means not signed in', () {
      expect(likeCounterUserId(MusicProvider.spotify, spotifyUserId: ''),
          isNull);
      expect(
        likeCounterUserId(MusicProvider.ytmusic, youTubeMusicSub: '   '),
        isNull,
      );
    });

    test('surrounding whitespace is trimmed off', () {
      expect(
        likeCounterUserId(MusicProvider.ytmusic, youTubeMusicSub: ' sub \n'),
        'sub',
      );
    });
  });
}
