import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/trigger_config.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_controller.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/app_controller_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppControllerHarness harness;
  late AppController controller;

  setUpAll(registerAppControllerFallbacks);
  setUp(silenceConnectivityChannel);
  tearDown(() => controller.dispose());

  /// Builds the controller, lets start-up finish, then forgets the start-up
  /// calls so every `verify` below is about the save.
  Future<void> start() async {
    harness = AppControllerHarness();
    controller = harness.build();
    await pumpEventQueue();
    clearInteractions(harness.settings);
    clearInteractions(harness.platform);
  }

  test('keeps an empty pattern out of storage and off the native listener',
      () async {
    await start();
    final before = controller.state.triggerConfig;

    await controller.saveTriggerConfig(
      const TriggerConfig(pattern: '', windowMs: 1000, debounceMs: 650),
    );

    verifyNever(() => harness.settings.saveTriggerConfig(any()));
    verifyNever(() => harness.platform.updateTriggerConfig(any()));
    expect(controller.state.triggerConfig.pattern, before.pattern);
    expect(controller.state.lastError, contains('at least one event'));
  });
}
