import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/settings/shared_prefs_settings_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('music provider setting', () {
    test('defaults to Spotify on a fresh install', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final repo = SharedPrefsSettingsRepository();

      expect(await repo.loadMusicProvider(), MusicProvider.spotify);
    });

    test('persists the selection across repository instances', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SharedPrefsSettingsRepository()
          .saveMusicProvider(MusicProvider.ytmusic);

      expect(
        await SharedPrefsSettingsRepository().loadMusicProvider(),
        MusicProvider.ytmusic,
      );
    });

    test('stores the desktop-compatible id', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SharedPrefsSettingsRepository()
          .saveMusicProvider(MusicProvider.ytmusic);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('music_provider'), 'ytmusic');
    });

    test('falls back to Spotify for an unknown stored value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'music_provider': 'tidal',
      });

      expect(
        await SharedPrefsSettingsRepository().loadMusicProvider(),
        MusicProvider.spotify,
      );
    });
  });
}
