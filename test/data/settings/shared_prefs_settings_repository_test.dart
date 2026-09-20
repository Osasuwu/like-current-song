import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/data/settings/shared_prefs_settings_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/rule_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPrefsSettingsRepository repo;

  setUp(() {
    repo = SharedPrefsSettingsRepository();
  });

  Future<Map<String, dynamic>?> savedRuleConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('rule_config');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  group('loadRuleConfig', () {
    test('fresh install: extra actions off with empty names, and pinned', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final config = await repo.loadRuleConfig();

      expect(config.toJson(), equals(RuleConfig.defaults().toJson()));
      expect(config.archiveRemoveEnabled, isFalse);
      expect(config.bestEnabled, isFalse);
      expect(config.followArtistEnabled, isFalse);
      expect(config.archivePlaylistName, isEmpty);
      expect(config.bestPlaylistName, isEmpty);
      // Persisted so later launches (which will have logs etc.) cannot flip it.
      expect(await savedRuleConfig(), equals(RuleConfig.defaults().toJson()));
    });

    test('fresh install stays off on the next launch once the app has been used', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await repo.loadRuleConfig();
      await repo.saveServiceEnabled(true);

      final config = await repo.loadRuleConfig();

      expect(config.archiveRemoveEnabled, isFalse);
      expect(config.bestEnabled, isFalse);
      expect(config.followArtistEnabled, isFalse);
    });

    test('upgrade: a v1.0.3 saved payload is kept exactly', () async {
      final saved = <String, dynamic>{
        'archiveRemoveEnabled': true,
        'archivePlaylistName': 'My Archive',
        'bestEnabled': true,
        'bestPlaylistName': 'Top Picks',
        'bestThreshold': 4,
        'followArtistEnabled': false,
        'followArtistThreshold': 7,
        'likeCooldownEnabled': true,
        'likeCooldownMinutes': 15,
      };
      SharedPreferences.setMockInitialValues(<String, Object>{
        'rule_config': jsonEncode(saved),
        'service_enabled': true,
      });

      final config = await repo.loadRuleConfig();

      expect(config.toJson(), equals(saved));
    });

    test('upgrade: pre-rule_config legacy keys migrate with the old actions on', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'archive_playlist_name': 'Old Archive',
      });

      final config = await repo.loadRuleConfig();

      expect(config.archiveRemoveEnabled, isTrue);
      expect(config.archivePlaylistName, 'Old Archive');
      expect(config.bestEnabled, isTrue);
      expect(config.bestPlaylistName, AppConstants.legacyBestPlaylistName);
      expect(config.followArtistEnabled, isTrue);
      expect(await savedRuleConfig(), equals(config.toJson()));
    });

    for (final marker in <String, Object>{
      'service_enabled': false,
      'logs': <String>['a log line'],
      'trigger_pattern': 'pause,play',
      'pending_likes': '[]',
    }.entries) {
      test('upgrade: used install without saved rules keeps the old all-on '
          'behaviour (marker: ${marker.key})', () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          marker.key: marker.value,
        });

        final config = await repo.loadRuleConfig();

        expect(config.toJson(), equals(RuleConfig.legacyDefaults().toJson()));
        expect(await savedRuleConfig(), equals(RuleConfig.legacyDefaults().toJson()));
      });
    }
  });
}
