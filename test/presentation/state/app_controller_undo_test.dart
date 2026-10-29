import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/domain/entities/undo_window.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_controller.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/app_controller_harness.dart';

/// The in-app Undo button (#268) offers what the native undo journal says can
/// be undone, and a tap on it undoes exactly that like. The journal is the
/// one source: the controller only mirrors it, so the button can never offer
/// a like the gesture would not undo.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppControllerHarness harness;
  late AppController controller;
  late List<AppLog> stored;

  UndoWindow openFor(String pressId) => UndoWindow(
        pressId: pressId,
        closesAt: DateTime.now().add(const Duration(seconds: 10)),
      );

  setUpAll(registerAppControllerFallbacks);

  setUp(() {
    silenceConnectivityChannel();
    harness = AppControllerHarness();
    stored = <AppLog>[];
    when(() => harness.settings.appendLog(any())).thenAnswer((invocation) async {
      stored.add(invocation.positionalArguments.single as AppLog);
    });
    when(() => harness.settings.loadLogs())
        .thenAnswer((_) async => List<AppLog>.of(stored));
  });

  tearDown(() => controller.dispose());

  test('a like made in the background is offered for undo once the app opens',
      () async {
    final window = openFor('press-bg');
    harness.undoWindow = window;

    controller = harness.build();
    await pumpEventQueue();

    expect(controller.state.undoWindow, window);
  });

  test('a window that closed before the app opened is not offered', () async {
    harness.undoWindow = UndoWindow(
      pressId: 'press-old',
      closesAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );

    controller = harness.build();
    await pumpEventQueue();

    expect(controller.state.undoWindow, isNull);
  });

  test('the journal opening and closing a window shows and hides it', () async {
    controller = harness.build();
    await pumpEventQueue();
    final closesAt = DateTime.now().add(const Duration(seconds: 10));

    harness.nativeEvents.add(<String, dynamic>{
      'type': 'undo_window',
      'value': <dynamic, dynamic>{
        'pressId': 'press-1',
        'closesAt': closesAt.millisecondsSinceEpoch,
      },
    });
    await pumpEventQueue();
    expect(controller.state.undoWindow?.pressId, 'press-1');

    harness.nativeEvents.add(<String, dynamic>{
      'type': 'undo_window',
      'value': null,
    });
    await pumpEventQueue();
    expect(controller.state.undoWindow, isNull);
  });

  test('a tap undoes the offered like and hides the button', () async {
    harness.undoWindow = openFor('press-1');
    when(() => harness.platform.undoLike(any()))
        .thenAnswer((_) async => UndoTapResult.undo);
    controller = harness.build();
    await pumpEventQueue();

    await controller.undoLastLike();

    verify(() => harness.platform.undoLike('press-1')).called(1);
    expect(controller.state.undoWindow, isNull);
    expect(
      stored.map((log) => (log.actionType, log.message)),
      contains(('undo', 'Undo tapped in the app: undoing the last like')),
    );
  });

  test('a tap that came too late is logged as nothing undone', () async {
    harness.undoWindow = openFor('press-1');
    when(() => harness.platform.undoLike(any()))
        .thenAnswer((_) async => UndoTapResult.tooLate);
    controller = harness.build();
    await pumpEventQueue();

    await controller.undoLastLike();

    expect(controller.state.undoWindow, isNull);
    expect(
      stored.map((log) => log.message),
      contains(
        'Undo tapped, but that like can no longer be undone: nothing undone',
      ),
    );
  });

  test('with no window offered a tap undoes nothing', () async {
    controller = harness.build();
    await pumpEventQueue();

    await controller.undoLastLike();

    verifyNever(() => harness.platform.undoLike(any()));
  });

  test('a failed tap is logged and the button follows the journal again',
      () async {
    final window = openFor('press-1');
    harness.undoWindow = window;
    when(() => harness.platform.undoLike(any()))
        .thenThrow(Exception('channel down'));
    controller = harness.build();
    await pumpEventQueue();

    await controller.undoLastLike();

    expect(
      stored.where((log) => log.result == LogResult.failure).map((l) => l.message),
      contains(contains('channel down')),
    );
    // The like was not undone, so it is offered again while it still can be.
    expect(controller.state.undoWindow, window);
  });
}
