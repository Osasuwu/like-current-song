import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/settings/shared_prefs_settings_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_routing.dart';
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

  group('music routing mode', () {
    test('defaults to the picker on a fresh install', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      expect(
        await SharedPrefsSettingsRepository().loadMusicRoutingMode(),
        MusicRoutingMode.picker,
      );
    });

    test('an install upgraded from a build without automatic keeps its pick',
        () async {
      // Exactly what an existing install carries: a picked service and no
      // routing key at all, because the key did not exist when it was written.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'music_provider': 'ytmusic',
      });
      final repo = SharedPrefsSettingsRepository();

      expect(
        await repo.loadMusicRoutingMode(),
        MusicRoutingMode.picker,
        reason: 'automatic is opt-in; an upgrade must never turn it on',
      );
      expect(await repo.loadMusicProvider(), MusicProvider.ytmusic);
    });

    test('persists the opt-in across repository instances', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SharedPrefsSettingsRepository()
          .saveMusicRoutingMode(MusicRoutingMode.automatic);

      expect(
        await SharedPrefsSettingsRepository().loadMusicRoutingMode(),
        MusicRoutingMode.automatic,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('music_routing_mode'), 'automatic');
      expect(
        prefs.getString('music_provider'),
        isNull,
        reason: 'the picked service is a separate key, left untouched',
      );
    });

    test('falls back to the picker for an unknown stored value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'music_routing_mode': 'whatever-comes-next',
      });

      expect(
        await SharedPrefsSettingsRepository().loadMusicRoutingMode(),
        MusicRoutingMode.picker,
      );
    });
  });
}
