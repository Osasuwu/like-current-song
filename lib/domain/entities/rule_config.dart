import '../../core/app_constants.dart';

class RuleConfig {
  final bool archiveRemoveEnabled;
  final String archivePlaylistName;
  final bool bestEnabled;
  final String bestPlaylistName;
  final int bestThreshold;
  final bool followArtistEnabled;
  final int followArtistThreshold;
  final bool likeCooldownEnabled;
  final int likeCooldownMinutes;

  const RuleConfig({
    required this.archiveRemoveEnabled,
    required this.archivePlaylistName,
    required this.bestEnabled,
    required this.bestPlaylistName,
    required this.bestThreshold,
    required this.followArtistEnabled,
    required this.followArtistThreshold,
    this.likeCooldownEnabled = true,
    this.likeCooldownMinutes = AppConstants.defaultLikeCooldownMinutes,
  });

  /// Defaults for a fresh install.
  ///
  /// The extra actions (archive-remove, best promotion, artist auto-follow)
  /// are opt-in: off, with empty playlist names. Thresholds keep a sensible
  /// suggested value so switching an action on needs only a playlist name.
  factory RuleConfig.defaults() {
    return const RuleConfig(
      archiveRemoveEnabled: false,
      archivePlaylistName: '',
      bestEnabled: false,
      bestPlaylistName: '',
      bestThreshold: AppConstants.defaultBestThreshold,
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
      bestEnabled: true,
      bestPlaylistName: AppConstants.legacyBestPlaylistName,
      bestThreshold: AppConstants.defaultBestThreshold,
      followArtistEnabled: true,
      followArtistThreshold: AppConstants.defaultFollowArtistThreshold,
      likeCooldownEnabled: true,
      likeCooldownMinutes: AppConstants.defaultLikeCooldownMinutes,
    );
  }

  RuleConfig copyWith({
    bool? archiveRemoveEnabled,
    String? archivePlaylistName,
    bool? bestEnabled,
    String? bestPlaylistName,
    int? bestThreshold,
    bool? followArtistEnabled,
    int? followArtistThreshold,
    bool? likeCooldownEnabled,
    int? likeCooldownMinutes,
  }) {
    return RuleConfig(
      archiveRemoveEnabled: archiveRemoveEnabled ?? this.archiveRemoveEnabled,
      archivePlaylistName: archivePlaylistName ?? this.archivePlaylistName,
      bestEnabled: bestEnabled ?? this.bestEnabled,
      bestPlaylistName: bestPlaylistName ?? this.bestPlaylistName,
      bestThreshold: bestThreshold ?? this.bestThreshold,
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
    if (bestEnabled && bestPlaylistName.trim().isEmpty) {
      errors.add('Best playlist name is required when best promotion is enabled.');
    }
    if (bestEnabled && bestThreshold < 1) {
      errors.add('Best threshold must be at least 1.');
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
      'bestEnabled': bestEnabled,
      'bestPlaylistName': bestPlaylistName,
      'bestThreshold': bestThreshold,
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
  ///
  /// Up to v1.1.0 the best-playlist fields were written as `bestOfEnabled`,
  /// `bestOfPlaylistName` and `bestOfThreshold`. Those spellings are still read
  /// when the current ones are absent, so upgrading keeps the saved rule; only
  /// the new spellings are ever written back.
  factory RuleConfig.fromJson(Map<String, dynamic> json) {
    final defaults = RuleConfig.legacyDefaults();
    return RuleConfig(
      archiveRemoveEnabled: json['archiveRemoveEnabled'] as bool? ?? defaults.archiveRemoveEnabled,
      archivePlaylistName: json['archivePlaylistName'] as String? ?? defaults.archivePlaylistName,
      bestEnabled:
          json['bestEnabled'] as bool? ?? json['bestOfEnabled'] as bool? ?? defaults.bestEnabled,
      bestPlaylistName: json['bestPlaylistName'] as String? ??
          json['bestOfPlaylistName'] as String? ??
          defaults.bestPlaylistName,
      bestThreshold: json['bestThreshold'] as int? ??
          json['bestOfThreshold'] as int? ??
          defaults.bestThreshold,
      followArtistEnabled: json['followArtistEnabled'] as bool? ?? defaults.followArtistEnabled,
      followArtistThreshold: json['followArtistThreshold'] as int? ?? defaults.followArtistThreshold,
      likeCooldownEnabled: json['likeCooldownEnabled'] as bool? ?? defaults.likeCooldownEnabled,
      likeCooldownMinutes: json['likeCooldownMinutes'] as int? ?? defaults.likeCooldownMinutes,
    );
  }
}
