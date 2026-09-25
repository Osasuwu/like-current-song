import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:like_spotify_mobile_app/data/likes/google_sheets_like_count_repository.dart';
import 'package:like_spotify_mobile_app/data/likes/shared_prefs_like_count_repository.dart';
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
        // The local fallback is the native store in the app; here it is the
        // preferences-backed one, which a unit test can actually run.
        localCounts: SharedPrefsLikeCountRepository(),
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

  group('one pair, one row (#193)', () {
    /// A sheet whose contents the test can change between reads, and which
    /// answers an append with the row it landed on — the next one down.
    ({http.Client client, List<http.Request> requests, List<List<String>> rows})
        liveSheet(
      List<List<String>> initialRows, {
      bool appendReportsRow = true,
    }) {
      final rows = <List<String>>[...initialRows];
      final requests = <http.Request>[];
      return (
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') return http.Response(sheetBody(rows), 200);
          if (request.method == 'POST') {
            final appended =
                (jsonDecode(request.body)['values'] as List).single as List;
            rows.add(appended.map((cell) => '$cell').toList());
            if (!appendReportsRow) return http.Response('{}', 200);
            // Header is row 1, so the row just added is `rows.length + 1`.
            final at = rows.length + 1;
            return http.Response(
              jsonEncode(<String, dynamic>{
                'updates': <String, dynamic>{'updatedRange': 'Likes!A$at:E$at'},
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
        requests: requests,
        rows: rows,
      );
    }

    test('a row the other half added after the cache loaded is not duplicated',
        () async {
      final spy = liveSheet(<List<String>>[]);
      final repo = repoOver(spy.client);

      // Some other track loads the cache; `track-1` is not in it.
      expect(await repo.incrementTrackLikeCount('track-0'), 1);

      // The Kotlin background half counts a like for `track-1` while the app
      // is open: a row appears that the Dart cache has never seen.
      spy.rows.add(
        <String>['user-1', 'track-1', '1', 'FALSE', '2026-01-01T00:00:00Z'],
      );

      expect(await repo.incrementTrackLikeCount('track-1'), 2);
      expect(
        spy.rows.where((r) => r[0] == 'user-1' && r[1] == 'track-1'),
        hasLength(1),
        reason: 'the sheet already had a row for the pair, so it must be '
            'updated rather than appended a second time',
      );
    });

    test('two likes for one track at once append a single row', () async {
      final spy = liveSheet(<List<String>>[]);
      final repo = repoOver(spy.client);

      // Two presses close enough together that neither has finished before
      // the other starts — a double press, or a queued like flushing while a
      // live one is in flight.
      final counts = await Future.wait(<Future<int>>[
        repo.incrementTrackLikeCount('track-1'),
        repo.incrementTrackLikeCount('track-1'),
      ]);

      expect(
        spy.rows.where((r) => r[0] == 'user-1' && r[1] == 'track-1'),
        hasLength(1),
        reason: 'both presses are the same pair, so they share one row',
      );
      expect(counts..sort(), <int>[1, 2]);
    });

    test('a pair that already has two rows keeps counting on the first',
        () async {
      // Sheets that already went wrong before the fix: the rule is that the
      // topmost row wins, so both halves agree which one to add to.
      final spy = liveSheet(<List<String>>[
        <String>['user-1', 'track-1', '1', 'FALSE', '2026-01-01T00:00:00Z'],
        <String>['user-1', 'track-1', '1', 'FALSE', '2026-01-02T00:00:00Z'],
      ]);
      final repo = repoOver(spy.client);

      expect(await repo.incrementTrackLikeCount('track-1'), 2);
      // The first data row is sheet row 2.
      expect(
        spy.requests.map((r) => r.url.path),
        contains('/v4/spreadsheets/sheet-1/values/Likes!C2'),
      );
      expect(spy.requests.where((r) => r.method == 'POST'), isEmpty);

      // It is said out loud once, with the rows to merge — a split count that
      // nothing reports is the part of #193 that never gets noticed.
      expect(logs, hasLength(1));
      expect(logs.single.result, LogResult.info);
      expect(logs.single.targetId, 'track-1');
      expect(logs.single.message, contains('rows 2 and 3'));

      // …and not again on the next like of the same track.
      expect(await repo.incrementTrackLikeCount('track-1'), 3);
      expect(logs, hasLength(1));
    });

    test('an append whose row is unreadable is looked up again, not repeated',
        () async {
      // The sheet took the append but its reply says nothing about where the
      // row landed, so the repository has no row number to remember.
      final spy = liveSheet(<List<String>>[], appendReportsRow: false);
      final repo = repoOver(spy.client);

      expect(await repo.incrementTrackLikeCount('track-1'), 1);
      expect(await repo.incrementTrackLikeCount('track-1'), 2);
      expect(
        spy.rows.where((r) => r[0] == 'user-1' && r[1] == 'track-1'),
        hasLength(1),
      );
    });
  });

  group('follow-artist counts distinct tracks on the shared sheet (#209)', () {
    /// The `ArtistTracks` tab as either half writes it.
    String artistBody(List<List<String>> dataRows) =>
        jsonEncode(<String, dynamic>{
          'range': 'ArtistTracks!A1:D1000',
          'values': <List<String>>[
            <String>['user_id', 'artist_id', 'track_id', 'created_at'],
            ...dataRows,
          ],
        });

    /// A sheet whose `ArtistTracks` tab holds [rows] and grows on append.
    ({http.Client client, List<http.Request> requests}) artistSheet(
      List<List<String>> rows,
    ) =>
        recordingClient((request) {
          if (request.method == 'GET') {
            return http.Response(artistBody(rows), 200);
          }
          final row = (jsonDecode(request.body)['values'] as List).single
              as List;
          rows.add(row.map((cell) => '$cell').toList());
          return http.Response('{}', 200);
        });

    test('a new track by the artist is recorded and counted', () async {
      final rows = <List<String>>[
        <String>['user-1', 'artist-1', 'track-a', '2026-09-01T00:00:00Z'],
      ];
      final spy = artistSheet(rows);
      final repo = repoOver(spy.client);

      expect(
        await repo.incrementArtistLikeCount('artist-1', trackId: 'track-b'),
        2,
      );
      final append = spy.requests.last;
      expect(append.method, 'POST');
      expect(
        append.url.path,
        '/v4/spreadsheets/sheet-1/values/ArtistTracks:append',
      );
      expect(rows.last.take(3), <String>['user-1', 'artist-1', 'track-b']);
      expect(logs, isEmpty);
    });

    test('a track already on the tab counts once and writes nothing',
        () async {
      final spy = artistSheet(<List<String>>[
        <String>['user-1', 'artist-1', 'track-a', '2026-09-01T00:00:00Z'],
      ]);
      final repo = repoOver(spy.client);

      expect(
        await repo.incrementArtistLikeCount('artist-1', trackId: 'track-a'),
        1,
      );
      expect(spy.requests.where((r) => r.method != 'GET'), isEmpty);
    });

    test('tracks liked at the computer count toward the phone', () async {
      // The desktop wrote two tracks, and once the same triple twice: two
      // devices appending the same pair counts it once, as the desktop does.
      final spy = artistSheet(<List<String>>[
        <String>['user-1', 'artist-1', 'track-a', '2026-09-01T00:00:00Z'],
        <String>['user-1', 'artist-1', 'track-b', '2026-09-02T00:00:00Z'],
        <String>['user-1', 'artist-1', 'track-b', '2026-09-03T00:00:00Z'],
        <String>['user-2', 'artist-1', 'track-c', '2026-09-03T00:00:00Z'],
        <String>['user-1', 'artist-2', 'track-d', '2026-09-03T00:00:00Z'],
      ]);
      final repo = repoOver(spy.client);

      // The local tally has never seen this artist; the sheet has.
      expect(
        await repo.incrementArtistLikeCount('artist-1', trackId: 'track-e'),
        3,
      );
    });

    test('the local tally moves either way, for the Stats screen', () async {
      final spy = artistSheet(<List<String>>[]);
      final repo = repoOver(spy.client);

      await repo.incrementArtistLikeCount('artist-1', trackId: 'track-a');
      await repo.incrementArtistLikeCount('artist-1', trackId: 'track-a');
      expect(await repo.getArtistLikeCount('artist-1'), 2);
    });

    test('without a track — follow-artist off — the sheet is not asked',
        () async {
      final spy = artistSheet(<List<String>>[]);
      final repo = repoOver(spy.client);

      expect(await repo.incrementArtistLikeCount('artist-1'), 1);
      expect(await repo.incrementArtistLikeCount('artist-1'), 2);
      expect(spy.requests, isEmpty);
    });

    test('no spreadsheet means the count stays on this device, silently',
        () async {
      final spy = artistSheet(<List<String>>[]);
      final repo = repoOver(spy.client, spreadsheetId: '');

      expect(
        await repo.incrementArtistLikeCount('artist-1', trackId: 'track-a'),
        1,
      );
      expect(spy.requests, isEmpty);
      expect(logs, isEmpty);
    });

    test('a sheet without the tab falls back and names the missing tab',
        () async {
      final spy = recordingClient(
        (_) => http.Response('{"error":{"code":400}}', 400),
      );
      final repo = repoOver(spy.client);

      expect(
        await repo.incrementArtistLikeCount('artist-1', trackId: 'track-a'),
        1,
      );
      expect(logs, hasLength(1));
      final log = logs.single;
      expect(
        log.actionType,
        GoogleSheetsLikeCountRepository.artistLogActionType,
      );
      expect(log.targetId, 'artist-1');
      expect(log.result, LogResult.failure);
      expect(log.httpCode, 400);
      expect(
        log.message,
        startsWith('Artist like counted on this device only.'),
      );
      expect(log.message, contains('no ArtistTracks tab'));
    });

    test('a refused append falls back to the local tally', () async {
      final spy = recordingClient((request) => request.method == 'GET'
          ? http.Response(artistBody(<List<String>>[]), 200)
          : http.Response('nope', 500));
      final repo = repoOver(spy.client);

      expect(
        await repo.incrementArtistLikeCount('artist-1', trackId: 'track-a'),
        1,
      );
      expect(logs.single.httpCode, 500);
    });
  });

  group('artistTrackTally', () {
    List<List<String>> tab(List<List<String>> rows) => <List<String>>[
          <String>['user_id', 'artist_id', 'track_id', 'created_at'],
          ...rows,
        ];

    test('skips the header and rows too short to hold a triple', () {
      final tally = GoogleSheetsLikeCountRepository.artistTrackTally(
        <Object>[
          ...tab(<List<String>>[
            <String>['user-1', 'artist-1'],
            <String>['user-1', 'artist-1', 'track-a'],
          ]),
          'not a row',
        ],
        'user-1',
        'artist-1',
        'track-a',
      );
      expect(tally.seen, isTrue);
      expect(tally.count, 1);
    });

    test('an unreadable tab is an empty one', () {
      final tally = GoogleSheetsLikeCountRepository.artistTrackTally(
        null,
        'user-1',
        'artist-1',
        'track-a',
      );
      expect(tally.seen, isFalse);
      expect(tally.count, 0);
    });
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
