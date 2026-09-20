import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/domain/entities/rule_config.dart';

void main() {
  group('RuleConfig.defaults (fresh install)', () {
    final config = RuleConfig.defaults();

    test('has every extra action off', () {
      expect(config.archiveRemoveEnabled, isFalse);
      expect(config.bestEnabled, isFalse);
      expect(config.followArtistEnabled, isFalse);
    });

    test('has empty playlist names', () {
      expect(config.archivePlaylistName, isEmpty);
      expect(config.bestPlaylistName, isEmpty);
    });

    test('keeps the like cooldown on', () {
      expect(config.likeCooldownEnabled, isTrue);
      expect(config.likeCooldownMinutes, AppConstants.defaultLikeCooldownMinutes);
    });

    test('is valid as-is', () {
      expect(config.validate(), isEmpty);
    });
  });

  group('RuleConfig.fromJson (upgrade from an older install)', () {
    test('keeps every value of a saved payload', () {
      // Exactly what the app writes to the `rule_config` pref.
      final saved = <String, dynamic>{
        'archiveRemoveEnabled': true,
        'archivePlaylistName': 'My Archive',
        'bestEnabled': false,
        'bestPlaylistName': 'Top Picks',
        'bestThreshold': 4,
        'followArtistEnabled': true,
        'followArtistThreshold': 7,
        'likeCooldownEnabled': false,
        'likeCooldownMinutes': 20,
      };

      final config = RuleConfig.fromJson(saved);

      expect(config.toJson(), equals(saved));
    });

    test('a payload saved before the like cooldown existed keeps its actions on', () {
      // Pre-#54 payload: no cooldown fields.
      final config = RuleConfig.fromJson(<String, dynamic>{
        'archiveRemoveEnabled': true,
        'archivePlaylistName': 'Discover Weekly Archive',
        'bestEnabled': true,
        'bestPlaylistName': 'Botbotb(Best of the best of the best)',
        'bestThreshold': 3,
        'followArtistEnabled': true,
        'followArtistThreshold': 5,
      });

      expect(config.archiveRemoveEnabled, isTrue);
      expect(config.bestEnabled, isTrue);
      expect(config.followArtistEnabled, isTrue);
      expect(config.likeCooldownEnabled, isTrue);
      expect(config.likeCooldownMinutes, AppConstants.defaultLikeCooldownMinutes);
    });

    test('missing fields fall back to what older installs ran with, not the new defaults', () {
      final config = RuleConfig.fromJson(<String, dynamic>{});

      expect(config.toJson(), equals(RuleConfig.legacyDefaults().toJson()));
      expect(config.archiveRemoveEnabled, isTrue);
      expect(config.archivePlaylistName, AppConstants.legacyArchivePlaylistName);
      expect(config.bestEnabled, isTrue);
      expect(config.bestPlaylistName, AppConstants.legacyBestPlaylistName);
      expect(config.followArtistEnabled, isTrue);
    });

    test('an explicitly saved "off" stays off', () {
      final config = RuleConfig.fromJson(<String, dynamic>{
        'archiveRemoveEnabled': false,
        'bestEnabled': false,
        'followArtistEnabled': false,
      });

      expect(config.archiveRemoveEnabled, isFalse);
      expect(config.bestEnabled, isFalse);
      expect(config.followArtistEnabled, isFalse);
    });

    test('round-trips the fresh-install defaults', () {
      final defaults = RuleConfig.defaults();

      expect(RuleConfig.fromJson(defaults.toJson()).toJson(), equals(defaults.toJson()));
    });
  });

  group('RuleConfig.fromJson (the best-of -> best rename, v1.1.1)', () {
    // Up to v1.1.0 the three best-playlist fields were persisted as
    // `bestOf*` inside the `rule_config` pref. Upgrading must not lose them.
    test('reads a v1.1.0 payload written with the bestOf* spellings', () {
      final config = RuleConfig.fromJson(<String, dynamic>{
        'archiveRemoveEnabled': true,
        'archivePlaylistName': 'My Archive',
        'bestOfEnabled': true,
        'bestOfPlaylistName': 'Top Picks',
        'bestOfThreshold': 4,
        'followArtistEnabled': false,
        'followArtistThreshold': 7,
        'likeCooldownEnabled': false,
        'likeCooldownMinutes': 20,
      });

      expect(config.bestEnabled, isTrue);
      expect(config.bestPlaylistName, 'Top Picks');
      expect(config.bestThreshold, 4);
      // Everything else is untouched by the rename.
      expect(config.archivePlaylistName, 'My Archive');
      expect(config.followArtistEnabled, isFalse);
      expect(config.likeCooldownMinutes, 20);
    });

    test('an old payload that saved the rule as off stays off', () {
      final config = RuleConfig.fromJson(<String, dynamic>{
        'bestOfEnabled': false,
        'bestOfPlaylistName': '',
        'bestOfThreshold': 3,
      });

      expect(config.bestEnabled, isFalse);
      expect(config.bestPlaylistName, isEmpty);
    });

    test('only the new spellings are written back', () {
      final config = RuleConfig.fromJson(<String, dynamic>{
        'bestOfEnabled': true,
        'bestOfPlaylistName': 'Top Picks',
        'bestOfThreshold': 4,
      });

      final json = config.toJson();
      expect(json.keys, isNot(contains('bestOfEnabled')));
      expect(json.keys, isNot(contains('bestOfPlaylistName')));
      expect(json.keys, isNot(contains('bestOfThreshold')));
      expect(json['bestEnabled'], isTrue);
      expect(json['bestPlaylistName'], 'Top Picks');
      expect(json['bestThreshold'], 4);
    });

    test('a new-spelling value wins over a stale old one', () {
      final config = RuleConfig.fromJson(<String, dynamic>{
        'bestEnabled': false,
        'bestPlaylistName': 'New',
        'bestThreshold': 2,
        'bestOfEnabled': true,
        'bestOfPlaylistName': 'Old',
        'bestOfThreshold': 9,
      });

      expect(config.bestEnabled, isFalse);
      expect(config.bestPlaylistName, 'New');
      expect(config.bestThreshold, 2);
    });
  });

  group('RuleConfig.validate', () {
    test('requires a playlist name only for actions that are on', () {
      final config = RuleConfig.defaults().copyWith(
        archiveRemoveEnabled: true,
        bestEnabled: true,
      );

      expect(config.validate(), hasLength(2));
    });
  });
}
