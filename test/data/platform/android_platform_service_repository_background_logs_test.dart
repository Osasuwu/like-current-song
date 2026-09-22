import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/data/platform/android_platform_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';

/// The native side buffers the log events that reached no live Flutter
/// attachment and hands them over once, oldest first. These tests stand in for
/// that channel, because getting the mapping wrong loses a background like
/// silently — there is no second chance to read the buffer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.serviceMethodChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AndroidPlatformServiceRepository repository;
  late List<String> calls;

  /// Answers `drainBackgroundLogs` with [entries]; any other method answers
  /// null, which is what the methods returning void do.
  void nativeReturns(List<dynamic> entries) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'drainBackgroundLogs') return entries;
      return null;
    });
  }

  /// Makes `drainBackgroundLogs` fail the way an older native half does.
  void nativeThrows(Exception error) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw error;
    });
  }

  setUp(() {
    calls = <String>[];
    repository = AndroidPlatformServiceRepository();
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('maps a well-formed native entry to an AppLog', () async {
    nativeReturns(<dynamic>[
      <dynamic, dynamic>{
        'atMs': 1758300000000,
        'actionType': 'like',
        'targetId': 'track-42',
        'result': 'success',
        'httpCode': 200,
        'message': 'Liked while the app was closed',
      },
    ]);

    final logs = await repository.drainBackgroundLogs();

    expect(calls, <String>['drainBackgroundLogs']);
    expect(logs, hasLength(1));
    final log = logs.single;
    expect(log.at, DateTime.fromMillisecondsSinceEpoch(1758300000000, isUtc: true));
    expect(log.at.isUtc, isTrue);
    expect(log.actionType, 'like');
    expect(log.targetId, 'track-42');
    expect(log.result, LogResult.success);
    expect(log.httpCode, 200);
    expect(log.message, 'Liked while the app was closed');
  });

  test('a null or absent targetId and httpCode map to null', () async {
    nativeReturns(<dynamic>[
      <dynamic, dynamic>{
        'atMs': 1758300000000,
        'actionType': 'like',
        'targetId': null,
        'result': 'failure',
        'httpCode': null,
        'message': 'No track playing',
      },
      <dynamic, dynamic>{
        'atMs': 1758300001000,
        'actionType': 'like',
        'result': 'failure',
        'message': 'No track playing either',
      },
    ]);

    final logs = await repository.drainBackgroundLogs();

    expect(logs, hasLength(2));
    for (final log in logs) {
      expect(log.targetId, isNull);
      expect(log.httpCode, isNull);
      expect(log.result, LogResult.failure);
    }
  });

  test('an unknown result string degrades to info', () async {
    nativeReturns(<dynamic>[
      <dynamic, dynamic>{
        'atMs': 1758300000000,
        'actionType': 'like',
        'result': 'exploded',
        'message': 'Something new the Dart side does not know',
      },
    ]);

    final logs = await repository.drainBackgroundLogs();

    expect(logs.single.result, LogResult.info);
  });

  test('skips a malformed entry and keeps the rest of the batch', () async {
    nativeReturns(<dynamic>[
      <dynamic, dynamic>{
        'atMs': 1758300000000,
        'actionType': 'like',
        'result': 'success',
        'message': 'First',
      },
      // No timestamp: nowhere to put it on the Logs screen.
      <dynamic, dynamic>{'actionType': 'like', 'message': 'Undated'},
      // Timestamp of the wrong type, and a message of the wrong type.
      <dynamic, dynamic>{'atMs': 'yesterday', 'message': 'Stringly typed'},
      <dynamic, dynamic>{'atMs': 1758300002000, 'message': 42},
      // Not a map at all.
      'not an entry',
      <dynamic, dynamic>{
        'atMs': 1758300003000,
        'actionType': 'like',
        'result': 'success',
        'message': 'Last',
      },
    ]);

    final logs = await repository.drainBackgroundLogs();

    expect(logs.map((log) => log.message), <String>['First', 'Last']);
  });

  test('a field of the wrong type falls back instead of losing the entry',
      () async {
    nativeReturns(<dynamic>[
      <dynamic, dynamic>{
        'atMs': 1758300000000,
        'actionType': 7,
        'targetId': 9,
        'result': 3,
        'httpCode': 'nope',
        'message': 'Survives anyway',
      },
    ]);

    final logs = await repository.drainBackgroundLogs();

    expect(logs, hasLength(1));
    expect(logs.single.actionType, 'legacy');
    expect(logs.single.targetId, isNull);
    expect(logs.single.result, LogResult.info);
    expect(logs.single.httpCode, isNull);
  });

  test('a PlatformException yields an empty list rather than throwing',
      () async {
    nativeThrows(PlatformException(code: 'error'));

    await expectLater(repository.drainBackgroundLogs(), completion(isEmpty));
  });

  test('an older native half without the method yields an empty list',
      () async {
    nativeThrows(MissingPluginException('no drainBackgroundLogs'));

    await expectLater(repository.drainBackgroundLogs(), completion(isEmpty));
  });

  test('no buffered events is an empty list', () async {
    nativeReturns(<dynamic>[]);

    expect(await repository.drainBackgroundLogs(), isEmpty);
  });
}
