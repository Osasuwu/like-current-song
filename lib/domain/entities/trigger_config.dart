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
