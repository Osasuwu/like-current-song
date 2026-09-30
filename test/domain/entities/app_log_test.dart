import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';

void main() {
  group('AppLog', () {
    group('toLine', () {
      test('writes every field as one JSON object', () {
        final log = AppLog(
          at: DateTime.utc(2026, 4, 6, 10, 0, 1),
          actionType: 'like',
          targetId: 'trk1',
          result: LogResult.failure,
          httpCode: 429,
          message: 'Rate limited\nretry later',
        );

        expect(
          log.toLine(),
          equals(
            '{"at":"2026-04-06T10:00:01.000Z","actionType":"like",'
            '"targetId":"trk1","result":"failure","httpCode":429,'
            r'"message":"Rate limited\nretry later"}',
          ),
        );
      });

      test('leaves out targetId and httpCode when they are null', () {
        final log = AppLog(
          at: DateTime.utc(2026, 4, 6, 10, 0, 1),
          message: 'Started',
        );

        expect(
          log.toLine(),
          equals(
            '{"at":"2026-04-06T10:00:01.000Z","actionType":"legacy",'
            '"result":"info","message":"Started"}',
          ),
        );
      });
    });

    group('fromLine', () {
      test('reads back every field of a stored line', () {
        final log = AppLog.fromLine(
          '{"at":"2026-04-06T10:00:01.000Z","actionType":"like",'
          '"targetId":"trk1","result":"failure","httpCode":429,'
          r'"message":"Rate limited\nretry later"}',
        );

        expect(log.at, equals(DateTime.utc(2026, 4, 6, 10, 0, 1)));
        expect(log.actionType, equals('like'));
        expect(log.targetId, equals('trk1'));
        expect(log.result, equals(LogResult.failure));
        expect(log.httpCode, equals(429));
        expect(log.message, equals('Rate limited\nretry later'));
      });

      test('fills defaults for keys an older version did not write', () {
        final log = AppLog.fromLine('{"at":"2026-04-06T10:00:01.000Z"}');

        expect(log.at, equals(DateTime.utc(2026, 4, 6, 10, 0, 1)));
        expect(log.actionType, equals('legacy'));
        expect(log.targetId, isNull);
        expect(log.result, equals(LogResult.info));
        expect(log.httpCode, isNull);
        expect(log.message, equals(''));
      });

      test('reads an unknown result name as info', () {
        final log = AppLog.fromLine(
          '{"at":"2026-04-06T10:00:01.000Z","result":"partial","message":"m"}',
        );

        expect(log.result, equals(LogResult.info));
      });

      test('keeps a plain-text line from before JSON logs as the message', () {
        final log = AppLog.fromLine('10:00 liked track trk1');

        expect(log.actionType, equals('legacy'));
        expect(log.result, equals(LogResult.info));
        expect(log.message, equals('10:00 liked track trk1'));
      });

      test('keeps a line that is JSON but not an object as the message', () {
        final log = AppLog.fromLine('[1,2]');

        expect(log.actionType, equals('legacy'));
        expect(log.message, equals('[1,2]'));
      });
    });
  });
}
