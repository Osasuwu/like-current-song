import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/data/platform/android_platform_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/undo_window.dart';

/// The in-app Undo button (#268) mirrors the native undo journal over the
/// platform channel. These tests stand in for the native half: a window read
/// wrong shows a button that cannot undo, or hides one that could.
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

  group('undoWindow', () {
    test('an open window comes back as its like and its close time', () async {
      nativeAnswers((_) => <dynamic, dynamic>{
            'pressId': 'press-7',
            'closesAt': 1758300010000,
          });

      final window = await repository.undoWindow();

      expect(calls.single.method, 'getUndoWindow');
      expect(
        window,
        UndoWindow(
          pressId: 'press-7',
          closesAt: DateTime.fromMillisecondsSinceEpoch(1758300010000),
        ),
      );
    });

    test('no window open comes back as null', () async {
      nativeAnswers((_) => null);

      expect(await repository.undoWindow(), isNull);
    });

    test('a native half without the method means no window, not a crash',
        () async {
      nativeAnswers((_) => throw PlatformException(code: 'notImplemented'));

      expect(await repository.undoWindow(), isNull);
    });
  });

  group('UndoWindow.fromChannel', () {
    test('a map missing its close time is no window', () {
      expect(UndoWindow.fromChannel(<dynamic, dynamic>{'pressId': 'p'}), isNull);
    });

    test('a blank press id is no window', () {
      expect(
        UndoWindow.fromChannel(<dynamic, dynamic>{'pressId': '', 'closesAt': 5}),
        isNull,
      );
    });
  });

  group('undoLike', () {
    test('sends the like it undoes and reports the undo started', () async {
      nativeAnswers((_) => 'UNDO');

      final result = await repository.undoLike('press-7');

      expect(calls.single.method, 'undoLike');
      expect(calls.single.arguments, <String, dynamic>{'pressId': 'press-7'});
      expect(result, UndoTapResult.undo);
    });

    test('reports an undo already under way', () async {
      nativeAnswers((_) => 'ALREADY_UNDOING');

      expect(await repository.undoLike('press-7'), UndoTapResult.alreadyUndoing);
    });

    test('reports a like that can no longer be undone', () async {
      nativeAnswers((_) => 'TOO_LATE');

      expect(await repository.undoLike('press-7'), UndoTapResult.tooLate);
    });
  });
}
