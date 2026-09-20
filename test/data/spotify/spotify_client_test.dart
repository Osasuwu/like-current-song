import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_client.dart';
import 'package:http/http.dart' as http;

class MockHttpClient extends Mock implements http.Client {}

void main() {
  group('SpotifyClient', () {
    late MockHttpClient mockHttpClient;
    late SpotifyClient client;

    setUpAll(() {
      registerFallbackValue(Uri.parse('https://example.com'));
    });

    setUp(() {
      mockHttpClient = MockHttpClient();
      client = SpotifyClient(mockHttpClient);
      // The legacy-endpoint decision lives for the process lifetime, so it has
      // to be cleared between tests.
      SpotifyClient.resetLibraryEndpointCacheForTesting();
    });

    group('createCodeVerifier', () {
      test('returns string of default length 64', () {
        final verifier = client.createCodeVerifier();

        expect(verifier.length, equals(64));
      });

      test('returns string of custom length', () {
        final verifier = client.createCodeVerifier(length: 32);

        expect(verifier.length, equals(32));
      });

      test('contains only valid characters', () {
        final verifier = client.createCodeVerifier();
        const validChars =
            'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

        for (final char in verifier.split('')) {
          expect(validChars.contains(char), equals(true));
        }
      });

      test('generates different verifiers on each call', () {
        final verifier1 = client.createCodeVerifier();
        final verifier2 = client.createCodeVerifier();

        expect(verifier1, isNot(equals(verifier2)));
      });

      test('can generate custom length verifiers', () {
        final verifier128 = client.createCodeVerifier(length: 128);
        final verifier16 = client.createCodeVerifier(length: 16);

        expect(verifier128.length, equals(128));
        expect(verifier16.length, equals(16));
      });
    });

    group('codeChallenge', () {
      test('returns base64url encoded SHA256 hash without padding', () {
        const verifier = 'test_verifier_string';
        final challenge = client.codeChallenge(verifier);

        expect(challenge, isNotEmpty);
        expect(challenge.contains('='), equals(false));
      });

      test('produces deterministic output for same input', () {
        const verifier = 'test_verifier_string';
        final challenge1 = client.codeChallenge(verifier);
        final challenge2 = client.codeChallenge(verifier);

        expect(challenge1, equals(challenge2));
      });

      test('produces different output for different inputs', () {
        final challenge1 = client.codeChallenge('verifier_1');
        final challenge2 = client.codeChallenge('verifier_2');

        expect(challenge1, isNot(equals(challenge2)));
      });

      test('outputs are valid base64url characters', () {
        const verifier = 'test_verifier_string';
        final challenge = client.codeChallenge(verifier);
        final base64urlChars = RegExp(r'^[A-Za-z0-9\-_]*$');

        expect(base64urlChars.hasMatch(challenge), equals(true));
      });

      test('removes padding characters from base64', () {
        const verifier = 'short';
        final challenge = client.codeChallenge(verifier);

        expect(challenge.contains('='), equals(false));
      });
    });

    group('buildAuthorizeUri', () {
      test('includes client_id in query parameters', () {
        const clientId = 'test_client_id';
        final uri = client.buildAuthorizeUri(
          clientId: clientId,
          redirectUri: 'http://localhost:8888/callback',
          codeChallenge: 'test_challenge',
          state: 'test_state',
        );

        expect(uri.queryParameters['client_id'], equals(clientId));
      });

      test('includes response_type=code in query parameters', () {
        final uri = client.buildAuthorizeUri(
          clientId: 'client_id',
          redirectUri: 'http://localhost:8888/callback',
          codeChallenge: 'test_challenge',
          state: 'test_state',
        );

        expect(uri.queryParameters['response_type'], equals('code'));
      });

      test('includes redirect_uri in query parameters', () {
        const redirectUri = 'http://localhost:8888/callback';
        final uri = client.buildAuthorizeUri(
          clientId: 'client_id',
          redirectUri: redirectUri,
          codeChallenge: 'test_challenge',
          state: 'test_state',
        );

        expect(uri.queryParameters['redirect_uri'], equals(redirectUri));
      });

      test('includes code_challenge_method=S256', () {
        final uri = client.buildAuthorizeUri(
          clientId: 'client_id',
          redirectUri: 'http://localhost:8888/callback',
          codeChallenge: 'test_challenge',
          state: 'test_state',
        );

        expect(uri.queryParameters['code_challenge_method'], equals('S256'));
      });

      test('includes code_challenge in query parameters', () {
        const codeChallenge = 'test_code_challenge_value';
        final uri = client.buildAuthorizeUri(
          clientId: 'client_id',
          redirectUri: 'http://localhost:8888/callback',
          codeChallenge: codeChallenge,
          state: 'test_state',
        );

        expect(uri.queryParameters['code_challenge'], equals(codeChallenge));
      });

      test('includes state in query parameters', () {
        const state = 'test_state_value';
        final uri = client.buildAuthorizeUri(
          clientId: 'client_id',
          redirectUri: 'http://localhost:8888/callback',
          codeChallenge: 'test_challenge',
          state: state,
        );

        expect(uri.queryParameters['state'], equals(state));
      });

      test('includes scope with all required permissions', () {
        final uri = client.buildAuthorizeUri(
          clientId: 'client_id',
          redirectUri: 'http://localhost:8888/callback',
          codeChallenge: 'test_challenge',
          state: 'test_state',
        );

        final scope = uri.queryParameters['scope'];
        expect(scope, isNotNull);
        expect(scope, contains('user-library-modify'));
        expect(scope, contains('user-library-read'));
        expect(scope, contains('user-read-playback-state'));
        expect(scope, contains('playlist-modify-private'));
        expect(scope, contains('playlist-modify-public'));
      });
    });

    group('exchangeCode', () {
      test('successfully exchanges code for token on 200 response', () async {
        final responseBody =
            '{"access_token":"access_token_value","refresh_token":"refresh_token_value","expires_in":3600}';
        when(() => mockHttpClient.post(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response(responseBody, 200));

        final result = await client.exchangeCode(
          code: 'auth_code',
          clientId: 'client_id',
          redirectUri: 'http://localhost:8888/callback',
          codeVerifier: 'code_verifier',
        );

        expect(result.accessToken, equals('access_token_value'));
        expect(result.refreshToken, equals('refresh_token_value'));
        expect(result.expiresInSec, equals(3600));
      });

      test('throws exception on 400 response', () async {
        when(() => mockHttpClient.post(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response('Invalid code', 400));

        expect(
          () => client.exchangeCode(
            code: 'invalid_code',
            clientId: 'client_id',
            redirectUri: 'http://localhost:8888/callback',
            codeVerifier: 'code_verifier',
          ),
          throwsException,
        );
      });

      test('throws exception on 401 response', () async {
        when(() => mockHttpClient.post(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response('Unauthorized', 401));

        expect(
          () => client.exchangeCode(
            code: 'code',
            clientId: 'client_id',
            redirectUri: 'http://localhost:8888/callback',
            codeVerifier: 'code_verifier',
          ),
          throwsException,
        );
      });

      test('handles response with missing refresh_token', () async {
        final responseBody =
            '{"access_token":"access_token_value","expires_in":3600}';
        when(() => mockHttpClient.post(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response(responseBody, 200));

        final result = await client.exchangeCode(
          code: 'auth_code',
          clientId: 'client_id',
          redirectUri: 'http://localhost:8888/callback',
          codeVerifier: 'code_verifier',
        );

        expect(result.accessToken, equals('access_token_value'));
        expect(result.refreshToken, equals(''));
      });
    });

    group('refreshToken', () {
      test('successfully refreshes token on 200 response', () async {
        final responseBody =
            '{"access_token":"new_access_token","refresh_token":"new_refresh_token","expires_in":3600}';
        when(() => mockHttpClient.post(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response(responseBody, 200));

        final result = await client.refreshToken(
          refreshToken: 'old_refresh_token',
          clientId: 'client_id',
        );

        expect(result.accessToken, equals('new_access_token'));
        expect(result.refreshToken, equals('new_refresh_token'));
        expect(result.expiresInSec, equals(3600));
      });

      test('preserves refresh token if not in response', () async {
        const originalRefreshToken = 'original_refresh_token';
        final responseBody =
            '{"access_token":"new_access_token","expires_in":3600}';
        when(() => mockHttpClient.post(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response(responseBody, 200));

        final result = await client.refreshToken(
          refreshToken: originalRefreshToken,
          clientId: 'client_id',
        );

        expect(result.accessToken, equals('new_access_token'));
        expect(result.refreshToken, equals(originalRefreshToken));
      });

      test('throws exception on 400 response', () async {
        when(() => mockHttpClient.post(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer(
            (_) async => http.Response('Invalid refresh token', 400));

        expect(
          () => client.refreshToken(
            refreshToken: 'invalid_token',
            clientId: 'client_id',
          ),
          throwsException,
        );
      });

      test('throws exception on 401 response', () async {
        when(() => mockHttpClient.post(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response('Unauthorized', 401));

        expect(
          () => client.refreshToken(
            refreshToken: 'refresh_token',
            clientId: 'client_id',
          ),
          throwsException,
        );
      });
    });

    group('currentTrackId', () {
      test('returns null on 204 No Content response', () async {
        when(() => mockHttpClient.get(
              any(),
              headers: any(named: 'headers'),
            )).thenAnswer((_) async => http.Response('', 204));

        final result = await client.currentTrackId('access_token');

        expect(result, isNull);
      });

      test('returns track ID from 200 response with track', () async {
        final responseBody = '{"item":{"id":"track_id_123"}}';
        when(() => mockHttpClient.get(
              any(),
              headers: any(named: 'headers'),
            )).thenAnswer((_) async => http.Response(responseBody, 200));

        final result = await client.currentTrackId('access_token');

        expect(result, equals('track_id_123'));
      });

      test('returns null when item is null in response', () async {
        final responseBody = '{"item":null}';
        when(() => mockHttpClient.get(
              any(),
              headers: any(named: 'headers'),
            )).thenAnswer((_) async => http.Response(responseBody, 200));

        final result = await client.currentTrackId('access_token');

        expect(result, isNull);
      });

      test('throws exception on 401 Unauthorized response', () async {
        when(() => mockHttpClient.get(
              any(),
              headers: any(named: 'headers'),
            )).thenAnswer((_) async => http.Response('Unauthorized', 401));

        expect(
          () => client.currentTrackId('invalid_token'),
          throwsException,
        );
      });

      test('throws exception on 500 server error response', () async {
        when(() => mockHttpClient.get(
              any(),
              headers: any(named: 'headers'),
            )).thenAnswer((_) async => http.Response('Server error', 500));

        expect(
          () => client.currentTrackId('access_token'),
          throwsException,
        );
      });

      test('includes Authorization header with bearer token', () async {
        when(() => mockHttpClient.get(
              any(),
              headers: any(named: 'headers'),
            )).thenAnswer((_) async => http.Response('', 204));

        await client.currentTrackId('my_access_token');

        verify(() => mockHttpClient.get(
              any(),
              headers: {'Authorization': 'Bearer my_access_token'},
            )).called(1);
      });
    });

    group('likeTrack', () {
      test('successfully likes track on 200 response', () async {
        when(() => mockHttpClient.put(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response('', 200));

        await client.likeTrack(
          trackId: 'track_id_123',
          accessToken: 'access_token',
        );

        verify(() => mockHttpClient.put(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).called(1);
      });

      test('throws exception on 401 Unauthorized response', () async {
        when(() => mockHttpClient.put(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response('Unauthorized', 401));

        await expectLater(
          () => client.likeTrack(
            trackId: 'track_id',
            accessToken: 'invalid_token',
          ),
          throwsException,
        );

        // 401 is a token problem: it must surface, never trigger a retry.
        verify(() => mockHttpClient.put(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).called(1);
      });

      test('throws exception on 400 Bad Request response', () async {
        when(() => mockHttpClient.put(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response('Bad request', 400));

        await expectLater(
          () => client.likeTrack(
            trackId: 'invalid_id',
            accessToken: 'access_token',
          ),
          throwsException,
        );

        verify(() => mockHttpClient.put(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).called(1);
      });

      test('includes Authorization header with bearer token', () async {
        when(() => mockHttpClient.put(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            )).thenAnswer((_) async => http.Response('', 200));

        await client.likeTrack(
          trackId: 'track_id',
          accessToken: 'my_token',
        );

        verify(() => mockHttpClient.put(
              any(),
              headers: {
                'Authorization': 'Bearer my_token',
                'Content-Type': 'application/json',
              },
              body: any(named: 'body'),
            )).called(1);
      });

      test('sends the track URI to the generic /me/library endpoint', () async {
        final requests = _recordPuts(mockHttpClient, (_) => http.Response('', 200));

        await client.likeTrack(
          trackId: 'my_track_123',
          accessToken: 'token',
        );

        expect(requests, hasLength(1));
        expect(requests.single.uri.toString(), endsWith('/me/library'));
        expect(
          jsonDecode(requests.single.body as String),
          equals({
            'uris': ['spotify:track:my_track_123'],
          }),
        );
      });
    });

    group('followArtists', () {
      test('sends artist URIs to the generic /me/library endpoint', () async {
        final requests = _recordPuts(mockHttpClient, (_) => http.Response('', 200));

        await client.followArtists(
          'token',
          artistIds: <String>['artist_a', 'artist_b'],
        );

        expect(requests, hasLength(1));
        expect(requests.single.uri.toString(), endsWith('/me/library'));
        expect(
          jsonDecode(requests.single.body as String),
          equals({
            'uris': ['spotify:artist:artist_a', 'spotify:artist:artist_b'],
          }),
        );
      });

      test('falls back to PUT /me/following when /me/library is unavailable',
          () async {
        final requests = _recordPuts(
          mockHttpClient,
          (uri) => uri.path.endsWith('/me/library')
              ? http.Response('', 404)
              : http.Response('', 200),
        );

        await client.followArtists(
          'token',
          artistIds: <String>['artist_a', 'artist_b'],
        );

        expect(requests, hasLength(2));
        expect(
          requests.last.uri.toString(),
          endsWith('/me/following?type=artist&ids=artist_a,artist_b'),
        );
        expect(requests.last.body, isNull);
      });

      test('throws with the legacy status when both endpoints fail', () async {
        _recordPuts(mockHttpClient, (_) => http.Response('Gone', 404));

        await expectLater(
          () => client.followArtists('token', artistIds: <String>['artist_a']),
          throwsA(isA<SpotifyApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message',
                  'Spotify follow artists failed')),
        );
      });
    });

    group('generic /me/library fallback', () {
      test('retries the legacy endpoint on 404 and likes the track', () async {
        final requests = _recordPuts(
          mockHttpClient,
          (uri) => uri.path.endsWith('/me/library')
              ? http.Response('', 404)
              : http.Response('', 200),
        );

        await client.likeTrack(trackId: 'trk', accessToken: 'token');

        expect(requests, hasLength(2));
        expect(requests.first.uri.toString(), endsWith('/me/library'));
        expect(requests.last.uri.toString(), endsWith('/me/tracks?ids=trk'));
        // The legacy endpoint takes IDs in the query string, not a JSON body.
        expect(requests.last.body, isNull);
        expect(
          requests.last.headers,
          equals({'Authorization': 'Bearer token'}),
        );
      });

      test('retries the legacy endpoint on 403', () async {
        final requests = _recordPuts(
          mockHttpClient,
          (uri) => uri.path.endsWith('/me/library')
              ? http.Response('Forbidden', 403)
              : http.Response('', 200),
        );

        await client.likeTrack(trackId: 'trk', accessToken: 'token');

        expect(requests, hasLength(2));
        expect(requests.last.uri.toString(), endsWith('/me/tracks?ids=trk'));
      });

      test('remembers the legacy endpoint for later calls', () async {
        final requests = _recordPuts(
          mockHttpClient,
          (uri) => uri.path.endsWith('/me/library')
              ? http.Response('', 404)
              : http.Response('', 200),
        );

        await client.likeTrack(trackId: 'trk1', accessToken: 'token');
        await client.likeTrack(trackId: 'trk2', accessToken: 'token');
        await client.followArtists('token', artistIds: <String>['artist_a']);

        // Only the first write pays two round trips.
        expect(requests, hasLength(4));
        expect(requests[2].uri.toString(), endsWith('/me/tracks?ids=trk2'));
        expect(
          requests[3].uri.toString(),
          endsWith('/me/following?type=artist&ids=artist_a'),
        );
      });

      test('does not remember the fallback when the legacy call also fails',
          () async {
        final requests = _recordPuts(
          mockHttpClient,
          (uri) => uri.path.endsWith('/me/library')
              ? http.Response('', 404)
              : http.Response('Server error', 500),
        );

        await expectLater(
          () => client.likeTrack(trackId: 'trk1', accessToken: 'token'),
          throwsA(isA<SpotifyApiException>()
              .having((e) => e.statusCode, 'statusCode', 500)),
        );
        requests.clear();

        // A legacy failure proves nothing about /me/library, so the next write
        // tries the generic endpoint again.
        await expectLater(
          () => client.likeTrack(trackId: 'trk2', accessToken: 'token'),
          throwsA(isA<SpotifyApiException>()),
        );
        expect(requests.first.uri.toString(), endsWith('/me/library'));
      });

      test('never retries on 429 Too Many Requests', () async {
        final requests =
            _recordPuts(mockHttpClient, (_) => http.Response('Slow down', 429));

        await expectLater(
          () => client.likeTrack(trackId: 'trk', accessToken: 'token'),
          throwsA(isA<SpotifyApiException>()
              .having((e) => e.statusCode, 'statusCode', 429)),
        );

        expect(requests, hasLength(1));
        expect(requests.single.uri.toString(), endsWith('/me/library'));
      });

      test('never retries on 500 Server Error', () async {
        final requests =
            _recordPuts(mockHttpClient, (_) => http.Response('Boom', 500));

        await expectLater(
          () => client.likeTrack(trackId: 'trk', accessToken: 'token'),
          throwsA(isA<SpotifyApiException>()
              .having((e) => e.statusCode, 'statusCode', 500)),
        );

        expect(requests, hasLength(1));
      });
    });
  });
}

/// A PUT recorded by [_recordPuts].
class _RecordedPut {
  _RecordedPut(this.uri, this.headers, this.body);

  final Uri uri;
  final Map<String, String>? headers;
  final Object? body;
}

/// Stubs `put` on [mock] with a response chosen per request URI and returns the
/// growing list of recorded requests, so tests can assert on the exact endpoint
/// sequence the fallback produced.
List<_RecordedPut> _recordPuts(
  MockHttpClient mock,
  http.Response Function(Uri uri) respond,
) {
  final requests = <_RecordedPut>[];
  when(() => mock.put(
        any(),
        headers: any(named: 'headers'),
        body: any(named: 'body'),
      )).thenAnswer((invocation) async {
    final uri = invocation.positionalArguments.first as Uri;
    requests.add(_RecordedPut(
      uri,
      invocation.namedArguments[#headers] as Map<String, String>?,
      invocation.namedArguments[#body],
    ));
    return respond(uri);
  });
  return requests;
}
