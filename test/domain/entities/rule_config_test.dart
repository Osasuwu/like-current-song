import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/domain/entities/rule_config.dart';

void main() {
  group('RuleConfig.defaults (fresh install)', () {
    final config = RuleConfig.defaults();

    test('has every extra action off', () {
      expect(config.archiveRemoveEnabled, isFalse);
      expect(config.bestOfEnabled, isFalse);
      expect(config.followArtistEnabled, isFalse);
    });

    test('has empty playlist names', () {
      expect(config.archivePlaylistName, isEmpty);
      expect(config.bestOfPlaylistName, isEmpty);
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
    test('keeps every value of a v1.0.3 saved payload', () {
      // Exactly what v1.0.3 wrote to the `rule_config` pref.
      final saved = <String, dynamic>{
        'archiveRemoveEnabled': true,
        'archivePlaylistName': 'My Archive',
        'bestOfEnabled': false,
        'bestOfPlaylistName': 'Top Picks',
        'bestOfThreshold': 4,
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
        'bestOfEnabled': true,
        'bestOfPlaylistName': 'Botbotb(Best of the best of the best)',
        'bestOfThreshold': 3,
        'followArtistEnabled': true,
        'followArtistThreshold': 5,
      });

      expect(config.archiveRemoveEnabled, isTrue);
      expect(config.bestOfEnabled, isTrue);
      expect(config.followArtistEnabled, isTrue);
      expect(config.likeCooldownEnabled, isTrue);
      expect(config.likeCooldownMinutes, AppConstants.defaultLikeCooldownMinutes);
    });

    test('missing fields fall back to what older installs ran with, not the new defaults', () {
      final config = RuleConfig.fromJson(<String, dynamic>{});

      expect(config.toJson(), equals(RuleConfig.legacyDefaults().toJson()));
      expect(config.archiveRemoveEnabled, isTrue);
      expect(config.archivePlaylistName, AppConstants.legacyArchivePlaylistName);
      expect(config.bestOfEnabled, isTrue);
      expect(config.bestOfPlaylistName, AppConstants.legacyBestOfPlaylistName);
      expect(config.followArtistEnabled, isTrue);
    });

    test('an explicitly saved "off" stays off', () {
      final config = RuleConfig.fromJson(<String, dynamic>{
        'archiveRemoveEnabled': false,
        'bestOfEnabled': false,
        'followArtistEnabled': false,
      });

      expect(config.archiveRemoveEnabled, isFalse);
      expect(config.bestOfEnabled, isFalse);
      expect(config.followArtistEnabled, isFalse);
    });

    test('round-trips the fresh-install defaults', () {
      final defaults = RuleConfig.defaults();

      expect(RuleConfig.fromJson(defaults.toJson()).toJson(), equals(defaults.toJson()));
    });
  });

  group('RuleConfig.validate', () {
    test('requires a playlist name only for actions that are on', () {
      final config = RuleConfig.defaults().copyWith(
        archiveRemoveEnabled: true,
        bestOfEnabled: true,
      );

      expect(config.validate(), hasLength(2));
    });
  });
}
