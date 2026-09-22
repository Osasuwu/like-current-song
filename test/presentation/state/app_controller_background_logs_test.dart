import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_controller.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/app_controller_harness.dart';

/// Likes that happened with the app swiped out are only in the native buffer,
/// and reading it empties it. Start-up is therefore the one chance to keep
/// them — and it has to keep them with the time they actually happened.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppControllerHarness harness;
  late AppController controller;
  late List<AppLog> stored;

  setUpAll(registerAppControllerFallbacks);

  setUp(() {
    silenceConnectivityChannel();
    harness = AppControllerHarness();
    // An in-memory stand-in for the stored log, so what start-up appends is
    // what the Logs screen then reads.
    stored = <AppLog>[];
    when(() => harness.settings.appendLog(any())).thenAnswer((invocation) async {
      stored.add(invocation.positionalArguments.single as AppLog);
    });
    when(() => harness.settings.loadLogs())
        .thenAnswer((_) async => List<AppLog>.of(stored));
  });

  tearDown(() => controller.dispose());

  test('persists the drained events with their own timestamps', () async {
    harness.backgroundLogs = <AppLog>[
      AppLog(
        at: DateTime.utc(2026, 9, 21, 23, 14),
        actionType: 'like',
        targetId: 'track-1',
        result: LogResult.success,
        message: 'Liked in the background',
      ),
      AppLog(
        at: DateTime.utc(2026, 9, 22, 1, 2),
        actionType: 'like',
        result: LogResult.failure,
        httpCode: 502,
        message: 'Background like failed',
      ),
    ];

    controller = harness.build();
    await pumpEventQueue();

    expect(
      stored.map((log) => log.at),
      <DateTime>[
        DateTime.utc(2026, 9, 21, 23, 14),
        DateTime.utc(2026, 9, 22, 1, 2),
      ],
    );
    expect(stored.first.targetId, 'track-1');
    expect(stored.last.httpCode, 502);
  });

  test('shows the drained events on the Logs screen without a refresh',
      () async {
    harness.backgroundLogs = <AppLog>[
      AppLog(
        at: DateTime.utc(2026, 9, 21, 23, 14),
        actionType: 'like',
        message: 'Liked in the background',
      ),
    ];

    controller = harness.build();
    await pumpEventQueue();

    expect(
      controller.state.logs.map((log) => log.message),
      contains('Liked in the background'),
    );
  });

  test('drains once per start-up', () async {
    controller = harness.build();
    await pumpEventQueue();

    verify(() => harness.platform.drainBackgroundLogs()).called(1);
  });

  test('a throwing drain still lets start-up finish', () async {
    when(() => harness.platform.drainBackgroundLogs())
        .thenThrow(Exception('no such method'));

    controller = harness.build();
    await pumpEventQueue();

    expect(controller.state.loading, isFalse);
    expect(controller.state.lastError, isNull);
    // The rest of start-up still ran.
    verify(() => harness.platform.updateTriggerConfig(any())).called(1);
  });
}
