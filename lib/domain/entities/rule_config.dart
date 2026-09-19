import '../../core/app_constants.dart';

class RuleConfig {
  final bool archiveRemoveEnabled;
  final String archivePlaylistName;
  final bool bestOfEnabled;
  final String bestOfPlaylistName;
  final int bestOfThreshold;
  final bool followArtistEnabled;
  final int followArtistThreshold;
  final bool likeCooldownEnabled;
  final int likeCooldownMinutes;

  const RuleConfig({
    required this.archiveRemoveEnabled,
    required this.archivePlaylistName,
    required this.bestOfEnabled,
    required this.bestOfPlaylistName,
    required this.bestOfThreshold,
    required this.followArtistEnabled,
    required this.followArtistThreshold,
    this.likeCooldownEnabled = true,
    this.likeCooldownMinutes = AppConstants.defaultLikeCooldownMinutes,
  });

  /// Defaults for a fresh install.
  ///
  /// The extra actions (archive-remove, best-of promotion, artist auto-follow)
  /// are opt-in: off, with empty playlist names. Thresholds keep a sensible
  /// suggested value so switching an action on needs only a playlist name.
  factory RuleConfig.defaults() {
    return const RuleConfig(
      archiveRemoveEnabled: false,
      archivePlaylistName: '',
      bestOfEnabled: false,
      bestOfPlaylistName: '',
      bestOfThreshold: AppConstants.defaultBestOfThreshold,
      followArtistEnabled: false,
      followArtistThreshold: AppConstants.defaultFollowArtistThreshold,
      likeCooldownEnabled: true,
      likeCooldownMinutes: AppConstants.defaultLikeCooldownMinutes,
    );
  }

  /// The defaults every install ran with up to v1.0.3, when all extra actions
  /// were on out of the box.
  ///
  /// Used only to upgrade installs that predate opt-in extra actions, so they
  /// keep behaving exactly as before: a saved payload missing a field, a
  /// pre-`rule_config` legacy key migration, or an install that used the app
  /// but never saved rules at all.
  factory RuleConfig.legacyDefaults() {
    return const RuleConfig(
      archiveRemoveEnabled: true,
      archivePlaylistName: AppConstants.legacyArchivePlaylistName,
      bestOfEnabled: true,
      bestOfPlaylistName: AppConstants.legacyBestOfPlaylistName,
      bestOfThreshold: AppConstants.defaultBestOfThreshold,
      followArtistEnabled: true,
      followArtistThreshold: AppConstants.defaultFollowArtistThreshold,
      likeCooldownEnabled: true,
      likeCooldownMinutes: AppConstants.defaultLikeCooldownMinutes,
    );
  }

  RuleConfig copyWith({
    bool? archiveRemoveEnabled,
    String? archivePlaylistName,
    bool? bestOfEnabled,
    String? bestOfPlaylistName,
    int? bestOfThreshold,
    bool? followArtistEnabled,
    int? followArtistThreshold,
    bool? likeCooldownEnabled,
    int? likeCooldownMinutes,
  }) {
    return RuleConfig(
      archiveRemoveEnabled: archiveRemoveEnabled ?? this.archiveRemoveEnabled,
      archivePlaylistName: archivePlaylistName ?? this.archivePlaylistName,
      bestOfEnabled: bestOfEnabled ?? this.bestOfEnabled,
      bestOfPlaylistName: bestOfPlaylistName ?? this.bestOfPlaylistName,
      bestOfThreshold: bestOfThreshold ?? this.bestOfThreshold,
      followArtistEnabled: followArtistEnabled ?? this.followArtistEnabled,
      followArtistThreshold: followArtistThreshold ?? this.followArtistThreshold,
      likeCooldownEnabled: likeCooldownEnabled ?? this.likeCooldownEnabled,
      likeCooldownMinutes: likeCooldownMinutes ?? this.likeCooldownMinutes,
    );
  }

  /// Returns human-readable validation errors, empty when the config is valid.
  List<String> validate() {
    final errors = <String>[];
    if (archiveRemoveEnabled && archivePlaylistName.trim().isEmpty) {
      errors.add('Archive playlist name is required when archive removal is enabled.');
    }
    if (bestOfEnabled && bestOfPlaylistName.trim().isEmpty) {
      errors.add('Best-of playlist name is required when best-of promotion is enabled.');
    }
    if (bestOfEnabled && bestOfThreshold < 1) {
      errors.add('Best-of threshold must be at least 1.');
    }
    if (followArtistEnabled && followArtistThreshold < 1) {
      errors.add('Follow-artist threshold must be at least 1.');
    }
    if (likeCooldownEnabled && likeCooldownMinutes < 1) {
      errors.add('Like cooldown minutes must be at least 1.');
    }
    return errors;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'archiveRemoveEnabled': archiveRemoveEnabled,
      'archivePlaylistName': archivePlaylistName,
      'bestOfEnabled': bestOfEnabled,
      'bestOfPlaylistName': bestOfPlaylistName,
      'bestOfThreshold': bestOfThreshold,
      'followArtistEnabled': followArtistEnabled,
      'followArtistThreshold': followArtistThreshold,
      'likeCooldownEnabled': likeCooldownEnabled,
      'likeCooldownMinutes': likeCooldownMinutes,
    };
  }

  /// Parses a persisted config.
  ///
  /// A persisted payload always comes from an install that already existed,
  /// so a missing field falls back to [RuleConfig.legacyDefaults] — the value
  /// that install was actually running with — never to the fresh-install
  /// [RuleConfig.defaults].
  factory RuleConfig.fromJson(Map<String, dynamic> json) {
    final defaults = RuleConfig.legacyDefaults();
    return RuleConfig(
      archiveRemoveEnabled: json['archiveRemoveEnabled'] as bool? ?? defaults.archiveRemoveEnabled,
      archivePlaylistName: json['archivePlaylistName'] as String? ?? defaults.archivePlaylistName,
      bestOfEnabled: json['bestOfEnabled'] as bool? ?? defaults.bestOfEnabled,
      bestOfPlaylistName: json['bestOfPlaylistName'] as String? ?? defaults.bestOfPlaylistName,
      bestOfThreshold: json['bestOfThreshold'] as int? ?? defaults.bestOfThreshold,
      followArtistEnabled: json['followArtistEnabled'] as bool? ?? defaults.followArtistEnabled,
      followArtistThreshold: json['followArtistThreshold'] as int? ?? defaults.followArtistThreshold,
      likeCooldownEnabled: json['likeCooldownEnabled'] as bool? ?? defaults.likeCooldownEnabled,
      likeCooldownMinutes: json['likeCooldownMinutes'] as int? ?? defaults.likeCooldownMinutes,
    );
  }
}
