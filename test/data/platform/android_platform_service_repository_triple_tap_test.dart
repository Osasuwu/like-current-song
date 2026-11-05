import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/data/platform/android_platform_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/trigger_config.dart';
import 'package:like_spotify_mobile_app/domain/entities/triple_tap_status.dart';

/// The triple-tap mode (#158) lives on the native side: the switch reaches it
/// through `setTriggerConfig`, and the screen's status line is whatever
/// `getTripleTapStatus` answers. These tests stand in for the native half.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.serviceMethodChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AndroidPlatformServiceRepository repository;
  late List<MethodCall> calls;

  void nativeAnswers(Object? Function(MethodCall call) answer) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  }

  setUp(() {
    calls = <MethodCall>[];
    repository = AndroidPlatformServiceRepository();
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('updateTriggerConfig', () {
    for (final enabled in [true, false]) {
      test('carries the triple-tap switch as $enabled', () async {
        nativeAnswers((_) => null);

        await repository.updateTriggerConfig(const TriggerConfig(
          pattern: 'pause,play',
          windowMs: 1200,
          debounceMs: 80,
        ).copyWith(tripleTapEnabled: enabled));

        expect(calls.single.method, 'setTriggerConfig');
        expect(
          (calls.single.arguments as Map)['tripleTapEnabled'],
          enabled,
        );
      });
    }
  });

  group('tripleTapStatus', () {
    const wire = <String, TripleTapStatus>{
      'off': TripleTapStatus.off,
      'unavailable': TripleTapStatus.unavailable,
      'not_granted': TripleTapStatus.notGranted,
      'needs_notification_access': TripleTapStatus.needsNotificationAccess,
      'listener_off': TripleTapStatus.listenerOff,
      'slot_taken': TripleTapStatus.slotTaken,
      'checking': TripleTapStatus.checking,
      'no_bluetooth_output': TripleTapStatus.noBluetoothOutput,
      'active': TripleTapStatus.active,
    };

    for (final entry in wire.entries) {
      test('"${entry.key}" from the native side reads as ${entry.value.name}',
          () async {
        nativeAnswers((_) => entry.key);

        expect(await repository.tripleTapStatus(), entry.value);
        expect(calls.single.method, 'getTripleTapStatus');
      });
    }

    test('an answer this build does not know reads as unavailable', () async {
      nativeAnswers((_) => 'something_new');

      expect(await repository.tripleTapStatus(), TripleTapStatus.unavailable);
    });

    test('no answer reads as unavailable', () async {
      nativeAnswers((_) => null);

      expect(await repository.tripleTapStatus(), TripleTapStatus.unavailable);
    });

    test('a native half without the method reads as unavailable, not a crash',
        () async {
      // No handler at all: the channel throws MissingPluginException.
      expect(await repository.tripleTapStatus(), TripleTapStatus.unavailable);
    });

    test('a native error reads as unavailable, not a crash', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom');
      });

      expect(await repository.tripleTapStatus(), TripleTapStatus.unavailable);
    });
  });
}
