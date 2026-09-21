import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:like_spotify_mobile_app/data/likes/google_sheets_like_count_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Everything the repository put on the Logs screen this test.
  final logs = <AppLog>[];

  setUp(() {
    logs.clear();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// The tab as the desktop half writes it: one header row, then data.
  String sheetBody(List<List<String>> dataRows) => jsonEncode(<String, dynamic>{
        'range': 'Likes!A1:E1000',
        'values': <List<String>>[
          <String>['user_id', 'track_id', 'count', 'backfilled', 'updated_at'],
          ...dataRows,
        ],
      });

  /// Records every call the repository makes and answers [reply]; anything the
  /// reply does not cover comes back as an empty 200, which is enough for the
  /// `values.update` calls that the repository only checks the status of.
  ({http.Client client, List<http.Request> requests}) recordingClient(
    http.Response Function(http.Request request) reply,
  ) {
    final requests = <http.Request>[];
    return (
      client: MockClient((request) async {
        requests.add(request);
        return reply(request);
      }),
      requests: requests,
    );
  }

  GoogleSheetsLikeCountRepository repoOver(
    http.Client client, {
    String spreadsheetId = 'sheet-1',
    String? token = 'access-token',
    String? userId = 'user-1',
    Future<String> Function()? readSpreadsheetId,
    Future<String?> Function()? readAccessToken,
    Future<String?> Function()? userIdGetter,
    Future<void> Function(AppLog log)? appendLog,
  }) =>
      GoogleSheetsLikeCountRepository(
        readSpreadsheetId: readSpreadsheetId ?? () async => spreadsheetId,
        readAccessToken: readAccessToken ?? () async => token,
        userIdGetter: userIdGetter ?? () async => userId,
        appendLog: appendLog ?? ((log) async => logs.add(log)),
        httpClient: client,
      );

  test('no spreadsheet means the count stays on this device', () async {
    final spy = recordingClient((_) => http.Response('{}', 200));
    final repo = repoOver(spy.client, spreadsheetId: '');

    expect(await repo.incrementTrackLikeCount('track-1'), 1);
    expect(await repo.incrementTrackLikeCount('track-1'), 2);
    expect(spy.requests, isEmpty);
    // No counter is configured, so there is nothing to report: logging here
    // would nag everyone who never wanted a shared count.
    expect(logs, isEmpty);
  });

  test('a sheet that will not answer counts locally', () async {
    final spy = recordingClient((_) => http.Response('nope', 500));
    final repo = repoOver(spy.client);

    expect(await repo.incrementTrackLikeCount('track-1'), 1);
    expect(await repo.incrementTrackLikeCount('track-1'), 2);
    // Each press retries the sheet: the cache was dropped on the failure.
    expect(spy.requests, hasLength(2));
  });

  group('a like the sheet did not record says so on the Logs screen', () {
    /// Every branch below ends the same way: the like is counted on this
    /// device, and the Logs screen carries one failure line naming the track.
    AppLog soleFailure() {
      expect(logs, hasLength(1));
      final log = logs.single;
      expect(log.actionType, GoogleSheetsLikeCountRepository.logActionType);
      expect(log.targetId, 'track-1');
      expect(log.result, LogResult.failure);
      expect(log.message, startsWith('Like counted on this device only.'));
      return log;
    }

    test('when the spreadsheet id cannot be read', () async {
      final spy = recordingClient((_) => http.Response('{}', 200));
      final repo = repoOver(
        spy.client,
        readSpreadsheetId: () async => throw Exception('prefs unavailable'),
      );

      expect(await repo.incrementTrackLikeCount('track-1'), 1);
      expect(spy.requests, isEmpty);
      expect(soleFailure().message, contains('prefs unavailable'));
    });

    test('when there is no music-service account to count under', () async {
      // The silent branch of #163/#164: a counter that had never worked was
      // indistinguishable from one that had nothing to do.
      final spy = recordingClient((_) => http.Response('{}', 200));
      final repo = repoOver(spy.client, userId: null);

      expect(await repo.incrementTrackLikeCount('track-1'), 1);
      expect(spy.requests, isEmpty);
      expect(soleFailure().message, contains('Connected services'));
    });

    test('when resolving that account throws', () async {
      final spy = recordingClient((_) => http.Response('{}', 200));
      final repo = repoOver(
        spy.client,
        userIdGetter: () async => throw Exception('Spotify unreachable'),
      );

      expect(await repo.incrementTrackLikeCount('track-1'), 1);
      expect(soleFailure().message, contains('Spotify unreachable'));
    });

    test('when the counter is not signed in to Google', () async {
      final spy = recordingClient((_) => http.Response('{}', 200));
      final repo = repoOver(spy.client, token: null);

      expect(await repo.incrementTrackLikeCount('track-1'), 1);
      expect(spy.requests, isEmpty);
      expect(soleFailure().message, contains('Sign in under Connected'));
    });

    test('when the Google sign-in cannot be read', () async {
      final spy = recordingClient((_) => http.Response('{}', 200));
      final repo = repoOver(
        spy.client,
        readAccessToken: () async => throw Exception('keystore locked'),
      );

      expect(await repo.incrementTrackLikeCount('track-1'), 1);
      expect(spy.requests, isEmpty);
      expect(soleFailure().message, contains('keystore locked'));
    });

    test('when the sheet refuses the call, with its status code', () async {
      final spy = recordingClient((_) => http.Response('nope', 500));
      final repo = repoOver(spy.client);

      expect(await repo.incrementTrackLikeCount('track-1'), 1);
      expect(soleFailure().httpCode, 500);
    });

    test('and a refusal the user can clear names the fix, not the JSON',
        () async {
      final spy = recordingClient(
        (_) => http.Response(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{
              'code': 403,
              'message': 'Google Sheets API has not been used in project 42.',
              'details': <Map<String, dynamic>>[
                <String, dynamic>{
                  'reason': 'SERVICE_DISABLED',
                  'metadata': <String, String>{
                    'consumer': 'projects/42',
                    'activationUrl': 'https://console.example/enable',
                  },
                },
              ],
            },
          }),
          403,
        ),
      );
      final repo = repoOver(spy.client);

      expect(await repo.incrementTrackLikeCount('track-1'), 1);
      final log = soleFailure();
      expect(log.httpCode, 403);
      expect(log.message, contains('Google Sheets API is not enabled'));
      expect(log.message, contains('https://console.example/enable'));
      expect(log.message, isNot(contains('SERVICE_DISABLED')));
    });

    test('and a log that itself fails still leaves the like counted',
        () async {
      final spy = recordingClient((_) => http.Response('nope', 500));
      final repo = repoOver(
        spy.client,
        appendLog: (_) async => throw Exception('log full'),
      );

      expect(await repo.incrementTrackLikeCount('track-1'), 1);
    });
  });

  test('a pair the sheet already has updates that row, and only it', () async {
    final spy = recordingClient((request) {
      if (request.method == 'GET') {
        return http.Response(
          sheetBody(<List<String>>[
            <String>['user-1', 'track-0', '9', 'FALSE', '2026-01-01T00:00:00Z'],
            <String>['user-1', 'track-1', '4', 'TRUE', '2026-01-01T00:00:00Z'],
          ]),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    final repo = repoOver(spy.client);

    expect(await repo.incrementTrackLikeCount('track-1'), 5);

    expect(spy.requests.map((r) => r.method), <String>['GET', 'PUT', 'PUT']);
    // `track-1` is the second data row, so row 3 of the tab.
    final count = spy.requests[1];
    expect(count.url.path, '/v4/spreadsheets/sheet-1/values/Likes!C3');
    expect(count.url.queryParameters['valueInputOption'], 'RAW');
    expect(count.headers['Authorization'], 'Bearer access-token');
    expect(jsonDecode(count.body), <String, dynamic>{
      'values': <List<dynamic>>[
        <dynamic>[5]
      ],
    });

    final stamp = spy.requests[2];
    expect(stamp.url.path, '/v4/spreadsheets/sheet-1/values/Likes!E3');
    final written =
        (jsonDecode(stamp.body)['values'] as List).single as List<dynamic>;
    expect(
      written.single,
      matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')),
    );

    // Column D is never named, so `backfilled` keeps whatever it held.
    expect(
      spy.requests.where((r) => r.url.path.endsWith('D3')),
      isEmpty,
    );
  });

  test('a pair the sheet has never seen is appended', () async {
    final spy = recordingClient((request) {
      if (request.method == 'GET') {
        return http.Response(sheetBody(<List<String>>[]), 200);
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'updates': <String, dynamic>{'updatedRange': 'Likes!A2:E2'},
        }),
        200,
      );
    });
    final repo = repoOver(spy.client);

    expect(await repo.incrementTrackLikeCount('track-1'), 1);

    final append = spy.requests.last;
    expect(append.method, 'POST');
    expect(append.url.path, '/v4/spreadsheets/sheet-1/values/Likes:append');
    expect(append.url.queryParameters, <String, String>{
      'valueInputOption': 'RAW',
      'insertDataOption': 'INSERT_ROWS',
    });
    final row = (jsonDecode(append.body)['values'] as List).single as List;
    expect(row[0], 'user-1');
    expect(row[1], 'track-1');
    expect(row[2], 1);
    expect(row[3], 'FALSE');

    // The appended row is remembered, so the next press updates rather than
    // appending a second copy of the same pair.
    expect(await repo.incrementTrackLikeCount('track-1'), 2);
    expect(spy.requests.last.url.path, '/v4/spreadsheets/sheet-1/values/Likes!E2');
  });

  test('a song the service had already liked starts at 2, backfilled',
      () async {
    final spy = recordingClient((request) {
      if (request.method == 'GET') {
        return http.Response(sheetBody(<List<String>>[]), 200);
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'updates': <String, dynamic>{'updatedRange': 'Likes!A2:E2'},
        }),
        200,
      );
    });
    final repo = repoOver(spy.client);

    expect(
      await repo.incrementTrackLikeCount('track-1', wasAlreadyLiked: true),
      2,
    );

    final row = (jsonDecode(spy.requests.last.body)['values'] as List).single
        as List;
    expect(row[2], 2);
    expect(row[3], 'TRUE');
  });

  test('an append whose range cannot be read does not lose the like', () async {
    final spy = recordingClient((request) {
      if (request.method == 'GET') {
        return http.Response(sheetBody(<List<String>>[]), 200);
      }
      return http.Response('{}', 200);
    });
    final repo = repoOver(spy.client);

    expect(await repo.incrementTrackLikeCount('track-1'), 1);
  });

  group('rowFromA1Range', () {
    test('reads the row an append landed on', () {
      expect(
        GoogleSheetsLikeCountRepository.rowFromA1Range('Likes!A12:E12'),
        12,
      );
      expect(GoogleSheetsLikeCountRepository.rowFromA1Range('Likes!A7:E7'), 7);
    });

    test('a range with no row is zero', () {
      expect(GoogleSheetsLikeCountRepository.rowFromA1Range(''), 0);
      expect(GoogleSheetsLikeCountRepository.rowFromA1Range('Likes'), 0);
    });
  });
}
