import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/likes/sheets_api_error.dart';

void main() {
  // The bodies Google actually sends, typed out here rather than built from
  // the code under test: a test that asked the parser what a refusal looks
  // like would agree with any change to it. `tests/test_sheets_api_disabled.py`
  // holds the desktop twin to the same literals.
  const activationUrl =
      'https://console.developers.google.com/apis/api/sheets.googleapis.com/'
      'overview?project=123456789';
  const prose =
      'Google Sheets API has not been used in project 123456789 before or it '
      'is disabled. Enable it by visiting $activationUrl then retry. If you '
      'enabled this API recently, wait a few minutes.';

  // What the API sends today: a `google.rpc.ErrorInfo` among `error.details`.
  final currentShape = jsonEncode(<String, dynamic>{
    'error': <String, dynamic>{
      'code': 403,
      'message': prose,
      'status': 'PERMISSION_DENIED',
      'details': <Map<String, dynamic>>[
        <String, dynamic>{
          '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
          'reason': 'SERVICE_DISABLED',
          'domain': 'googleapis.com',
          'metadata': <String, dynamic>{
            'consumer': 'projects/123456789',
            'service': 'sheets.googleapis.com',
            'activationUrl': activationUrl,
          },
        },
        <String, dynamic>{
          '@type': 'type.googleapis.com/google.rpc.LocalizedMessage',
          'locale': 'en-US',
          'message': prose,
        },
      ],
    },
  });

  // The older spelling, which carries the reason and nothing else — whatever
  // it can say about the project and the URL is in the prose.
  final oldShape = jsonEncode(<String, dynamic>{
    'error': <String, dynamic>{
      'code': 403,
      'message': 'Access Not Configured. $prose',
      'errors': <Map<String, dynamic>>[
        <String, dynamic>{
          'domain': 'usageLimits',
          'reason': 'accessNotConfigured',
          'message': 'Access Not Configured. $prose',
        },
      ],
    },
  });

  group('reading the refusal', () {
    test('the current shape names the page that fixes it', () {
      final read = SheetsApiDisabled.read(403, currentShape);

      expect(read, isNotNull);
      expect(read!.activationUrl, activationUrl);
      expect(read.project, '123456789');
      // The status code was never the point; the URL and the project are.
      expect(read.message, contains('Google Sheets API is not enabled'));
      expect(read.message, contains(activationUrl));
      expect(read.message, contains('123456789'));
    });

    test('the old shape is read too', () {
      final read = SheetsApiDisabled.read(403, oldShape);

      expect(read, isNotNull);
      // Nothing in this shape holds the URL as a field, so it comes out of
      // the prose.
      expect(read!.activationUrl, activationUrl);
      expect(read.project, '123456789');
    });

    test('a url that ends the sentence keeps no full stop', () {
      // A link with a stray "." on the end is a 404 for whoever taps it.
      final body = jsonEncode(<String, dynamic>{
        'error': <String, dynamic>{
          'message': 'Enable it by visiting $activationUrl.',
          'errors': <Map<String, dynamic>>[
            <String, dynamic>{'reason': 'accessNotConfigured'},
          ],
        },
      });

      expect(SheetsApiDisabled.read(403, body)!.activationUrl, activationUrl);
    });

    test('a disabled reason without a url falls back to the library', () {
      final body = jsonEncode(<String, dynamic>{
        'error': <String, dynamic>{
          'message': 'nope',
          'details': <Map<String, dynamic>>[
            <String, dynamic>{'reason': 'SERVICE_DISABLED'},
          ],
        },
      });

      final read = SheetsApiDisabled.read(403, body);

      expect(read, isNotNull);
      expect(read!.activationUrl, sheetsApiLibraryUrl);
      expect(read.project, isNull);
      // Still a complete instruction, even with Google saying almost nothing.
      expect(read.message, contains('Google Sheets API is not enabled'));
    });

    test('the fallback is the library page, not the credentials one', () {
      // Two different pages: the credentials one makes OAuth clients and
      // cannot switch an API on, which is the whole of #165.
      expect(sheetsApiLibraryUrl, contains('/apis/library/'));
      expect(sheetsApiLibraryUrl, endsWith('sheets.googleapis.com'));
    });

    // Guessing "your API is off" at someone whose API is on would be worse
    // than the status code they used to get.
    for (final entry in <String, String>{
      'empty': '',
      'blank': '   ',
      'html': '<html>403 Forbidden</html>',
      'truncated': '{',
      'not an object': '[]',
      'error is a string': '{"error":"forbidden"}',
      'some other 403': '{"error":{"message":"Request had insufficient scopes."}}',
      'a reason we do not claim':
          '{"error":{"message":"revoked","details":[{"reason":"ACCESS_TOKEN_EXPIRED"}]}}',
    }.entries) {
      test('${entry.key} is left alone', () {
        expect(SheetsApiDisabled.read(403, entry.value), isNull);
      });
    }

    test('only a 403 is read this way', () {
      // A 404 or a 500 that happens to quote the same reason is a different
      // failure, and the caller's own branches already say so.
      expect(SheetsApiDisabled.read(404, currentShape), isNull);
      expect(SheetsApiDisabled.read(500, currentShape), isNull);
    });
  });
}
