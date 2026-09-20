import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/presentation/screens/trigger_config_screen.dart';

import '../../helpers/screen_harness.dart';

void main() {
  /// Clears the pattern field, replaces it with [pattern], and presses Save.
  Future<void> saveWithPattern(WidgetTester tester, String pattern) async {
    await tester.pumpWidget(hostScreen(const TriggerConfigScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Pattern'),
      pattern,
    );
    // The Save button lives below the fold of a lazy ListView, so it has to be
    // scrolled into existence before it can be tapped.
    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.scrollUntilVisible(
      save,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('refuses an empty pattern and says what is missing',
      (tester) async {
    await saveWithPattern(tester, '');

    expect(
      find.text('Trigger pattern needs at least one event, '
          'for example pause,play.'),
      findsOneWidget,
    );
    expect(find.text('Trigger configuration saved'), findsNothing);
  });

  testWidgets('refuses a pattern that is only commas and whitespace',
      (tester) async {
    await saveWithPattern(tester, ' , , ');

    expect(
      find.text('Trigger pattern needs at least one event, '
          'for example pause,play.'),
      findsOneWidget,
    );
    expect(find.text('Trigger configuration saved'), findsNothing);
  });
}
