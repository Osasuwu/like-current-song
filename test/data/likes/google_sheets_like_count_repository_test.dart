import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:like_spotify_mobile_app/data/likes/google_sheets_like_count_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

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
  }) =>
      GoogleSheetsLikeCountRepository(
        readSpreadsheetId: () async => spreadsheetId,
        readAccessToken: () async => token,
        userIdGetter: () => userId,
        httpClient: client,
      );

  test('no spreadsheet means the count stays on this device', () async {
    final spy = recordingClient((_) => http.Response('{}', 200));
    final repo = repoOver(spy.client, spreadsheetId: '');

    expect(await repo.incrementTrackLikeCount('track-1'), 1);
    expect(await repo.incrementTrackLikeCount('track-1'), 2);
    expect(spy.requests, isEmpty);
  });

  test('a sheet nobody is signed in to counts locally', () async {
    final spy = recordingClient((_) => http.Response('{}', 200));
    final repo = repoOver(spy.client, token: null);

    expect(await repo.incrementTrackLikeCount('track-1'), 1);
    expect(spy.requests, isEmpty);
  });

  test('a sheet that will not answer counts locally', () async {
    final spy = recordingClient((_) => http.Response('nope', 500));
    final repo = repoOver(spy.client);

    expect(await repo.incrementTrackLikeCount('track-1'), 1);
    expect(await repo.incrementTrackLikeCount('track-1'), 2);
    // Each press retries the sheet: the cache was dropped on the failure.
    expect(spy.requests, hasLength(2));
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
