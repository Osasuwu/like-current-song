import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:like_spotify_mobile_app/data/likes/counter_sheet_schema.dart';
import 'package:like_spotify_mobile_app/data/likes/counter_spreadsheet_creator.dart';

void main() {
  // The schema the app must write, spelled out rather than read from
  // [CounterSheetSchema]: a test that asked the code what it does would agree
  // with any change to it. `tests/test_counter_schema_parity.py` holds the
  // other two halves to the same literals.
  const likesHeader = <String>[
    'user_id',
    'track_id',
    'count',
    'backfilled',
    'updated_at',
  ];
  const artistHeader = <String>[
    'user_id',
    'artist_id',
    'track_id',
    'created_at',
  ];

  List<String> headerOf(Map<String, dynamic> tab) => <String>[
        for (final cell
            in (tab['data'] as List).first['rowData'].first['values'] as List)
          cell['userEnteredValue']['stringValue'] as String,
      ];

  group('schema', () {
    test('the tabs and headers are the ones all three halves agree on', () {
      expect(CounterSheetSchema.likesTab, 'Likes');
      expect(CounterSheetSchema.likesHeader, likesHeader);
      expect(CounterSheetSchema.artistTracksTab, 'ArtistTracks');
      expect(CounterSheetSchema.artistTracksHeader, artistHeader);
    });

    test('the written columns are derived from the header, not guessed', () {
      expect(CounterSheetSchema.countColumn, 'C');
      expect(CounterSheetSchema.updatedAtColumn, 'E');
      expect(
        CounterSheetSchema.columnOf(<String>['a', 'b', 'c'], 'c'),
        'C',
      );
      expect(
        () => CounterSheetSchema.columnOf(<String>['a'], 'missing'),
        throwsArgumentError,
      );
    });
  });

  group('request body', () {
    final body = CounterSpreadsheetCreator.requestBody();
    final sheets = body['sheets'] as List;

    test('names the spreadsheet', () {
      expect(body['properties'], <String, dynamic>{
        'title': 'Like Current Song counters',
      });
    });

    test('creates both tabs, Likes first', () {
      expect(
        <dynamic>[for (final sheet in sheets) sheet['properties']['title']],
        <String>['Likes', 'ArtistTracks'],
      );
    });

    test('types both header rows, in order, starting at A1', () {
      expect(headerOf(sheets[0] as Map<String, dynamic>), likesHeader);
      expect(headerOf(sheets[1] as Map<String, dynamic>), artistHeader);
      for (final sheet in sheets) {
        final data = (sheet['data'] as List).single as Map<String, dynamic>;
        expect(data['startRow'], 0);
        expect(data['startColumn'], 0);
        expect((data['rowData'] as List).length, 1);
      }
    });
  });

  group('create', () {
    test('posts once to the create endpoint and answers the id', () async {
      final requests = <http.Request>[];
      final creator = CounterSpreadsheetCreator(
        readAccessToken: () async => 'access-token',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'spreadsheetId': 'made-up-id',
              'spreadsheetUrl': 'https://example.test/made-up-id',
            }),
            200,
          );
        }),
      );

      final created = await creator.create();

      expect(created.spreadsheetId, 'made-up-id');
      expect(created.url, 'https://example.test/made-up-id');
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://sheets.googleapis.com/v4/spreadsheets',
      );
      expect(request.headers['Authorization'], 'Bearer access-token');
      expect(
        jsonDecode(request.body),
        jsonDecode(jsonEncode(CounterSpreadsheetCreator.requestBody())),
      );
    });

    test('a reply without a url still gives back the id', () async {
      final creator = CounterSpreadsheetCreator(
        readAccessToken: () async => 'access-token',
        httpClient: MockClient(
          (_) async => http.Response('{"spreadsheetId":"only-id"}', 200),
        ),
      );

      final created = await creator.create();

      expect(created.spreadsheetId, 'only-id');
      expect(created.url, isNull);
    });

    test('says to sign in rather than calling Google without a token',
        () async {
      final requests = <http.Request>[];
      final creator = CounterSpreadsheetCreator(
        readAccessToken: () async => null,
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        creator.create(),
        throwsA(
          isA<CounterSpreadsheetException>().having(
            (error) => error.message,
            'message',
            contains('Sign in'),
          ),
        ),
      );
      expect(requests, isEmpty);
    });

    test('a refusal from Google is reported, not swallowed', () async {
      final creator = CounterSpreadsheetCreator(
        readAccessToken: () async => 'access-token',
        httpClient: MockClient(
          (_) async => http.Response('{"error":{"message":"nope"}}', 403),
        ),
      );

      await expectLater(
        creator.create(),
        throwsA(
          isA<CounterSpreadsheetException>()
              .having(
                (error) => error.message,
                'message',
                allOf(contains('403'), contains('nope')),
              )
              // A 403 the body does not explain is not a disabled API, so
              // there is no page to offer and the card must not draw a button.
              .having((error) => error.activationUrl, 'activationUrl', isNull),
        ),
      );
    });

    test('a project with the Sheets API off is told so, and where', () async {
      // The likely first run: an OAuth client exists but the API was never
      // switched on, and the button used to answer with a 403 and raw JSON
      // (#165). The URL comes out separately so the card can offer a button.
      final creator = CounterSpreadsheetCreator(
        readAccessToken: () async => 'access-token',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode(<String, dynamic>{
              'error': <String, dynamic>{
                'code': 403,
                'message': 'Google Sheets API has not been used in project '
                    '123456789 before or it is disabled.',
                'details': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'reason': 'SERVICE_DISABLED',
                    'metadata': <String, dynamic>{
                      'consumer': 'projects/123456789',
                      'activationUrl': 'https://example.test/enable',
                    },
                  },
                ],
              },
            }),
            403,
          ),
        ),
      );

      await expectLater(
        creator.create(),
        throwsA(
          isA<CounterSpreadsheetException>()
              .having(
                (error) => error.message,
                'message',
                allOf(
                  contains('Google Sheets API is not enabled'),
                  contains('123456789'),
                  isNot(contains('403')),
                ),
              )
              .having(
                (error) => error.activationUrl,
                'activationUrl',
                'https://example.test/enable',
              ),
        ),
      );
    });

    test('a 2xx with no id is a failure, not a spreadsheet named ""', () async {
      final creator = CounterSpreadsheetCreator(
        readAccessToken: () async => 'access-token',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );

      await expectLater(
        creator.create(),
        throwsA(isA<CounterSpreadsheetException>()),
      );
    });
  });
}
