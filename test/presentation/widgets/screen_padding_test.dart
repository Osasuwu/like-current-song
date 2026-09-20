import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/presentation/widgets/screen_padding.dart';

/// Builds [scrollBodyPadding] under a [MediaQuery] that reports [padding],
/// the way an Android navigation bar does.
Future<EdgeInsets> pad(
  WidgetTester tester, {
  required EdgeInsets padding,
  EdgeInsets base = const EdgeInsets.all(16),
}) async {
  late EdgeInsets result;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(padding: padding),
      child: Builder(
        builder: (context) {
          result = scrollBodyPadding(context, base: base);
          return const SizedBox();
        },
      ),
    ),
  );
  return result;
}

void main() {
  testWidgets('adds the navigation bar inset under the base padding',
      (tester) async {
    expect(
      await pad(tester, padding: const EdgeInsets.only(bottom: 48)),
      const EdgeInsets.fromLTRB(16, 16, 16, 64),
    );
  });

  testWidgets('is the base padding when nothing is inset', (tester) async {
    expect(
      await pad(tester, padding: EdgeInsets.zero),
      const EdgeInsets.all(16),
    );
  });

  testWidgets('carries the inset alone when the base is zero', (tester) async {
    expect(
      await pad(
        tester,
        padding: const EdgeInsets.only(bottom: 48),
        base: EdgeInsets.zero,
      ),
      const EdgeInsets.only(bottom: 48),
    );
  });
}
