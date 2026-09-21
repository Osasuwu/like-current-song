import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/trigger_config.dart';
import 'package:like_spotify_mobile_app/domain/services/signal_pattern_matcher.dart';

void main() {
  group('SignalPatternMatcher', () {
    group('basic pattern matching', () {
      test('matches two-event pattern: pause then play', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        final firstResult = matcher.onEvent(event: 'pause', config: config);
        final secondResult = matcher.onEvent(event: 'play', config: config);

        expect(firstResult, equals(false));
        expect(secondResult, equals(true));
      });

      test('does not match wrong order: play then pause', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        matcher.onEvent(event: 'play', config: config);
        final result = matcher.onEvent(event: 'pause', config: config);

        expect(result, equals(false));
      });

      test('returns false for partial match without complete pattern', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        final result = matcher.onEvent(event: 'pause', config: config);

        expect(result, equals(false));
      });
    });

    group('event validation', () {
      test('rejects invalid event "skip"', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'skip,next',
          windowMs: 5000,
          debounceMs: 500,
        );

        final result = matcher.onEvent(event: 'skip', config: config);

        expect(result, equals(false));
      });

      test('rejects invalid event "next"', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'next',
          windowMs: 5000,
          debounceMs: 500,
        );

        final result = matcher.onEvent(event: 'next', config: config);

        expect(result, equals(false));
      });

      test('only accepts play and pause events', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'play',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(matcher.onEvent(event: 'play', config: config), equals(true));

        final matcher2 = SignalPatternMatcher();
        expect(matcher2.onEvent(event: 'pause', config: config), equals(false));

        expect(
          matcher2.onEvent(event: 'invalid', config: config),
          equals(false),
        );
      });
    });

    group('single event pattern', () {
      test('matches single event pattern "pause"', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause',
          windowMs: 5000,
          debounceMs: 500,
        );

        final result = matcher.onEvent(event: 'pause', config: config);

        expect(result, equals(true));
      });

      test('matches single event pattern "play"', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'play',
          windowMs: 5000,
          debounceMs: 500,
        );

        final result = matcher.onEvent(event: 'play', config: config);

        expect(result, equals(true));
      });

      test('does not match single event pattern with wrong event', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause',
          windowMs: 5000,
          debounceMs: 500,
        );

        final result = matcher.onEvent(event: 'play', config: config);

        expect(result, equals(false));
      });
    });

    group('debounce behavior', () {
      test('prevents rapid successive matches within debounceMs', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause',
          windowMs: 5000,
          debounceMs: 100,
        );

        final firstMatch = matcher.onEvent(event: 'pause', config: config);
        final secondMatch = matcher.onEvent(event: 'pause', config: config);

        expect(firstMatch, equals(true));
        expect(secondMatch, equals(false));
      });

      test('allows match after debounceMs period (simulated with delays)', () async {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause',
          windowMs: 5000,
          debounceMs: 50,
        );

        final firstMatch = matcher.onEvent(event: 'pause', config: config);
        expect(firstMatch, equals(true));

        await Future.delayed(Duration(milliseconds: 60));

        final secondMatch = matcher.onEvent(event: 'pause', config: config);
        expect(secondMatch, equals(true));
      });
    });

    group('state management', () {
      test('clears events after successful match', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        matcher.onEvent(event: 'pause', config: config);
        matcher.onEvent(event: 'play', config: config);

        final thirdEvent = matcher.onEvent(event: 'pause', config: config);

        expect(thirdEvent, equals(false));
      });

      test('maintains state across non-matching events', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play,pause',
          windowMs: 5000,
          debounceMs: 500,
        );

        matcher.onEvent(event: 'pause', config: config);
        matcher.onEvent(event: 'play', config: config);

        final pauseMatch = matcher.onEvent(event: 'pause', config: config);

        expect(pauseMatch, equals(true));
      });
    });

    group('three-event pattern', () {
      test('matches three-event sequence correctly', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play,pause',
          windowMs: 5000,
          debounceMs: 500,
        );

        final first = matcher.onEvent(event: 'pause', config: config);
        final second = matcher.onEvent(event: 'play', config: config);
        final third = matcher.onEvent(event: 'pause', config: config);

        expect(first, equals(false));
        expect(second, equals(false));
        expect(third, equals(true));
      });

      test('does not match incomplete three-event pattern', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play,pause',
          windowMs: 5000,
          debounceMs: 500,
        );

        final first = matcher.onEvent(event: 'pause', config: config);
        final second = matcher.onEvent(event: 'play', config: config);

        expect(first, equals(false));
        expect(second, equals(false));
      });
    });

    group('multiple events before match', () {
      test('matches correct pattern at end of sequence', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        matcher.onEvent(event: 'play', config: config);
        matcher.onEvent(event: 'play', config: config);
        final match = matcher.onEvent(event: 'pause', config: config);
        final secondMatch = matcher.onEvent(event: 'play', config: config);

        expect(match, equals(false));
        expect(secondMatch, equals(true));
      });

      test('uses tail of events for pattern matching', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        matcher.onEvent(event: 'play', config: config);
        matcher.onEvent(event: 'pause', config: config);
        final match = matcher.onEvent(event: 'play', config: config);

        expect(match, equals(true));
      });
    });

    group('window expiration', () {
      test('events outside window are removed', () async {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 50,
          debounceMs: 500,
        );

        matcher.onEvent(event: 'pause', config: config);
        await Future.delayed(Duration(milliseconds: 60));

        final match = matcher.onEvent(event: 'play', config: config);

        expect(match, equals(false));
      });
    });

    group('pattern with spaces', () {
      test('correctly parses pattern with spaces around events', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause , play',
          windowMs: 5000,
          debounceMs: 500,
        );

        matcher.onEvent(event: 'pause', config: config);
        final match = matcher.onEvent(event: 'play', config: config);

        expect(match, equals(true));
      });
    });

    group('edge cases', () {
      test('an empty pattern never triggers, however many events arrive', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: '',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(matcher.onEvent(event: 'play', config: config), equals(false));
        expect(matcher.onEvent(event: 'pause', config: config), equals(false));
        expect(matcher.onEvent(event: 'play', config: config), equals(false));
      });

      test('a comma and whitespace only pattern never triggers', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: ' , , ',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(matcher.onEvent(event: 'pause', config: config), equals(false));
        expect(matcher.onEvent(event: 'play', config: config), equals(false));
      });

      test('handles rapid consecutive valid events', () {
        final matcher = SignalPatternMatcher();
        final config = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 0,
        );

        matcher.onEvent(event: 'pause', config: config);
        final firstMatch = matcher.onEvent(event: 'play', config: config);

        matcher.onEvent(event: 'pause', config: config);
        final secondMatch = matcher.onEvent(event: 'play', config: config);

        expect(firstMatch, equals(true));
        expect(secondMatch, equals(true));
      });
    });
  });
}
