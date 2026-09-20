class TriggerConfig {
  final String pattern;
  final int windowMs;
  final int debounceMs;
  final int feedbackVolume;

  const TriggerConfig({
    required this.pattern,
    required this.windowMs,
    required this.debounceMs,
    this.feedbackVolume = 100,
  });

  List<String> get events =>
      pattern.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  /// Returns human-readable validation errors, empty when the config is valid.
  ///
  /// A pattern with no events is the one thing this rejects: it is not "match
  /// nothing" to a user, it is a trigger they forgot to type, and both
  /// matchers answer it with silence.
  List<String> validate() {
    if (events.isEmpty) {
      return <String>[
        'Trigger pattern needs at least one event, for example pause,play.',
      ];
    }
    return <String>[];
  }

  TriggerConfig copyWith({
    String? pattern,
    int? windowMs,
    int? debounceMs,
    int? feedbackVolume,
  }) {
    return TriggerConfig(
      pattern: pattern ?? this.pattern,
      windowMs: windowMs ?? this.windowMs,
      debounceMs: debounceMs ?? this.debounceMs,
      feedbackVolume: feedbackVolume ?? this.feedbackVolume,
    );
  }
}
