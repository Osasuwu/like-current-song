import '../../core/app_constants.dart';

class TriggerConfig {
  final String pattern;
  final int windowMs;
  final int debounceMs;
  final int feedbackVolume;

  /// The earbuds' triple tap (`PREVIOUS`) likes too (#158). Opt-in: it takes
  /// a key away from the player, and it needs a one-time adb grant.
  final bool tripleTapEnabled;

  const TriggerConfig({
    required this.pattern,
    required this.windowMs,
    required this.debounceMs,
    this.feedbackVolume = 100,
    this.tripleTapEnabled = false,
  });

  List<String> get events =>
      pattern.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  /// Returns human-readable validation errors, empty when the config is valid.
  ///
  /// A pattern with no events is rejected: it is not "match nothing" to a
  /// user, it is a trigger they forgot to type, and both matchers answer it
  /// with silence. So is a window past [AppConstants.maxWindowMs] (#248): the
  /// matchers would hold it to the cap anyway, and saying so beats a setting
  /// that silently does less than it shows.
  List<String> validate() {
    final errors = <String>[];
    if (events.isEmpty) {
      errors.add(
        'Trigger pattern needs at least one event, for example pause,play.',
      );
    }
    if (windowMs > AppConstants.maxWindowMs) {
      errors.add(
        'Trigger window can be at most ${AppConstants.maxWindowMs} ms.',
      );
    }
    return errors;
  }

  TriggerConfig copyWith({
    String? pattern,
    int? windowMs,
    int? debounceMs,
    int? feedbackVolume,
    bool? tripleTapEnabled,
  }) {
    return TriggerConfig(
      pattern: pattern ?? this.pattern,
      windowMs: windowMs ?? this.windowMs,
      debounceMs: debounceMs ?? this.debounceMs,
      feedbackVolume: feedbackVolume ?? this.feedbackVolume,
      tripleTapEnabled: tripleTapEnabled ?? this.tripleTapEnabled,
    );
  }
}
