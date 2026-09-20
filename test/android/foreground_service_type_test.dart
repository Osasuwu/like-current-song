@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Foreground service types an app targeting Android 15 (API 35) or higher may
/// not start from a `BOOT_COMPLETED` receiver — the system throws
/// `ForegroundServiceStartNotAllowedException` instead.
///
/// https://developer.android.com/about/versions/15/behavior-changes-15
const restrictedFromBootCompleted = <String>{
  'dataSync',
  'camera',
  'mediaPlayback',
  'phoneCall',
  'mediaProjection',
  // Restricted since Android 14.
  'microphone',
};

/// This is a manifest test rather than a Kotlin one on purpose: the Kotlin unit
/// tests under `android/app/src/test/` are not wired into CI (`ci.yml` runs
/// `flutter test` and `pytest`), so a guard placed there would gate nothing.
void main() {
  late String manifest;

  setUpAll(() {
    final file = File('android/app/src/main/AndroidManifest.xml');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run from the package root, where `flutter test` runs',
    );
    // Comments quote the very type names under test; drop them so the
    // assertions read the declarations and nothing else.
    manifest = file.readAsStringSync().replaceAll(
      RegExp(r'<!--.*?-->', dotAll: true),
      '',
    );
  });

  group('MediaButtonForegroundService', () {
    test('is startable from BOOT_COMPLETED on Android 15+', () {
      // The premise: BootCompletedReceiver starts this service, so its type is
      // subject to the restriction. If the receiver ever stops listening for
      // boot, this test is measuring nothing and should be revisited.
      expect(
        _element(manifest, 'receiver', '.BootCompletedReceiver'),
        contains('android.intent.action.BOOT_COMPLETED'),
        reason: 'the boot receiver is what makes the service type matter',
      );

      final type = _foregroundServiceType(
        _element(manifest, 'service', '.MediaButtonForegroundService'),
      );

      expect(
        restrictedFromBootCompleted,
        isNot(contains(type)),
        reason:
            'foregroundServiceType="$type" cannot be started from a '
            'BOOT_COMPLETED receiver when targeting API 35+, so the listener '
            'would never come back after a reboot',
      );
    });

    test('declares the subtype and permission specialUse requires', () {
      final service = _element(
        manifest,
        'service',
        '.MediaButtonForegroundService',
      );
      if (_foregroundServiceType(service) != 'specialUse') {
        return; // Another allowed type; these two requirements are specialUse's.
      }

      expect(
        manifest,
        contains('android.permission.FOREGROUND_SERVICE_SPECIAL_USE'),
        reason: 'specialUse requires FOREGROUND_SERVICE_SPECIAL_USE',
      );

      final subtype = RegExp(
        r'<property\s+android:name="android\.app\.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"\s+android:value="([^"]*)"',
      ).firstMatch(service);
      expect(
        subtype,
        isNotNull,
        reason:
            'specialUse requires a PROPERTY_SPECIAL_USE_FGS_SUBTYPE property '
            'inside the <service>; Play reviews the explanation it carries',
      );
      expect(subtype!.group(1)!.trim(), isNotEmpty);
    });
  });
}

/// The `<$tag>` element whose `android:name` is [name], opening tag through
/// close. Self-closing elements come back as just the opening tag.
String _element(String manifest, String tag, String name) {
  final start = manifest.indexOf(
    RegExp('<$tag\\b(?=[^>]*android:name="${RegExp.escape(name)}")'),
  );
  expect(start, isNot(-1), reason: 'no <$tag android:name="$name"> found');

  final openEnd = manifest.indexOf('>', start);
  if (manifest[openEnd - 1] == '/') {
    return manifest.substring(start, openEnd + 1);
  }
  final close = manifest.indexOf('</$tag>', openEnd);
  expect(close, isNot(-1), reason: '<$tag android:name="$name"> is unclosed');
  return manifest.substring(start, close + '</$tag>'.length);
}

String _foregroundServiceType(String service) {
  final match = RegExp(
    r'android:foregroundServiceType="([^"]*)"',
  ).firstMatch(service);
  expect(match, isNotNull, reason: 'the service declares no FGS type');
  return match!.group(1)!;
}
