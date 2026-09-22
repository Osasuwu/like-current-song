import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/presentation/screens/logs_screen.dart';

import '../../helpers/screen_harness.dart';

void main() {
  group('formatLogTime', () {
    test('shows only the clock for something from today', () {
      final now = DateTime(2026, 9, 22, 20, 5);
      final at = DateTime(2026, 9, 22, 18, 34).toUtc();
      expect(formatLogTime(at, now: now), '18:34');
    });

    test('adds the day once the event is not from today', () {
      // The point of the whole screen once background events are kept: an
      // entry from last night must not read like one from a minute ago.
      final now = DateTime(2026, 9, 22, 9, 0);
      final at = DateTime(2026, 9, 21, 23, 58).toUtc();
      expect(formatLogTime(at, now: now), '21 Sep 23:58');
    });

    test('adds the year once that differs too', () {
      final now = DateTime(2026, 1, 2, 9, 0);
      final at = DateTime(2025, 12, 31, 23, 58).toUtc();
      expect(formatLogTime(at, now: now), '31 Dec 2025 23:58');
    });

    test('pads a single-digit hour and minute', () {
      final now = DateTime(2026, 9, 22, 20, 5);
      final at = DateTime(2026, 9, 22, 7, 4).toUtc();
      expect(formatLogTime(at, now: now), '07:04');
    });
  });

  group('LogsScreen', () {
    testWidgets('puts the time in front of every entry', (tester) async {
      // A couple of hours back, so the rendered clock differs from the
      // current one and the assertion cannot pass by accident.
      final at = DateTime.now().subtract(const Duration(hours: 2));
      await tester.pumpWidget(
        hostScreen(
          const LogsScreen(),
          logs: <AppLog>[
            AppLog(
              at: at.toUtc(),
              actionType: 'like_track',
              targetId: '4cOdK2wGLETKBW3PvgPWqT',
              result: LogResult.success,
              httpCode: 200,
              message: 'Liked track',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      String two(int value) => value.toString().padLeft(2, '0');
      // `textContaining`, so a date prefix around midnight does not matter.
      expect(
        find.textContaining(
          '${two(at.hour)}:${two(at.minute)} · like_track · '
          '4cOdK2wGLETKBW3PvgPWqT · HTTP 200',
        ),
        findsOneWidget,
      );
    });
  });
}
