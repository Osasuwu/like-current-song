import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';

void main() {
  test('ids match the desktop music.provider values', () {
    expect(MusicProvider.spotify.id, 'spotify');
    expect(MusicProvider.ytmusic.id, 'ytmusic');
  });

  test('default is Spotify', () {
    expect(MusicProvider.defaultProvider, MusicProvider.spotify);
  });

  test('fromId resolves known ids', () {
    for (final provider in MusicProvider.values) {
      expect(MusicProvider.fromId(provider.id), provider);
    }
  });

  test('fromId falls back to the default for null or unknown ids', () {
    expect(MusicProvider.fromId(null), MusicProvider.spotify);
    expect(MusicProvider.fromId(''), MusicProvider.spotify);
    expect(MusicProvider.fromId('YTMUSIC'), MusicProvider.spotify);
  });
}
