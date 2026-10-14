import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/trigger_config.dart';

void main() {
  group('TriggerConfig', () {
    group('events getter', () {
      test('splits comma-separated pattern into list', () {
        final config = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(config.events, equals(['pause', 'play']));
      });

      test('trims whitespace around events', () {
        final config = TriggerConfig(
          pattern: 'pause , play',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(config.events, equals(['pause', 'play']));
      });

      test('returns empty list for empty string', () {
        final config = TriggerConfig(
          pattern: '',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(config.events, equals([]));
      });

      test('returns single event', () {
        final config = TriggerConfig(
          pattern: 'pause',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(config.events, equals(['pause']));
      });

      test('filters out empty strings from trailing comma', () {
        final config = TriggerConfig(
          pattern: 'pause,play,',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(config.events, equals(['pause', 'play']));
      });

      test('filters out empty strings from leading comma', () {
        final config = TriggerConfig(
          pattern: ',pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(config.events, equals(['pause', 'play']));
      });

      test('handles multiple consecutive commas', () {
        final config = TriggerConfig(
          pattern: 'pause,,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(config.events, equals(['pause', 'play']));
      });

      test('handles only commas and whitespace', () {
        final config = TriggerConfig(
          pattern: ', , , ',
          windowMs: 5000,
          debounceMs: 500,
        );

        expect(config.events, equals([]));
      });
    });

    group('validate', () {
      test('accepts a pattern that has events', () {
        final config = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 1000,
          debounceMs: 500,
        );

        expect(config.validate(), isEmpty);
      });

      test('rejects an empty pattern, saying what is missing', () {
        final config = TriggerConfig(
          pattern: '',
          windowMs: 1000,
          debounceMs: 500,
        );

        expect(config.validate(), hasLength(1));
        expect(config.validate().single, contains('at least one event'));
      });

      test('rejects a pattern that is only commas and whitespace', () {
        final config = TriggerConfig(
          pattern: ' , , ',
          windowMs: 1000,
          debounceMs: 500,
        );

        expect(config.validate(), hasLength(1));
      });

      test('caps the window at 1500 ms, saying so (#248)', () {
        // Past 1.5 s an automatic pause and the resume after it read as the
        // user's `pause, play`. The limit and its message are the contract.
        const atCap = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 1500,
          debounceMs: 500,
        );
        const pastCap = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 1501,
          debounceMs: 500,
        );

        expect(atCap.validate(), isEmpty);
        expect(
          pastCap.validate(),
          equals(<String>['Trigger window can be at most 1500 ms.']),
        );
      });
    });

    group('copyWith', () {
      test('updates pattern when provided', () {
        final original = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        final updated = original.copyWith(pattern: 'play');

        expect(updated.pattern, equals('play'));
        expect(updated.windowMs, equals(5000));
        expect(updated.debounceMs, equals(500));
      });

      test('updates windowMs when provided', () {
        final original = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        final updated = original.copyWith(windowMs: 10000);

        expect(updated.pattern, equals('pause,play'));
        expect(updated.windowMs, equals(10000));
        expect(updated.debounceMs, equals(500));
      });

      test('updates debounceMs when provided', () {
        final original = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        final updated = original.copyWith(debounceMs: 1000);

        expect(updated.pattern, equals('pause,play'));
        expect(updated.windowMs, equals(5000));
        expect(updated.debounceMs, equals(1000));
      });

      test('updates multiple fields at once', () {
        final original = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        final updated = original.copyWith(
          pattern: 'play',
          windowMs: 8000,
          debounceMs: 2000,
        );

        expect(updated.pattern, equals('play'));
        expect(updated.windowMs, equals(8000));
        expect(updated.debounceMs, equals(2000));
      });

      test('preserves all fields when copyWith called with no parameters', () {
        final original = TriggerConfig(
          pattern: 'pause,play',
          windowMs: 5000,
          debounceMs: 500,
        );

        final copy = original.copyWith();

        expect(copy.pattern, equals(original.pattern));
        expect(copy.windowMs, equals(original.windowMs));
        expect(copy.debounceMs, equals(original.debounceMs));
      });
    });
  });
}
