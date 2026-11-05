import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/domain/entities/trigger_config.dart';
import 'package:like_spotify_mobile_app/domain/entities/triple_tap_status.dart';
import 'package:like_spotify_mobile_app/presentation/screens/trigger_config_screen.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_providers.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/app_controller_harness.dart';

/// The triple-tap section of the trigger screen (#158): an opt-in switch saved
/// with the rest of the trigger, the native side's status line, and the
/// one-time setup the mode cannot run without.
void main() {
  late AppControllerHarness harness;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'spotify_client_id': 'test-client-id',
    });
    registerAppControllerFallbacks();
    harness = AppControllerHarness()..notificationAccess = true;
  });

  /// Opens the screen the way the app does: pushed from a page that was up
  /// while the controller started, so the screen reads a loaded config.
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      harness.host(
        Consumer(
          builder: (context, ref, _) {
            ref.watch(appControllerProvider);
            return TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const TriggerConfigScreen(),
                ),
              ),
              child: const Text('open'),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  final tripleTapSwitch = find.widgetWithText(
    SwitchListTile,
    "Like on the earbuds' triple tap",
  );
  final save = find.widgetWithText(FilledButton, 'Save');

  Future<void> pressSave(WidgetTester tester) async {
    await scrollTo(tester, save);
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  TriggerConfig savedTrigger() =>
      verify(
            () => harness.platform.updateTriggerConfig(captureAny()),
          ).captured.last
          as TriggerConfig;

  testWidgets('turning the switch on and saving hands it to the listener', (
    tester,
  ) async {
    await open(tester);

    await scrollTo(tester, tripleTapSwitch);
    await tester.tap(tripleTapSwitch);
    await tester.pumpAndSettle();
    await pressSave(tester);

    expect(savedTrigger().tripleTapEnabled, isTrue);
  });

  testWidgets('a saved choice shows on the switch and survives a save', (
    tester,
  ) async {
    when(() => harness.settings.loadTriggerConfig()).thenAnswer(
      (_) async => const TriggerConfig(
        pattern: AppConstants.defaultPattern,
        windowMs: AppConstants.defaultWindowMs,
        debounceMs: AppConstants.defaultDebounceMs,
        tripleTapEnabled: true,
      ),
    );
    await open(tester);

    await scrollTo(tester, tripleTapSwitch);
    expect(tester.widget<SwitchListTile>(tripleTapSwitch).value, isTrue);

    await pressSave(tester);
    expect(savedTrigger().tripleTapEnabled, isTrue);
  });

  testWidgets('the switch is off on an install that never opted in', (
    tester,
  ) async {
    await open(tester);

    await scrollTo(tester, tripleTapSwitch);
    expect(tester.widget<SwitchListTile>(tripleTapSwitch).value, isFalse);

    await pressSave(tester);
    expect(savedTrigger().tripleTapEnabled, isFalse);
  });

  testWidgets('shows what the native side says stands in the way', (
    tester,
  ) async {
    harness.tripleTapStatus = TripleTapStatus.slotTaken;
    await open(tester);

    final status = find.text(TripleTapStatus.slotTaken.label);
    await scrollTo(tester, status);
    expect(status, findsOneWidget);
  });

  testWidgets('Check again reads the status afresh', (tester) async {
    harness.tripleTapStatus = TripleTapStatus.notGranted;
    await open(tester);

    harness.tripleTapStatus = TripleTapStatus.active;
    final recheck = find.widgetWithText(TextButton, 'Check again');
    await scrollTo(tester, recheck);
    await tester.tap(recheck);
    await tester.pumpAndSettle();

    expect(find.text(TripleTapStatus.active.label), findsOneWidget);
    expect(find.text(TripleTapStatus.notGranted.label), findsNothing);
  });

  testWidgets(
    'a status still being checked is read again until it settles',
    (tester) async {
      harness.tripleTapStatus = TripleTapStatus.checking;
      await open(tester);
      final checking = find.text(TripleTapStatus.checking.label);
      await scrollTo(tester, checking);
      expect(checking, findsOneWidget);

      // The probe ends on the native side; nobody presses Check again.
      harness.tripleTapStatus = TripleTapStatus.slotTaken;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.text(TripleTapStatus.slotTaken.label), findsOneWidget);
      expect(checking, findsNothing);
    },
  );

  testWidgets('a settled status is read once, not polled', (tester) async {
    harness.tripleTapStatus = TripleTapStatus.active;
    await open(tester);
    await tester.pump(const Duration(seconds: 10));

    verify(() => harness.platform.tripleTapStatus()).called(1);
  });

  testWidgets(
    'a check that never settles stops reading after a few tries',
    (tester) async {
      harness.tripleTapStatus = TripleTapStatus.checking;
      await open(tester);
      await tester.pump(const Duration(seconds: 30));
      clearInteractions(harness.platform);
      await tester.pump(const Duration(seconds: 30));

      verifyNever(() => harness.platform.tripleTapStatus());
      final checking = find.text(TripleTapStatus.checking.label);
      await scrollTo(tester, checking);
      expect(checking, findsOneWidget);
    },
  );

  testWidgets('leaving the screen mid-check stops the reads', (tester) async {
    harness.tripleTapStatus = TripleTapStatus.checking;
    await open(tester);
    Navigator.of(tester.element(find.byType(TriggerConfigScreen))).pop();
    await tester.pumpAndSettle();
    clearInteractions(harness.platform);

    await tester.pump(const Duration(seconds: 10));

    verifyNever(() => harness.platform.tripleTapStatus());
  });

  testWidgets(
    'saving reads the status again, since the mode may have changed',
    (tester) async {
      await open(tester);

      harness.tripleTapStatus = TripleTapStatus.notGranted;
      await pressSave(tester);
      await tester.pumpAndSettle();

      final status = find.text(TripleTapStatus.notGranted.label);
      await scrollTo(tester, status);
      expect(status, findsOneWidget);
    },
  );

  testWidgets('the setup names the adb grant, Shizuku, and both caveats', (
    tester,
  ) async {
    await open(tester);

    const grant =
        'adb shell pm grant com.osasuwu.like_spotify '
        'android.permission.SET_MEDIA_KEY_LISTENER';
    final command = find.text(grant);
    await scrollTo(tester, command);
    expect(command, findsOneWidget);
    expect(find.textContaining('Shizuku'), findsOneWidget);
    expect(
      find.textContaining('send "previous" on a triple tap'),
      findsOneWidget,
    );
    expect(find.textContaining('any Bluetooth device'), findsOneWidget);
  });
}
